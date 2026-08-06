package PVE::Storage::Custom::QnapPlugin;

# Use a QNAP NAS (QuTS hero / QTS) as block storage for Proxmox VE.
#
# One VM disk maps to one QNAP volume (zvol), exported as one iSCSI LUN.
# Snapshots, rollback and clones are performed by the NAS itself, so they do not
# depend on qcow2 and complete almost instantly.
#
# Things that are easy to get wrong, and why the code looks the way it does:
#   - A LUN is created through the storage API (POST /api/storage/v1/volumes),
#     not the iSCSI API. POST /api/iscsi/v1/luns registers an *existing* block
#     device; pointing it at something that does not exist reports success and
#     silently does nothing.
#   - Resizing also goes through the storage API (PUT .../reshaping). Setting
#     lun_capacity via the iSCSI API returns success but only changes what the
#     API reports, leaving the metadata inconsistent with the actual zvol.
#   - Cloning uses instant_clone_qsnapshot, which is a real copy-on-write clone.
#     clone_qsnapshot performs a full copy.
#   - Rollback silently destroys newer snapshots, so volume_rollback_is_possible
#     makes PVE refuse it first (same contract as the built-in ZFSPoolPlugin).
#
# See docs/qnap-api.md for the full API reference.

use strict;
use warnings;

use Cwd qw(realpath);
use JSON qw(decode_json);

use PVE::JSONSchema qw(get_standard_option);
use PVE::Storage::ISCSIPlugin;
use PVE::Storage::Plugin;
use PVE::Tools qw(file_get_contents file_set_contents);

use PVE::Storage::Custom::Qnap::API;

use base qw(PVE::Storage::Plugin);

our $VERSION = '0.1.0';

# Range of pve-storage API versions this plugin supports.
my $API_MIN = 9;
my $API_MAX = 15;

# QNAP volume_type. 3 = zvol (block). Shared folders use a different value and
# must be filtered out.
my $QNAP_VOLUME_TYPE_BLOCK = 3;

sub api {
    # Call the constants with parentheses so they resolve at runtime. Importing
    # PVE::Storage to get them as barewords would risk a circular load, and api()
    # is only ever called from PVE::Storage anyway.
    my $apiver = PVE::Storage::APIVER();
    my $apiage = PVE::Storage::APIAGE();

    return $apiver if $apiver >= $API_MIN && $apiver <= $API_MAX;

    # If PVE is newer but still backwards compatible with our range, claim our maximum.
    return $API_MAX if ($apiver - $apiage) <= $API_MAX;

    die "pve-qnap-plugin $VERSION: unsupported pve-storage API version $apiver\n";
}

sub type { return 'qnap'; }

sub plugindata {
    return {
        content => [{ images => 1, rootdir => 1, none => 1 }, { images => 1 }],
        format => [{ raw => 1 }, 'raw'],
        'sensitive-properties' => { password => 1 },
    };
}

sub properties {
    return {
        'qnap-pool-id' => {
            description => "QNAP storage pool id (pool_id from GET /api/storage/v1/pools).",
            type => 'integer',
            minimum => 1,
        },
        'qnap-api-port' => {
            description => "Port of the QNAP management API. HTTPS only.",
            type => 'integer',
            minimum => 1,
            maximum => 65535,
            default => 443,
        },
        'qnap-verify-tls' => {
            description => "Verify the TLS certificate of the NAS. Turn off for self-signed or expired certificates.",
            type => 'boolean',
            default => 0,
        },
        'qnap-blocksize' => {
            description => "Block size of the zvol. On RAIDZ a small value wastes a lot of space "
                . "(with 6-wide RAIDZ2 and ashift=12, 4k costs 3x the nominal capacity). "
                . "Cannot be changed after creation.",
            type => 'string',
            enum => ['4k', '8k', '16k', '32k', '64k', '128k'],
            default => '16k',
        },
        'qnap-compression' => {
            description => "Enable LZ4 compression. Nearly free, and it offsets RAIDZ padding overhead.",
            type => 'boolean',
            default => 1,
        },
        'qnap-dedup' => {
            description => "Enable deduplication. Costs a lot of memory, and linked clones already "
                . "cover the common case of duplicating a guest.",
            type => 'boolean',
            default => 0,
        },
        'qnap-ssd-cache' => {
            description => "Use the SSD read cache (the ZFS secondarycache property).",
            type => 'boolean',
            default => 1,
        },
        'qnap-fast-clone' => {
            description => "QNAP fast clone (the fastcopy property). It serves VAAI/ODX, which "
                . "Proxmox VE cannot use.",
            type => 'boolean',
            default => 0,
        },
        'qnap-sync' => {
            description => "ZIL synchronous I/O mode. 'disabled' loses data on power failure.",
            type => 'string',
            enum => ['standard', 'always', 'disabled'],
            default => 'standard',
        },
        'qnap-threshold' => {
            description => "Thin provisioning warning threshold in percent. 0 disables it.",
            type => 'integer',
            minimum => 0,
            maximum => 100,
            default => 80,
        },
    };
}

