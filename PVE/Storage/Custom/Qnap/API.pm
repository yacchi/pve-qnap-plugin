package PVE::Storage::Custom::Qnap::API;

# Client for the QNAP QuTS hero / QTS management API.
#
# It hides three different transports:
#   - REST   /api/...                 iSCSI LUNs, targets, storage, snapshots
#   - CGI    /cgi-bin/...             whatever REST does not cover (returns XML)
#   - auth   /cgi-bin/authLogin.cgi   obtains the session id
#
# Note that the session id is passed differently depending on the transport:
#   REST -> "sid: <sid>" header (X-SID, Authorization etc. are rejected)
#   CGI  -> &sid=<sid> query parameter

use strict;
use warnings;

use HTTP::Request;
use JSON qw(decode_json encode_json);
use LWP::UserAgent;
use MIME::Base64 qw(encode_base64);
use URI::Escape qw(uri_escape);

my $LOGIN_PATH = '/cgi-bin/authLogin.cgi';

sub new {
    my ($class, %param) = @_;

    die "QNAP API: host is required\n" if !$param{host};

    my $self = {
        host => $param{host},
        user => $param{user} // 'admin',
        password => $param{password},
        port => $param{port} // 443,
        verify_tls => $param{verify_tls} // 0,
        timeout => $param{timeout} // 120,
        sid => undef,
    };

    return bless $self, $class;
}

sub _base_url {
    my ($self) = @_;
    return "https://$self->{host}:$self->{port}";
}

sub _ua {
    my ($self) = @_;

    $self->{ua} //= LWP::UserAgent->new(
        timeout => $self->{timeout},
        agent => 'pve-qnap-plugin/0.1',
        ssl_opts => {
            verify_hostname => $self->{verify_tls} ? 1 : 0,
            SSL_verify_mode => $self->{verify_tls} ? 0x01 : 0x00,
        },
    );

    return $self->{ua};
}

# --- authentication -------------------------------------------------------

sub login {
    my ($self) = @_;

    die "QNAP API: password is not set\n" if !defined($self->{password});

    # Send the credentials in the body. QNAP's own CSI driver puts them in the
    # query string, where they end up in access logs and error messages.
    my $pw = encode_base64($self->{password}, '');
    my $body = 'user=' . uri_escape($self->{user}) . '&pwd=' . uri_escape($pw);

    my $req = HTTP::Request->new('POST', $self->_base_url() . $LOGIN_PATH);
    $req->header('Content-Type' => 'application/x-www-form-urlencoded');
    $req->content($body);

    my $res = $self->_ua()->request($req);
    die "QNAP API: login request failed: " . $res->status_line . "\n" if !$res->is_success;

    my $xml = $res->decoded_content // '';
    my ($passed) = $xml =~ m{<authPassed><!\[CDATA\[(\d+)\]\]></authPassed>};
    my ($sid) = $xml =~ m{<authSid><!\[CDATA\[([^\]]*)\]\]></authSid>};

    die "QNAP API: authentication failed for user '$self->{user}'\n"
        if !$passed || !$sid;

    $self->{sid} = $sid;

    return $sid;
}

sub _sid {
    my ($self) = @_;
    return $self->{sid} // $self->login();
}

# --- REST -----------------------------------------------------------------

# An expired session is reported as HTTP 200 with error_code -22, so the body
# has to be inspected rather than the status code.
sub _is_auth_error {
    my ($data) = @_;
    return 0 if ref($data) ne 'HASH';
    return 0 if ($data->{error_code} // 0) != -22;
    return ($data->{error_message} // '') =~ /sid is invalid/i;
}

sub _rest_raw {
    my ($self, $method, $path, $body) = @_;

    $path = "/$path" if $path !~ m{^/};
    my $req = HTTP::Request->new($method, $self->_base_url() . "/api$path");
    $req->header('sid' => $self->_sid());

    if (defined($body)) {
        $req->header('Content-Type' => 'application/json');
        $req->content(ref($body) ? encode_json($body) : $body);
    }

    my $res = $self->_ua()->request($req);
    my $text = $res->decoded_content // '';

    # Treat an empty body (204 and friends) as success.
    return { error_code => 0, error_message => '' } if $text eq '';

    my $data = eval { decode_json($text) };
    if ($@) {
        die "QNAP API: $method /api$path returned non-JSON ("
            . $res->status_line . "): "
            . substr($text, 0, 200) . "\n";
    }

    return $data;
}

sub rest {
    my ($self, $method, $path, $body) = @_;

    my $data = $self->_rest_raw($method, $path, $body);

    if (_is_auth_error($data)) {
        $self->login();
        $data = $self->_rest_raw($method, $path, $body);
    }

    my $code = $data->{error_code} // 0;
    if ($code != 0) {
        my $msg = $data->{error_message} // 'unknown error';
        # When a rollback is blocked by a clone, QNAP names the offending snapshot.
        if (my $blocked = eval { $data->{error_data}->{cloned_snapshots} }) {
            $msg .= " (cloned snapshots: $blocked)";
        }
        die "QNAP API: $method /api$path failed: $msg [$code]\n";
    }

    return $data;
}

sub get    { my ($self, $path) = @_;        return $self->rest('GET',    $path); }
sub post   { my ($self, $path, $body) = @_; return $self->rest('POST',   $path, $body // {}); }
sub put    { my ($self, $path, $body) = @_; return $self->rest('PUT',    $path, $body // {}); }
sub delete { my ($self, $path) = @_;        return $self->rest('DELETE', $path); }

# --- CGI ------------------------------------------------------------------

# For operations REST does not expose, such as instant clones. Returns raw XML.
sub cgi {
    my ($self, $script, $params) = @_;

    my @pairs;
    for my $key (sort keys %$params) {
        push @pairs, uri_escape($key) . '=' . uri_escape($params->{$key} // '');
    }

    my $run = sub {
        my $url = $self->_base_url() . "/cgi-bin/$script?"
            . join('&', @pairs, 'sid=' . uri_escape($self->_sid()));
        my $res = $self->_ua()->get($url);
        die "QNAP API: CGI $script failed: " . $res->status_line . "\n" if !$res->is_success;
        return $res->decoded_content // '';
    };

    my $xml = $run->();

    # The CGI endpoints report an expired session as authPassed=0.
    if ($xml =~ m{<authPassed><!\[CDATA\[0\]\]></authPassed>}) {
        $self->login();
        $xml = $run->();
    }

    return $xml;
}

# Extract <result> from a CGI response. QNAP returns 0 on success, or the id of
# the object it just created.
sub cgi_result {
    my ($self, $script, $params) = @_;

    my $xml = $self->cgi($script, $params);
    my ($result) = $xml =~ m{<result>(-?\d+)</result>};

    die "QNAP API: CGI $script returned no result\n" if !defined($result);
    die "QNAP API: CGI $script failed (result=$result)\n" if $result < 0;

    return $result;
}

1;
