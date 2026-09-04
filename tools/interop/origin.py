"""The HTTP/1.1 origin that both interop suites put something in front of.

The HTTP/2 suite runs four front ends over it and the proxy suite runs four
proxies to it. One origin rather than one per server, because what is being
tested is the protocol each server speaks and not how each one serves a file,
and giving them all the same answers to give is what makes one case table apply
to all of them. A difference in a result is then a difference in the protocol
handling and not a difference in what nginx and Caddy think a directory listing
looks like.

It speaks HTTP/1.1 and nothing else. The front end is what turns it into HTTP/2,
which is also how almost every HTTP/2 deployment in the world is actually put
together, and a forward proxy leaves it as it is.
"""

from __future__ import annotations

import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = 8080


class Handler(BaseHTTPRequestHandler):
    # Keep alive, because the front ends hold one upstream connection and
    # reconnecting per request would hide a failure to reuse them.
    protocol_version = "HTTP/1.1"

    # The default logs every request to stderr, which buries the suite's own
    # output in a container log nobody asked for.
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        self.answer(read_body=False)

    def do_POST(self):
        self.answer(read_body=True)

    def do_PUT(self):
        self.answer(read_body=True)

    def do_HEAD(self):
        self.answer(read_body=False)

    def answer(self, read_body: bool):
        url = urlparse(self.path)
        path = url.path
        query = parse_qs(url.query)

        body = self.read_body() if read_body else b""

        if path == "/get":
            self.send_json(
                {
                    "method": self.command,
                    "path": self.path,
                    "headers": {k.lower(): v for k, v in self.headers.items()},
                }
            )
            return

        if path == "/echo":
            kind = self.headers.get("content-type") or "application/octet-stream"
            self.send_bytes(200, body, kind)
            return

        if path.startswith("/status/"):
            self.send_status(int(path.rsplit("/", 1)[1]))
            return

        if path.startswith("/bytes/"):
            count = int(path.rsplit("/", 1)[1])
            self.send_bytes(200, b"a" * count, "application/octet-stream")
            return

        if path.startswith("/headers/"):
            self.send_many_headers(int(path.rsplit("/", 1)[1]))
            return

        if path == "/drip":
            self.send_drip(
                int((query.get("chunks") or ["16"])[0]),
                float((query.get("delay") or ["0.01"])[0]),
            )
            return

        if path == "/redirect":
            self.send_response(302)
            self.send_header("location", "/get")
            self.send_header("content-length", "0")
            self.end_headers()
            return

        self.send_status(404)

    def read_body(self) -> bytes:
        """The request body, however the front end chose to frame this hop.

        There is no chunked encoding in HTTP/2, so a client that streams a body
        sends no length, and a front end proxying that upstream has nothing to
        frame it with but chunked. Reading only the content-length case would
        make a streamed upload arrive here as an empty one, and the case that
        checks it would pass against a client that sent nothing at all.
        """
        encoding = (self.headers.get("transfer-encoding") or "").lower()
        if "chunked" not in encoding:
            length = int(self.headers.get("content-length") or 0)
            return self.rfile.read(length) if length else b""

        pieces = []
        while True:
            size = int(self.rfile.readline().split(b";")[0], 16)
            if size == 0:
                break
            pieces.append(self.rfile.read(size))
            self.rfile.read(2)
        # The terminal chunk is followed by trailers and then a blank line, and
        # leaving those unread would leave the next request on this connection
        # starting in the middle of the last one.
        while self.rfile.readline() not in (b"\r\n", b"\n", b""):
            pass
        return b"".join(pieces)

    def send_json(self, payload: dict):
        self.send_bytes(
            200, json.dumps(payload).encode("utf-8"), "application/json"
        )

    def send_bytes(self, status: int, body: bytes, kind: str):
        self.send_response(status)
        self.send_header("content-type", kind)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_status(self, status: int):
        self.send_response(status)
        # 204 and 304 carry no body and no length. Sending a length of zero on
        # one of those is a thing some front ends pass through and others
        # refuse, which would be this origin's bug and not the front end's.
        if status not in (204, 304):
            self.send_header("content-length", "0")
        self.end_headers()

    def send_many_headers(self, count: int):
        self.send_response(200)
        self.send_header("content-type", "text/plain")
        self.send_header("content-length", "2")
        for i in range(count):
            # A repeated name and a repeated value, so an HPACK encoder in front
            # of this has something worth indexing and the dynamic table on the
            # client side actually gets used.
            self.send_header(f"x-test-{i}", "value")
            self.send_header("x-repeated", "same")
        self.end_headers()
        self.wfile.write(b"ok")

    def send_drip(self, chunks: int, delay: float):
        """A body sent in pieces, with a pause between them.

        The front end has no length to give, so it has to stream, which is what
        turns one response into many DATA frames on the wire. A client that only
        works when the whole body arrives at once passes every other case here
        and fails this one.
        """
        self.send_response(200)
        self.send_header("content-type", "text/plain")
        self.send_header("transfer-encoding", "chunked")
        self.end_headers()
        for _ in range(chunks):
            self.wfile.write(b"4\r\ndrip\r\n")
            self.wfile.flush()
            time.sleep(delay)
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


def main() -> int:
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"origin listening on {PORT}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