sub options {
    return {
        server => { fixed => 1 },
        portal => { fixed => 1 },
        target => { fixed => 1 },
        'qnap-pool-id' => { fixed => 1 },
        username => { optional => 1 },
        password => { optional => 1 },
        'qnap-api-port' => { optional => 1 },
        'qnap-verify-tls' => { optional => 1 },
        'qnap-blocksize' => { optional => 1, fixed => 1 },
        'qnap-compression' => { optional => 1 },
        'qnap-dedup' => { optional => 1 },
        'qnap-ssd-cache' => { optional => 1 },
        'qnap-fast-clone' => { optional => 1 },
        'qnap-sync' => { optional => 1 },
        'qnap-threshold' => { optional => 1 },
        content => { optional => 1 },
        nodes => { optional => 1 },
        disable => { optional => 1 },
        shared => { optional => 1 },
        bwlimit => { optional => 1 },
    };
}

# --- credentials ----------------------------------------------------------
#
# Store the bare password under /etc/pve/priv/storage, like PBSPlugin does.
# (CIFSPlugin writes a "password=" prefix, but that is the mount.cifs credentials
# file format, not a general convention.)

sub qnap_password_file_name {
    my ($storeid) = @_;
    return "/etc/pve/priv/storage/${storeid}.pw";
}

sub qnap_set_password {
    my ($storeid, $password) = @_;

    mkdir "/etc/pve/priv/storage";
    file_set_contents(qnap_password_file_name($storeid), "$password\n", 0600, 1);

    return;
}

sub qnap_delete_password {
    my ($storeid) = @_;

    my $file = qnap_password_file_name($storeid);
    unlink($file) or warn "removing qnap password file '$file' failed: $!\n" if -e $file;

    return;
}

sub qnap_get_password {
    my ($storeid) = @_;

    my $file = qnap_password_file_name($storeid);
    die "qnap: no password configured for storage '$storeid'"
        . " - set it with 'pvesm set $storeid --password'\n"
        if !-e $file;

    my $password = file_get_contents($file);
    chomp $password;

    return $password;
}

sub on_add_hook {
    my ($class, $storeid, $scfg, %param) = @_;

    qnap_set_password($storeid, $param{password}) if defined($param{password});

    return;
}

sub on_update_hook {
    my ($class, $storeid, $scfg, %param) = @_;

    return if !exists($param{password});

    if (defined($param{password})) {
        qnap_set_password($storeid, $param{password});
    } else {
        qnap_delete_password($storeid);
    }

    return;
}

sub on_delete_hook {
    my ($class, $storeid, $scfg) = @_;

    qnap_delete_password($storeid);

    return;
}

# --- API access -----------------------------------------------------------

my $api_clients = {};

sub _api {
    my ($class, $storeid, $scfg) = @_;

    $api_clients->{$storeid} //= PVE::Storage::Custom::Qnap::API->new(
        host => $scfg->{server},
        user => $scfg->{username} // 'admin',
        password => qnap_get_password($storeid),
        port => $scfg->{'qnap-api-port'} // 443,
        verify_tls => $scfg->{'qnap-verify-tls'} ? 1 : 0,
    );

    return $api_clients->{$storeid};
}

