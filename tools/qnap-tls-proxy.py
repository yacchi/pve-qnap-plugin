#!/usr/bin/env python3
"""TLS proxy that records the HTTP calls a QNAP CSI sidecar makes to a NAS.

The sidecar always connects to https://<host>:443 regardless of the protocol and
port it is configured with, so listen on 443 and forward upstream. The upstream
certificate is not verified, since it is typically self-signed or expired.

Secrets (pwd / password) are redacted from the log.
"""
import http.server
import json
import os
import ssl
import sys
import urllib.parse

import urllib3

UPSTREAM = os.environ.get("UPSTREAM", "https://172.26.64.1")
LOG = os.environ.get("LOGFILE", "/work/csi-calls.jsonl")

urllib3.disable_warnings()
POOL = urllib3.PoolManager(cert_reqs="CERT_NONE", retries=False, timeout=120.0)

SECRET_KEYS = {"pwd", "password", "passwd"}


def redact_qs(query: str) -> str:
    parts = urllib.parse.parse_qsl(query, keep_blank_values=True)
    return urllib.parse.urlencode(
        [(k, "<redacted>" if k.lower() in SECRET_KEYS else v) for k, v in parts]
    )


def redact_body(body: bytes) -> str:
    if not body:
        return ""
    try:
        obj = json.loads(body)
    except Exception:
        text = body.decode("utf-8", "replace")
        return text if len(text) < 4000 else text[:4000] + "...(truncated)"
    if isinstance(obj, dict):
        for k in list(obj):
            if k.lower() in SECRET_KEYS:
                obj[k] = "<redacted>"
    return json.dumps(obj, ensure_ascii=False)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # suppress the default stderr log
        pass

    def _read_body(self) -> bytes:
        if (self.headers.get("Transfer-Encoding") or "").lower() == "chunked":
            chunks = []
            while True:
                size = int(self.rfile.readline().split(b";")[0], 16)
                if size == 0:
                    self.rfile.readline()
                    break
                chunks.append(self.rfile.read(size))
                self.rfile.read(2)  # CRLF
            return b"".join(chunks)
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def _proxy(self):
        body = self._read_body()
        url = urllib.parse.urlsplit(self.path)

        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in ("host", "transfer-encoding", "content-length")}
        resp = POOL.request(
            self.command, UPSTREAM + self.path, body=body or None,
            headers=headers, redirect=False, preload_content=True,
        )

        rec = {
            "method": self.command,
            "path": url.path,
            "query": redact_qs(url.query),
            "req_headers": {k: ("<redacted>" if k.lower() == "sid" else v)
                            for k, v in headers.items()},
            "req_body": redact_body(body),
            "status": resp.status,
            "resp_body": redact_body(resp.data)[:4000],
        }
        with open(LOG, "a") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        print(f"{self.command} {url.path}?{rec['query']} -> {resp.status}",
              file=sys.stderr, flush=True)

        self.send_response(resp.status)
        for k, v in resp.headers.items():
            if k.lower() in ("transfer-encoding", "connection", "content-length"):
                continue
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(resp.data)))
        self.end_headers()
        self.wfile.write(resp.data)

    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = _proxy


def main():
    httpd = http.server.ThreadingHTTPServer(("0.0.0.0", 443), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain("/certs/server.crt", "/certs/server.key")
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    print(f"proxy listening :443 -> {UPSTREAM}", file=sys.stderr, flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
