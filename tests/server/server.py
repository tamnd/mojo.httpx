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

`--tls` serves the same routes over https with the certificate in
`tests/fixtures/tls`, which is a self signed certificate for localhost that is
also its own trust anchor. It is there so that the CONNECT tunnel tests have a
real https server on the far end of the tunnel, and so that the https path can be
exercised without the network. `tests/fixtures/tls/README.md` says how it was
made and why checking a private key into a repository is fine in this one case.
"""

from __future__ import annotations

import argparse
import gzip
import itertools
import json
import os
import ssl
import sys
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

# The two codings that are not in every Python. brotli comes from the
# brotli-python package and zstd from either the standard library, which has it
# from 3.14 on, or the zstandard package for a Python older than that. pixi
# installs both packages, so which Python the environment solved to does not
# decide whether these two routes work. They are still imported softly, so that
# a Python without them runs every other route and the two that need them answer
# 501 rather than killing the server on an import at the top of the file.
try:
    import brotli
except ImportError:
    brotli = None

try:
    from compression import zstd
except ImportError:
    try:
        import zstandard as zstd
    except ImportError:
        zstd = None


DIGEST_REALM = "testserver"
DIGEST_NONCE = "dcd98b7102dd2f0e8b11d0f600bfb0c093"
DIGEST_OPAQUE = "5ccc069c403ebaf9f0171e9517f40e41"
"""Fixed rather than random, so any connection can check any response.

