"""A small HTTP server for the test suite, with httpbin's routes.

Written in Python on purpose. The point of these tests is to check that our
client talks to somebody else's server, and a server built out of our own parser
and our own writer would agree with our client about every mistake both of them
made. An independent implementation disagrees, which is the whole value.

It is also the reason this is Python's `http.server` rather than a real httpbin
install. No pip dependency, no version drift, and every route here exists because
a test needed it rather than because httpbin has it.

Run it with `--port 0` and it prints `PORT <n>` on stdout as soon as it is
listening, then serves until it is killed. The port line is how a test knows both
which port to talk to and that the server is ready, which beats sleeping and
hoping.
"""

from __future__ import annotations

import argparse
import gzip
import itertools
import json
import sys
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


class Handler(BaseHTTPRequestHandler):
    # Keep alive is the default in HTTP/1.1 and the connection pool needs a
    # server that actually honours it, so this is not the usual 1.0 default.
    protocol_version = "HTTP/1.1"
    server_version = "mojo-httpx-testserver/1"
    sys_version = ""

    def setup(self):
        # One handler instance per connection, so an id assigned here is an id
        # for the connection rather than for the request. It goes out on every
        # response, which is how a test can see whether the client reused a
        # connection or opened a new one. There is no other way to observe that
        # from the client side, and connection reuse is most of what a pool is.
        BaseHTTPRequestHandler.setup(self)
        self.conn_id = self.server.next_conn_id()

    def send_response(self, code, message=None):
        # Overridden so the connection id goes out on every response rather than
        # only on the ones built by _send. Several routes write their headers by
        # hand to get a framing that send_response would not produce, and a
        # route that quietly lost the id would make a reuse test fail for a
        # reason that has nothing to do with the pool.
        BaseHTTPRequestHandler.send_response(self, code, message)
        self.send_header("X-Conn-Id", str(self.conn_id))

    def log_message(self, fmt, *args):
        # The default writes to stderr, which turns a passing test run into a
        # wall of request lines. Kept as a method so it can be switched on with
        # --verbose when something needs looking at.
        if self.server.verbose:
            sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    # Every method funnels through one place, because httpbin's routes mostly
    # differ by what they echo rather than by what they do.
    def do_GET(self):
        self._dispatch()

    def do_POST(self):
        self._dispatch()

    def do_PUT(self):
        self._dispatch()

    def do_PATCH(self):
        self._dispatch()

    def do_DELETE(self):
        self._dispatch()

    def do_OPTIONS(self):
        self._dispatch()

    def do_HEAD(self):
        self._dispatch()

    def _dispatch(self):
        split = urlsplit(self.path)
        path = split.path
        query = parse_qs(split.query, keep_blank_values=True)
        parts = [p for p in path.split("/") if p != ""]

        try:
            self._route(path, parts, query)
        except BrokenPipeError:
            # The client went away mid response, which several tests do on
            # purpose. Nothing here to report.
            pass

    def _route(self, path, parts, query):
        if path == "/" or path == "/get" or path == "/anything":
            return self._echo()
        if path in ("/post", "/put", "/patch", "/delete"):
            return self._echo()
        if path == "/headers":
            return self._json({"headers": self._headers_dict()})
        if path == "/user-agent":
            return self._json({"user-agent": self.headers.get("user-agent")})
        if path == "/ip":
            return self._json({"origin": self.client_address[0]})

        if len(parts) == 2 and parts[0] == "status":
            return self._status_route(int(parts[1]))
        if len(parts) == 2 and parts[0] == "bytes":
            return self._bytes(int(parts[1]))
        if len(parts) == 2 and parts[0] == "stream-bytes":
            return self._stream_bytes(int(parts[1]))
        if len(parts) == 2 and parts[0] == "delay":
            time.sleep(float(parts[1]))
            return self._echo()
        if len(parts) == 2 and parts[0] == "drip":
            return self._drip(int(parts[1]), query)
        if len(parts) == 2 and parts[0] == "redirect":
            return self._redirect_chain(int(parts[1]))
        if path == "/redirect-to":
            code = int(query.get("status_code", ["302"])[0])
            return self._redirect(query["url"][0], code)
        if len(parts) == 3 and parts[0] == "basic-auth":
            return self._basic_auth(parts[1], parts[2])
        if path == "/cookies":
            return self._json({"cookies": self._cookies_dict()})
        if path == "/cookies/set":
            return self._set_cookies(query)
        if path == "/gzip":
            return self._compressed("gzip")
        if path == "/deflate":
            return self._compressed("deflate")
        if path == "/chunked":
            return self._chunked()
        if path == "/trailers":
            return self._trailers()
        if path == "/close":
            return self._close_after()
        if path == "/no-length":
            return self._until_close()
        if path == "/echo":
            return self._raw_echo()
        if path == "/expect":
            return self._echo()
        if path == "/conn":
            return self._json({"id": self.conn_id})

        self._json({"error": "no such route", "path": path}, code=404)

    def _headers_dict(self):
        out = {}
        for name, value in self.headers.items():
            # Repeated fields are joined the way httpbin does it, because a test
            # asserting on this wants to see that both arrived.
            if name in out:
                out[name] = out[name] + "," + value
            else:
                out[name] = value
        return out

    def _cookies_dict(self):
        out = {}
        raw = self.headers.get("cookie")
        if not raw:
            return out
        for pair in raw.split(";"):
            if "=" not in pair:
                continue
            name, _, value = pair.partition("=")
            out[name.strip()] = value.strip()
        return out

    def _read_body(self):
        length = self.headers.get("content-length")
        if self.headers.get("transfer-encoding", "").lower() == "chunked":
            return self._read_chunked()
        if length is None:
            return b""
        return self.rfile.read(int(length))

    def _read_chunked(self):
        body = b""
        while True:
            line = self.rfile.readline().strip()
            size = int(line.split(b";")[0], 16)
            if size == 0:
                # Trailers, then the blank line that ends them.
                while self.rfile.readline().strip():
                    pass
                return body
            body += self.rfile.read(size)
            self.rfile.read(2)

    def _echo(self):
        body = self._read_body()
        payload = {
            "method": self.command,
            "url": self.path,
            "headers": self._headers_dict(),
            "args": {k: v for k, v in parse_qs(urlsplit(self.path).query).items()},
        }
        try:
            payload["data"] = body.decode("utf-8")
        except UnicodeDecodeError:
            payload["data"] = ""
        try:
            payload["json"] = json.loads(body) if body else None
        except ValueError:
            payload["json"] = None
        self._json(payload)

    def _raw_echo(self):
        """Hand back exactly the bytes that were sent, and nothing else.

        Used by the tests that care about what went on the wire rather than
        about what it meant.
        """
        body = self._read_body()
        self._send(200, body, "application/octet-stream")

    def _status_route(self, code):
        self._read_body()
        # 204 and 304 must not carry a body, and this is the route tests use to
        # check that the client knows that, so the server has to get it right.
        if code in (204, 304):
            self.send_response(code)
            self.end_headers()
            return
        self._send(code, b"", "text/plain")

    def _bytes(self, count):
        self._read_body()
        # Deterministic rather than random, so a test can assert on the content
        # and not only on the length.
        payload = bytes((i % 256) for i in range(count))
        self._send(200, payload, "application/octet-stream")

    def _stream_bytes(self, count):
        self._read_body()
        payload = bytes((i % 256) for i in range(count))
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        step = 1024
        for start in range(0, len(payload), step):
            piece = payload[start : start + step]
            self.wfile.write(b"%x\r\n%s\r\n" % (len(piece), piece))
        self.wfile.write(b"0\r\n\r\n")

    def _drip(self, count, query):
        """Send `count` bytes slowly, so a read timeout has something to hit."""
        self._read_body()
        delay = float(query.get("delay", ["0.05"])[0])
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(count))
        self.end_headers()
        for _ in range(count):
            self.wfile.write(b"*")
            self.wfile.flush()
            time.sleep(delay)

    def _redirect_chain(self, remaining):
        self._read_body()
        if remaining <= 1:
            return self._redirect("/get", 302)
        return self._redirect("/redirect/%d" % (remaining - 1), 302)

    def _redirect(self, location, code):
        self.send_response(code)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _basic_auth(self, user, password):
        self._read_body()
        import base64

        want = "Basic " + base64.b64encode(
            ("%s:%s" % (user, password)).encode("utf-8")
        ).decode("ascii")
        if self.headers.get("authorization") != want:
            body = b'{"authenticated": false}'
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="test"')
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self._json({"authenticated": True, "user": user})

    def _set_cookies(self, query):
        self._read_body()
        self.send_response(302)
        self.send_header("Location", "/cookies")
        self.send_header("Content-Length", "0")
        for name, values in query.items():
            self.send_header("Set-Cookie", "%s=%s; Path=/" % (name, values[0]))
        self.end_headers()

    def _compressed(self, encoding):
        self._read_body()
        raw = json.dumps({"compressed": True, "encoding": encoding}).encode()
        if encoding == "gzip":
            payload = gzip.compress(raw)
        else:
            payload = zlib.compress(raw)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Encoding", encoding)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _chunked(self):
        self._read_body()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        for piece in (b"chunk one ", b"chunk two ", b"chunk three"):
            self.wfile.write(b"%x\r\n%s\r\n" % (len(piece), piece))
        self.wfile.write(b"0\r\n\r\n")

    def _trailers(self):
        self._read_body()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Trailer", "X-Checksum")
        self.end_headers()
        self.wfile.write(b"5\r\nhello\r\n")
        self.wfile.write(b"0\r\nX-Checksum: abc123\r\n\r\n")

    def _close_after(self):
        self._read_body()
        body = b'{"closed": true}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def _until_close(self):
        """No Content-Length and no chunking, so the close is the framing.

        The one shape where a client has to read until the socket ends. Written
        by hand because `send_response` would helpfully add a length.
        """
        self._read_body()
        self.wfile.write(b"HTTP/1.1 200 OK\r\n")
        self.wfile.write(b"Content-Type: text/plain\r\n")
        self.wfile.write(b"X-Conn-Id: %d\r\n" % self.conn_id)
        self.wfile.write(b"\r\n")
        self.wfile.write(b"this ends when the connection does")
        self.close_connection = True

    def _json(self, payload, code=200):
        self._send(code, json.dumps(payload).encode("utf-8"), "application/json")

    def _send(self, code, body, content_type):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        # A HEAD response carries the headers of the GET it describes and none
        # of the body, which is exactly the case a client gets wrong by waiting
        # for bytes that are never coming.
        if self.command != "HEAD":
            self.wfile.write(body)


class Server(ThreadingHTTPServer):
    # Threaded so that a keep alive connection sitting idle does not stop the
    # next connection being served, which is what a connection pool test does
    # by design.
    daemon_threads = True
    allow_reuse_address = True
    verbose = False

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
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    server = Server((args.host, args.port), Handler)
    server.verbose = args.verbose
    print("PORT %d" % server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