# Return the block volumes keyed by label, which is what PVE calls the volname.
sub _volumes {
    my ($class, $storeid, $scfg) = @_;

    my $res = $class->_api($storeid, $scfg)->get('storage/v1/volumes');

    my $pool_id = $scfg->{'qnap-pool-id'};
    my $volumes = {};

    for my $vol (@{ $res->{collection} // [] }) {
        next if ($vol->{volume_type} // 0) != $QNAP_VOLUME_TYPE_BLOCK;
        next if defined($pool_id) && (($vol->{pool}->{id} // -1) != $pool_id);
        my $label = $vol->{volume_label} // next;
        $volumes->{$label} = $vol;
    }

    return $volumes;
}

sub _volume {
    my ($class, $storeid, $scfg, $volname, $noerr) = @_;

    my $vol = $class->_volumes($storeid, $scfg)->{$volname};

    die "qnap: volume '$volname' does not exist on storage '$storeid'\n"
        if !$vol && !$noerr;

    return $vol;
}

sub _luns {
    my ($class, $storeid, $scfg) = @_;

    my $res = $class->_api($storeid, $scfg)->get('iscsi/v1/luns');

    return { map { $_->{lun_index} => $_ } @{ $res->{collection} // [] } };
}

# Resolve the target index from the IQN, so storage.cfg only has to carry the IQN.
sub _target_index {
    my ($class, $storeid, $scfg) = @_;

    my $res = $class->_api($storeid, $scfg)->get('iscsi/v1/targets');

    for my $target (@{ $res->{collection} // [] }) {
        return $target->{target_index} if ($target->{target_iqn} // '') eq $scfg->{target};
    }

    die "qnap: iSCSI target '$scfg->{target}' not found on '$scfg->{server}'\n";
}

sub _snapshots {
    my ($class, $storeid, $scfg, $volume_id) = @_;

    my $res = $class->_api($storeid, $scfg)->get("snapmgr/v1/volumes/$volume_id/snapshots");

    # Sort by creation order; the rollback blocker check depends on it.
    my @sorted = sort {
        ($a->{create_time} // '') cmp ($b->{create_time} // '')
            || ($a->{snapshot_id} // 0) <=> ($b->{snapshot_id} // 0)
    } @{ $res->{collection} // [] };

    return \@sorted;
}

sub _snapshot_id {
    my ($class, $storeid, $scfg, $volume_id, $snap, $noerr) = @_;

    for my $snapshot (@{ $class->_snapshots($storeid, $scfg, $volume_id) }) {
        return $snapshot->{snapshot_id} if ($snapshot->{snapshot_name} // '') eq $snap;
    }

    die "qnap: snapshot '$snap' does not exist\n" if !$noerr;

    return undef;
}

sub _blocksize_bytes {
    my ($scfg) = @_;

    my $blocksize = $scfg->{'qnap-blocksize'} // '16k';
    my ($num, $unit) = $blocksize =~ m/^(\d+)([km]?)$/i
        or die "qnap: invalid qnap-blocksize '$blocksize'\n";

    return $num * 1024 if lc($unit) eq 'k';
    return $num * 1024 * 1024 if lc($unit) eq 'm';
    return $num;
}

# QNAP expects the sync mode as a number.
my $SYNC_IO = { standard => 0, always => 1, disabled => 2 };

# --- volume names ---------------------------------------------------------

sub parse_volname {
    my ($class, $volname) = @_;

    if ($volname =~ m/^(base-(\d+)-\S+)\/(vm-(\d+)-\S+)$/) {
        my ($basename, $basevmid, $name, $vmid) = ($1, $2, $3, $4);
        $class->parse_volname($basename); # validate only
        return ('images', $name, $vmid, $basename, $basevmid, undef, 'raw');
    } elsif ($volname =~ m/^(base-(\d+)-\S+)$/) {
        return ('images', $1, $2, undef, undef, 1, 'raw');
    } elsif ($volname =~ m/^(vm-(\d+)-\S+)$/) {
        return ('images', $1, $2, undef, undef, undef, 'raw');
    }

    die "qnap: unable to parse volume name '$volname'\n";
}

# Like RBDPlugin, implement path() only and skip filesystem_path. The latter is
# not given a storeid, which is needed to look up the NAA of the LUN. Every base
# class method that would call filesystem_path is overridden below.
sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    die "qnap: direct access to snapshots is not supported"
        . " - clone the snapshot to a new volume instead\n"
        if defined($snapname);

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    my $vol = $class->_volume($storeid, $scfg, $name);
    my $lun_index = $vol->{lun_index} // -1;

    die "qnap: volume '$name' has no iSCSI LUN attached\n" if $lun_index < 0;

    my $lun = $class->_luns($storeid, $scfg)->{$lun_index}
        or die "qnap: LUN $lun_index for volume '$name' not found\n";

    my $naa = $lun->{lun_naa}
        or die "qnap: LUN $lun_index has no NAA identifier\n";

    # Prefer the multipath device if one exists.
    my $mpath = "/dev/mapper/3$naa";
    my $path = -e $mpath ? $mpath : "/dev/disk/by-id/scsi-3$naa";

    return wantarray ? ($path, $vmid, $vtype) : $path;
}

sub find_free_diskname {
    my ($class, $storeid, $scfg, $vmid, $fmt, $add_fmt_suffix) = @_;

    my @names = keys %{ $class->_volumes($storeid, $scfg) };

    return PVE::Storage::Plugin::get_next_vm_diskname(\@names, $storeid, $vmid, $fmt, $scfg);
}

# --- volume lifecycle -----------------------------------------------------

# Creation is asynchronous, so wait until a lun_index has been assigned.
sub _wait_for_lun {
    my ($class, $storeid, $scfg, $volname, $timeout) = @_;

    $timeout //= 60;

    for my $i (1 .. $timeout) {
        my $vol = $class->_volume($storeid, $scfg, $volname, 1);
        if ($vol && !$vol->{creating} && ($vol->{lun_index} // -1) >= 0) {
            return $vol;
        }
        sleep 1;
    }

    die "qnap: timeout waiting for volume '$volname' to become ready\n";
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    die "qnap: unsupported format '$fmt' - only 'raw' is supported\n"
        if defined($fmt) && $fmt ne 'raw';

    $name //= $class->find_free_diskname($storeid, $scfg, $vmid, 'raw');

    die "qnap: illegal name '$name' - should be 'vm-$vmid-*'\n"
        if $name !~ m/^vm-$vmid-/;

    die "qnap: volume '$name' already exists\n"
        if $class->_volume($storeid, $scfg, $name, 1);

    my $api = $class->_api($storeid, $scfg);

    # $size arrives in KiB.
    $api->post(
        'storage/v1/volumes',
        {
            label => $name,
            type => 'zvol',
            pool_id => int($scfg->{'qnap-pool-id'}),
            capacity => int($size) * 1024,
            provision_type => 'thin',
            threshold => int($scfg->{'qnap-threshold'} // 80),
            iscsi => { create_lun => JSON::true },
            zfs => {
                compress => ($scfg->{'qnap-compression'} // 1) ? JSON::true : JSON::false,
                dedup => ($scfg->{'qnap-dedup'} // 0) ? JSON::true : JSON::false,
                fast_copy => ($scfg->{'qnap-fast-clone'} // 0) ? JSON::true : JSON::false,
                record_size => _blocksize_bytes($scfg),
            },
            read_cache_enable => ($scfg->{'qnap-ssd-cache'} // 1) ? JSON::true : JSON::false,
            sync_io => $SYNC_IO->{ $scfg->{'qnap-sync'} // 'standard' },
            snapshot_reservation => 0,
            encryption => {
                encrypt => JSON::false,
                key_str => '',
                save_key => JSON::false,
                use_default_key => JSON::false,
            },
        },
    );

    my $vol = eval { $class->_wait_for_lun($storeid, $scfg, $name) };
    if (my $err = $@) {
        eval { $class->free_image($storeid, $scfg, $name, 0, 'raw') };
        die $err;
    }

    $class->_map_lun($storeid, $scfg, $vol->{lun_index});

    return $name;
}

sub _map_lun {
    my ($class, $storeid, $scfg, $lun_index) = @_;

    my $target_index = $class->_target_index($storeid, $scfg);
    $class->_api($storeid, $scfg)->post("iscsi/v1/targets/$target_index/luns/$lun_index");

    return;
}

sub _unmap_lun {
    my ($class, $storeid, $scfg, $lun_index) = @_;

    my $target_index = $class->_target_index($storeid, $scfg);
    eval { $class->_api($storeid, $scfg)->delete("iscsi/v1/targets/$target_index/luns/$lun_index") };
    warn $@ if $@;

    return;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $format) = @_;

    my ($vtype, $name) = $class->parse_volname($volname);

    my $vol = $class->_volume($storeid, $scfg, $name, 1);
    return undef if !$vol; # stay idempotent

    my $api = $class->_api($storeid, $scfg);

    # Order matters: unmap, then snapshots, then the volume itself. Deleting a
    # volume whose LUN is still mapped fails with -14 "Failed to unmount volume",
    # a message that has nothing to do with the actual cause.
    my $lun_index = $vol->{lun_index} // -1;
    $class->_unmap_lun($storeid, $scfg, $lun_index) if $lun_index >= 0;

    for my $snapshot (@{ $class->_snapshots($storeid, $scfg, $vol->{volume_id}) }) {
        eval { $api->delete("snapmgr/v1/snapshots/$snapshot->{snapshot_id}") };
        warn $@ if $@;
    }

    $api->delete("storage/v1/volumes/$vol->{volume_id}");

    return undef;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $volumes = $class->_volumes($storeid, $scfg);

    my $res = [];
    for my $name (sort keys %$volumes) {
        my $vol = $volumes->{$name};

        my ($owner, $parent);
        eval {
            (undef, undef, $owner, $parent) = $class->parse_volname($name);
        };
        next if $@; # ignore volumes that are not managed by PVE

        my $volid = "$storeid:$name";

        if ($vollist) {
            next if !grep { $_ eq $volid } @$vollist;
        } elsif (defined($vmid)) {
            next if !defined($owner) || $owner ne $vmid;
        }

        push @$res, {
            volid => $volid,
            format => 'raw',
            size => $vol->{size}->{total} // 0,
            used => $vol->{size}->{used} // 0,
            vmid => $owner,
            parent => $parent,
        };
    }

    return $res;
}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    my ($vtype, $name) = $class->parse_volname($volname);
    my $vol = $class->_volume($storeid, $scfg, $name);

    my $size = $vol->{size}->{total} // 0;
    my $used = $vol->{size}->{used} // 0;

    return wantarray ? ($size, 'raw', $used, undef) : $size;
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    my ($vtype, $name) = $class->parse_volname($volname);
    my $vol = $class->_volume($storeid, $scfg, $name);

    # lun_capacity on the iSCSI API reports success without resizing the zvol.
    $class->_api($storeid, $scfg)->put(
        "storage/v1/volumes/$vol->{volume_id}/reshaping",
        {
            capacity => int($size),
            provision_type => $vol->{provision_type} // 'thin',
            iscsi => { update_lun => JSON::true },
        },
    );

    # Rescan so the guest sees the new size.
    eval { $class->_rescan_sessions($scfg) };
    warn $@ if $@;

    return 1;
}

# --- snapshots ------------------------------------------------------------

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my ($vtype, $name) = $class->parse_volname($volname);
    my $vol = $class->_volume($storeid, $scfg, $name);

    $class->_api($storeid, $scfg)->post(
        "snapmgr/v1/volumes/$vol->{volume_id}/snapshots",
        {
            snapshot_name => $snap,
            snapshot_description => "Proxmox VE snapshot",
            # vital=1 marks the snapshot as protected in the QNAP UI.
            vital => 0,
            # Never let snapshots expire. QNAP's own CSI driver sets 30 minutes.
            expire_min => 0,
        },
    );

    return;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;

    my ($vtype, $name) = $class->parse_volname($volname);
    my $vol = $class->_volume($storeid, $scfg, $name);

    my $snapshot_id = $class->_snapshot_id($storeid, $scfg, $vol->{volume_id}, $snap, 1);
    return if !defined($snapshot_id); # stay idempotent

    $class->_api($storeid, $scfg)->delete("snapmgr/v1/snapshots/$snapshot_id");

    return;
}

# A ZFS rollback destroys every snapshot newer than the target, and QNAP does it
# without warning. Report those snapshots as blockers so PVE refuses the rollback,
# exactly like the built-in ZFSPoolPlugin does.
sub volume_rollback_is_possible {
    my ($class, $scfg, $storeid, $volname, $snap, $blockers) = @_;

    my ($vtype, $name) = $class->parse_volname($volname);
    my $vol = $class->_volume($storeid, $scfg, $name);

    my $found;
    $blockers //= []; # not guaranteed to be set by the caller

    for my $snapshot (@{ $class->_snapshots($storeid, $scfg, $vol->{volume_id}) }) {
        my $snapshot_name = $snapshot->{snapshot_name} // '';
        if ($snapshot_name eq $snap) {
            $found = 1;
        } elsif ($found) {
            push @$blockers, $snapshot_name;
        }
    }

    my $volid = "${storeid}:${volname}";

    die "can't rollback, snapshot '$snap' does not exist on '$volid'\n"
        if !$found;

    die "can't rollback, '$snap' is not most recent snapshot on '$volid'\n"
        if scalar(@$blockers) > 0;

    return 1;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my ($vtype, $name) = $class->parse_volname($volname);
    my $vol = $class->_volume($storeid, $scfg, $name);
    my $snapshot_id = $class->_snapshot_id($storeid, $scfg, $vol->{volume_id}, $snap);

    my $api = $class->_api($storeid, $scfg);

    # Asynchronous job; the reply only says fork:1.
    $api->post("snapmgr/v1/snapshots/$snapshot_id/recovery?stop=false&save_key=false");

    # Wait for the newer snapshots to disappear, which marks the job as done.
    for my $i (1 .. 120) {
        my $snapshots = $class->_snapshots($storeid, $scfg, $vol->{volume_id});
        my $latest = @$snapshots ? $snapshots->[-1]->{snapshot_name} : undef;
        return if defined($latest) && $latest eq $snap;
        sleep 1;
    }

    die "qnap: timeout waiting for rollback of '$volname' to '$snap'\n";
}

sub volume_snapshot_info {
    my ($class, $scfg, $storeid, $volname) = @_;

    my ($vtype, $name) = $class->parse_volname($volname);
    my $vol = $class->_volume($storeid, $scfg, $name);

    my $info = {};
    my $order = 0;

    for my $snapshot (@{ $class->_snapshots($storeid, $scfg, $vol->{volume_id}) }) {
        $info->{ $snapshot->{snapshot_name} } = {
            id => $snapshot->{snapshot_id},
            timestamp => $snapshot->{create_time},
            order => $order++,
        };
    }

    return $info;
}

# --- templates and clones -------------------------------------------------

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase) = $class->parse_volname($volname);

    die "qnap: create_base is not possible with base image\n" if $isBase;

    my $vol = $class->_volume($storeid, $scfg, $name);
    my $api = $class->_api($storeid, $scfg);

    my $newname = $name;
    $newname =~ s/^vm-/base-/;

    $api->put(
        "storage/v1/volumes/$vol->{volume_id}/label",
        { label => $newname, iscsi => { update_lun => JSON::true } },
    );

    # The snapshot every linked clone will be derived from.
    $api->post(
        "snapmgr/v1/volumes/$vol->{volume_id}/snapshots",
        {
            snapshot_name => '__base__',
            snapshot_description => 'Proxmox VE base image',
            vital => 0,
            expire_min => 0,
        },
    );

    return $newname;
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;

    my ($vtype, $basename, $basevmid, undef, undef, $isBase) = $class->parse_volname($volname);

    # A linked clone of a template derives from the __base__ snapshot.
    $snap //= '__base__';

    die "qnap: clone_image only works on base images or snapshots\n"
        if !$isBase && $snap eq '__base__';

    my $vol = $class->_volume($storeid, $scfg, $basename);
    my $snapshot_id = $class->_snapshot_id($storeid, $scfg, $vol->{volume_id}, $snap);

    my $name = $class->find_free_diskname($storeid, $scfg, $vmid, 'raw');
    my $target_index = $class->_target_index($storeid, $scfg);

    # instant_clone_qsnapshot creates a real copy-on-write clone.
    # clone_qsnapshot would perform a full copy instead.
    $class->_api($storeid, $scfg)->cgi_result(
        'disk/snapshot.cgi',
        {
            func => 'instant_clone_qsnapshot',
            snapshotID => $snapshot_id,
            new_name => $name,
            poolID => $scfg->{'qnap-pool-id'},
            targetIndex => $target_index,
            by_lun => 1,
        },
    );

    $class->_wait_for_lun($storeid, $scfg, $name);

    return $name;
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    my $features = {
        snapshot => { current => 1, snap => 1 },
        clone => { base => 1, snap => 1 },
        template => { current => 1 },
        copy => { base => 1, current => 1, snap => 1 },
        sparseinit => { base => 1, current => 1 },
        rename => { current => 1 },
    };

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase) = $class->parse_volname($volname);

    my $key = $snapname ? 'snap' : ($isBase ? 'base' : 'current');

    return 1 if $features->{$feature}->{$key};

    return undef;
}

# --- storage state --------------------------------------------------------

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $session = PVE::Storage::ISCSIPlugin::iscsi_session($cache, $scfg->{target});
    my $active = defined($session) ? 1 : 0;

    my $pools = eval { $class->_api($storeid, $scfg)->get('storage/v1/pools') };
    if (my $err = $@) {
        warn "qnap: unable to query pool status: $err";
        return (0, 0, 0, 0);
    }

    for my $pool (@{ $pools->{collection} // [] }) {
        next if ($pool->{pool_id} // -1) != $scfg->{'qnap-pool-id'};

        my $capacity = $pool->{capacity} // {};
        my $total = $capacity->{capacity_bytes} // 0;
        my $free = $capacity->{free_bytes} // 0;
        my $used = $capacity->{allocated_bytes} // ($total - $free);

        return ($total, $free, $used, $active);
    }

    warn "qnap: pool $scfg->{'qnap-pool-id'} not found on '$scfg->{server}'\n";

    return (0, 0, 0, 0);
}

sub _rescan_sessions {
    my ($class, $scfg) = @_;

    my $sessions = PVE::Storage::ISCSIPlugin::iscsi_session_list()->{ $scfg->{target} };
    PVE::Storage::ISCSIPlugin::iscsi_session_rescan($sessions) if $sessions;

    return;
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $sessions = PVE::Storage::ISCSIPlugin::iscsi_session($cache, $scfg->{target});
    my $portals = PVE::Storage::ISCSIPlugin::iscsi_portals($scfg->{target}, $scfg->{portal});

    if (!defined($sessions)) {
        eval { PVE::Storage::ISCSIPlugin::iscsi_login($scfg->{target}, $portals, $cache) };
        warn $@ if $@;
    } else {
        PVE::Storage::ISCSIPlugin::iscsi_session_rescan($sessions);
    }

    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    # Do not log out: other nodes may still be using the same target.
    return 1;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    die "qnap: snapshots cannot be activated directly\n" if defined($snapname);

    my $path = $class->path($scfg, $volname, $storeid);

    return 1 if -b $path || -b (realpath($path) // '');

    # A freshly created or resized LUN may not be visible yet.
    eval { $class->_rescan_sessions($scfg) };
    warn $@ if $@;

    for my $i (1 .. 30) {
        my $real = realpath($path);
        return 1 if defined($real) && -b $real;
        sleep 1;
    }

    die "qnap: device for volume '$volname' did not appear at '$path'\n";
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    return 1;
}

sub check_connection {
    my ($class, $storeid, $scfg) = @_;

    eval { $class->_api($storeid, $scfg)->get('iscsi/v1/service') };
    if (my $err = $@) {
        warn "qnap: connection check failed: $err";
        return 0;
    }

    return 1;
}

1;
