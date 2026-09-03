"""A small HTTP forward proxy for the test suite.

Python for the reason `server.py` is Python: a proxy built out of our own writer
would agree with our client about whatever both of them got wrong, and the only
thing worth testing here is that a real proxy accepts what we send it. This one
is deliberately strict about the part that matters, which is the request line. A
request that arrives in origin form is refused with a 400 rather than guessed at,
because a proxy that guesses is a proxy that would pass a broken client.

It relays rather than answers. Whatever comes back from the origin goes back to
the client with the status, the headers and the body unchanged, so a test can
check that a compressed body or a set cookie survives the extra hop.

Three headers are added on the way out and they are the whole observability
story: `X-Proxy-Target` is the absolute URL that arrived in the request line,
`X-Proxy-Auth` is the `Proxy-Authorization` that came with it or `-` if there was
none, and `X-Proxy-Conn` is an id for the client connection so a test can see
whether the pool reused it. There is no other channel back to the test, and a
second one would be a second thing to keep in step.

`--auth user:pass` makes it demand credentials and answer 407 without them,
which is the only interesting failure mode a forward proxy has.

Run it with `--port 0` and it prints `PORT <n>` on stdout once it is listening,
the same handshake `server.py` uses and for the same reason.
"""

from __future__ import annotations

import argparse
import base64
import http.client
import itertools
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

# Headers that describe this hop rather than the message, so they stop here. RFC
# 9110 section 7.6.1. `Proxy-Authorization` is the one a test actually watches:
# a proxy that forwarded it would be handing the proxy's password to whatever
# server the request was aimed at.
HOP_BY_HOP = frozenset(
    [
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    ]
)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "mojo-httpx-testproxy/1"
    sys_version = ""

    def setup(self):
        # One handler instance per connection, so this is a connection id and
        # not a request id. See the same note in server.py.
        BaseHTTPRequestHandler.setup(self)
        self.conn_id = self.server.next_conn_id()

    def handle(self):
        try:
            BaseHTTPRequestHandler.handle(self)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    def log_message(self, fmt, *args):
        if self.server.verbose:
            sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def do_GET(self):
        self._proxy()

    def do_HEAD(self):
        self._proxy()

    def do_POST(self):
        self._proxy()

    def do_PUT(self):
        self._proxy()

    def do_DELETE(self):
        self._proxy()

    def do_PATCH(self):
        self._proxy()

    def do_OPTIONS(self):
        self._proxy()

    def _proxy(self):
        target = self.path
        offered = self.headers.get("Proxy-Authorization", "-")

        parts = urlsplit(target)
        if parts.scheme != "http" or not parts.netloc:
            # BaseHTTPRequestHandler already parsed the request line, so an
            # origin form target arrives here as a bare path. Refusing it is the
            # point of this proxy existing.
            self._fail(
                400,
                "a proxy needs an absolute request target, got %r" % target,
                offered,
            )
            return

        if self.server.credential is not None:
            if offered != self.server.credential:
                self._fail(
                    407,
                    "this proxy wants credentials",
                    offered,
                    extra=[("Proxy-Authenticate", 'Basic realm="testproxy"')],
                )
                return

        body = self._read_body()
        try:
            reply = self._forward(parts, body)
        except OSError as reason:
            self._fail(502, "cannot reach the origin: %s" % reason, offered)
            return

        status, reason, headers, payload = reply
        self.send_response(status, reason)
        self.send_header("X-Proxy-Target", target)
        self.send_header("X-Proxy-Auth", offered)
        self.send_header("X-Proxy-Conn", str(self.conn_id))
        for name, value in headers:
            if name.lower() in HOP_BY_HOP:
                continue
            if name.lower() == "content-length":
                # Rewritten below from what we actually hold, because a HEAD
                # reply carries a length for a body that is not there and
                # copying it would leave the client waiting for bytes nobody is
                # going to send.
                continue
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if payload:
            self.wfile.write(payload)

    def _read_body(self):
        length = self.headers.get("Content-Length")
        if length is None:
            return b""
        return self.rfile.read(int(length))

    def _forward(self, parts, body):
        """Make the real request and bring back everything it answered with."""
        conn = http.client.HTTPConnection(parts.netloc, timeout=10)
        try:
            path = parts.path or "/"
            if parts.query:
                path = path + "?" + parts.query
            forwarded = {}
            for name, value in self.headers.items():
                if name.lower() in HOP_BY_HOP:
                    continue
                forwarded[name] = value
            conn.request(self.command, path, body=body, headers=forwarded)
            answer = conn.getresponse()
            payload = answer.read()
            return (
                answer.status,
                answer.reason,
                answer.getheaders(),
                b"" if self.command == "HEAD" else payload,
            )
        finally:
            conn.close()

    def _fail(self, status, message, offered, extra=()):
        payload = message.encode("utf-8")
        self.send_response(status)
        self.send_header("X-Proxy-Auth", offered)
        self.send_header("X-Proxy-Conn", str(self.conn_id))
        for name, value in extra:
            self.send_header(name, value)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)


class Proxy(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 256

    verbose = False
    credential = None
    """The exact `Proxy-Authorization` value to demand, or None to demand none."""

    def __init__(self, *args, **kwargs):
        ThreadingHTTPServer.__init__(self, *args, **kwargs)
        self._conn_counter = itertools.count(1)
        self._conn_lock = threading.Lock()

    def next_conn_id(self):
        with self._conn_lock:
            return next(self._conn_counter)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--auth", default=None, help="user:pass to demand")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    proxy = Proxy((args.host, args.port), Handler)
    proxy.verbose = args.verbose
    if args.auth is not None:
        encoded = base64.b64encode(args.auth.encode("utf-8")).decode("ascii")
        proxy.credential = "Basic " + encoded
    print("PORT %d" % proxy.server_address[1], flush=True)
    try:
        proxy.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