A real server issues a fresh nonce per challenge and remembers it. Doing that
here would mean shared state across the threading server for no gain, since
what these tests are checking is that the client computes the right answer to a
challenge, not that the server tracks replay.
"""


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

    def handle(self):
        # A client that closes with bytes we already sent still sitting unread
        # makes the kernel answer with a reset, and the reset lands wherever we
        # happen to be: on the write inside the route, or on the read of the
        # next request line, which is outside _dispatch and so past the catch
        # there. Either way it is a peer that left rather than anything wrong
        # here, and letting it through prints a traceback into the middle of a
        # passing test run. The cancellation tests leave that way on purpose.
        try:
            BaseHTTPRequestHandler.handle(self)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

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
        if len(parts) in (4, 5) and parts[0] == "digest-auth":
            algorithm = parts[4] if len(parts) == 5 else "MD5"
            return self._digest_auth(parts[1], parts[2], parts[3], algorithm)
        if path == "/cookies":
            return self._json({"cookies": self._cookies_dict()})
        if path == "/cookies/set":
            return self._set_cookies(query)
        if path == "/cookies/delete":
            return self._delete_cookies(query)
        if path == "/cookies/set-raw":
            return self._set_cookie_raw(query)
        if path == "/gzip":
            return self._compressed("gzip", query)
        if path == "/deflate":
            return self._compressed("deflate", query)
        if path == "/brotli":
            return self._compressed("br", query)
        if path == "/zstd":
            return self._compressed("zstd", query)
        if path == "/unknown-encoding":
            return self._unknown_encoding()
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
        if remaining <= 1:
            return self._redirect("/get", 302)
        return self._redirect("/redirect/%d" % (remaining - 1), 302)

    def _redirect(self, location, code):
        # The body is read even though nothing looks at it. A redirect is
        # usually the answer to a POST, and leaving the body on the socket
        # means the next request on that connection starts by parsing it as a
        # request line, which comes back as a 501 with no obvious cause.
        self._read_body()
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

    def _digest_auth(self, qop, user, password, algorithm):
        # `/digest-auth/<qop>/<user>/<password>[/<algorithm>]`, as httpbin has
        # it. A qop of `none` means the RFC 2069 shape with no client nonce,
        # which some old servers still speak.
        self._read_body()
        header = self.headers.get("authorization")
        if header and self._digest_ok(header, qop, user, password, algorithm):
            return self._json(
                {
                    "authenticated": True,
                    "user": user,
                    "cookies": self._cookies_dict(),
                }
            )

        challenge = (
            'Digest realm="%s", nonce="%s", opaque="%s", algorithm=%s'
            % (DIGEST_REALM, DIGEST_NONCE, DIGEST_OPAQUE, algorithm)
        )
        if qop != "none":
            challenge += ', qop="%s"' % qop
        body = b'{"authenticated": false}'
        self.send_response(401)
        self.send_header("WWW-Authenticate", challenge)
        # A cookie on the challenge, because a real digest server often pins the
        # session to one and a client that drops it on the retry gets challenged
        # forever. The success route echoes the cookies back so a test can see
        # whether it survived.
        self.send_header("Set-Cookie", "digest-session=opened; Path=/")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _digest_ok(self, header, qop, user, password, algorithm):
        # Verified with Python's own header parser and hashlib rather than with
        # anything of ours. A check written against our own implementation would
        # agree with whatever mistake it made.
        import hashlib
        from urllib.request import parse_http_list, parse_keqv_list

        scheme, _, rest = header.partition(" ")
        if scheme.lower() != "digest":
            return False
        fields = parse_keqv_list(parse_http_list(rest))

        hashes = {
            "md5": hashlib.md5,
            "sha": hashlib.sha1,
            "sha-256": hashlib.sha256,
            "sha-512": hashlib.sha512,
        }
        name = algorithm.lower()
        session = name.endswith("-sess")
        if session:
            name = name[: -len("-sess")]
        if name not in hashes:
            return False

        def digest(text):
            return hashes[name](text.encode("utf-8")).hexdigest()

        if fields.get("username") != user:
            return False
        if fields.get("nonce") != DIGEST_NONCE:
            return False
        if fields.get("realm") != DIGEST_REALM:
            return False
        if fields.get("opaque") != DIGEST_OPAQUE:
            return False
        if fields.get("uri") != self.path:
            return False

        ha1 = digest("%s:%s:%s" % (user, DIGEST_REALM, password))
        if session:
            ha1 = digest(
                "%s:%s:%s" % (ha1, DIGEST_NONCE, fields.get("cnonce", ""))
            )
        ha2 = digest("%s:%s" % (self.command, fields.get("uri", "")))

        if qop == "none":
            if "qop" in fields:
                return False
            want = digest("%s:%s:%s" % (ha1, DIGEST_NONCE, ha2))
        else:
            if fields.get("qop") != "auth":
                return False
            want = digest(
                ":".join(
                    [
                        ha1,
                        DIGEST_NONCE,
                        fields.get("nc", ""),
                        fields.get("cnonce", ""),
                        "auth",
                        ha2,
                    ]
                )
            )
        return fields.get("response") == want

    def _set_cookies(self, query):
        self._read_body()
        self.send_response(302)
        self.send_header("Location", "/cookies")
        self.send_header("Content-Length", "0")
        for name, values in query.items():
            self.send_header("Set-Cookie", "%s=%s; Path=/" % (name, values[0]))
        self.end_headers()

    def _delete_cookies(self, query):
        # Expiring a cookie is how a server deletes one, so this sends the same
        # header a real logout endpoint would.
        self._read_body()
        self.send_response(302)
        self.send_header("Location", "/cookies")
        self.send_header("Content-Length", "0")
        for name in query:
            self.send_header("Set-Cookie", "%s=; Path=/; Max-Age=0" % name)
        self.end_headers()

    def _set_cookie_raw(self, query):
        # One Set-Cookie per `value`, verbatim, so a test can reach attributes
        # the tidier route does not: Secure, Max-Age, a narrow Path, a Domain
        # that ought to be refused.
        self._read_body()
        body = json.dumps({"cookies": self._cookies_dict()}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        for value in query.get("value", []):
            self.send_header("Set-Cookie", value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _compressed(self, encoding, query=None):
        self._read_body()
        size = int((query or {}).get("size", ["0"])[0])
        if size > 0:
            # Large enough that the body arrives in several reads, so the
            # decoder is exercised across chunk boundaries instead of being
            # handed the whole thing in one pass.
            unit = b"the quick brown fox jumps. "
            raw = (unit * (size // len(unit) + 1))[:size]
            content_type = "text/plain"
        else:
            raw = json.dumps(
                {"compressed": True, "encoding": encoding}
            ).encode()
            content_type = "application/json"
        if encoding == "gzip":
            payload = gzip.compress(raw)
        elif encoding == "br":
            if brotli is None:
                return self._no_compressor("br", "the brotli package")
            payload = brotli.compress(raw)
        elif encoding == "zstd":
            if zstd is None:
                return self._no_compressor("zstd", "a zstd module")
            payload = zstd.compress(raw)
        else:
            payload = zlib.compress(raw)
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Encoding", encoding)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def _no_compressor(self, encoding, package):
        """This Python cannot make that coding, said in the status line.

        501 rather than a traceback, so the test that wanted it fails saying
        what is missing rather than failing as a dropped connection.
        """
        self._read_body()
        body = ("no %s here, %s is not installed" % (encoding, package)).encode()
        self.send_response(501)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _unknown_encoding(self):
        """A coding no client asked for, which every client should refuse.

        `exi` is a real registered content coding for a binary XML format, and
        no HTTP client implements it, so it stands for the general case: a name
        that is in the registry and is not something we can undo. The bytes are
        not exi either, and that is the point: a client that reads the header
        never gets as far as looking at them.
        """
        self._read_body()
        payload = b"this was never exi"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Encoding", "exi")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if self.command != "HEAD":
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

    # socketserver listens with a backlog of five. The async tests open every
    # connection in a batch before any of them is answered, so a batch bigger
    # than five overflows the accept queue, and an overflowed queue on Linux
    # drops the SYN rather than refusing it. The client then waits a full TCP
    # retransmit, about a second, and a test measuring whether requests overlap
    # measures the kernel's retry timer instead. Nothing about the library.
    request_queue_size = 256

    verbose = False

    def __init__(self, *args, **kwargs):
        ThreadingHTTPServer.__init__(self, *args, **kwargs)
        self._conn_counter = itertools.count(1)
        self._conn_lock = threading.Lock()

    def next_conn_id(self):
        with self._conn_lock:
            return next(self._conn_counter)


CERT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(__file__)), "fixtures", "tls"
)


def wrap_in_tls(server):
    """Put the test certificate in front of an already listening server.

    Wrapping the listening socket rather than each accepted one, which is what
    `ssl` is built for and what keeps `serve_forever` unchanged. The port has
    already been chosen and reported by the time this runs, so a test learns the
    port the same way whether or not TLS is on.
    """
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(
        os.path.join(CERT_DIR, "server.pem"),
        os.path.join(CERT_DIR, "server.key"),
    )
    # http/1.1 only, and said out loud rather than left to the default. Our
    # client offers h2 as well on an https connection, and a server that stayed
    # quiet about ALPN would leave the client to guess, which is the one thing
    # ALPN exists to stop.
    ctx.set_alpn_protocols(["http/1.1"])
    server.socket = ctx.wrap_socket(server.socket, server_side=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--tls", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    server = Server((args.host, args.port), Handler)
    server.verbose = args.verbose
    if args.tls:
        wrap_in_tls(server)
    print("PORT %d" % server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
