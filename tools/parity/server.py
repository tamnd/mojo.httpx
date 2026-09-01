"""The recording server both clients talk to.

It reads one request per connection, writes the answer the case asked for, and
keeps the bytes it received exactly as they arrived. Nothing is normalized here.
Everything this hands back is what came off the socket, because the whole
comparison rests on that being true.

One request per connection is on purpose. Almost every canned reply says
`Connection: close`, so neither client can reuse a connection and the server
never has to decide where one request ended and the next began. That removes the
only part of this file that could disagree with the clients about framing, and
the request bytes are unaffected either way.

The exception is the framing cases, which are about a body the server ends by
closing. Those still get one connection each, because closing is how they end.
"""

import socket
import threading


class Recorder:
    def __init__(self, replies_for):
        """`replies_for(name)` gives the list of answers for one case."""
        self._replies_for = replies_for
        self._sock = socket.socket()
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind(("127.0.0.1", 0))
        self._sock.listen(64)
        self._sock.settimeout(0.2)
        self.port = self._sock.getsockname()[1]
        self.records = []
        self.problems = []
        self._hits = {}
        self._running = True
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    @property
    def base(self):
        return "http://127.0.0.1:%d" % self.port

    def reset(self):
        self.records = []
        self.problems = []
        self._hits = {}

    def stop(self):
        self._running = False
        self._thread.join(timeout=5)
        self._sock.close()

    def _serve(self):
        while self._running:
            try:
                conn, _ = self._sock.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            try:
                self._handle(conn)
            finally:
                try:
                    conn.close()
                except OSError:
                    pass

    def _handle(self, conn):
        conn.settimeout(10.0)
        raw = _read_request(conn)
        if not raw:
            return
        name = _case_name(raw)
        if name is None:
            self.problems.append("a request arrived with no case in its path")
            return
        replies = self._replies_for(name)
        if replies is None:
            self.problems.append("a request arrived for unknown case " + name)
            return
        hit = self._hits.get(name, 0)
        self._hits[name] = hit + 1
        self.records.append((name, raw))
        try:
            conn.sendall(replies[min(hit, len(replies) - 1)])
        except OSError:
            # The client may already be gone, which is fine for a `HEAD` or for
            # a case that got what it needed from the head alone.
            pass


def _read_request(conn):
    buf = b""
    while b"\r\n\r\n" not in buf:
        try:
            piece = conn.recv(65536)
        except OSError:
            return buf
        if not piece:
            return buf
        buf += piece

    head, rest = buf.split(b"\r\n\r\n", 1)
    fields = {}
    for line in head.split(b"\r\n")[1:]:
        if b":" not in line:
            continue
        name, _, value = line.partition(b":")
        fields[name.strip().lower()] = value.strip()

    if fields.get(b"transfer-encoding", b"").lower() == b"chunked":
        while not rest.endswith(b"0\r\n\r\n"):
            piece = conn.recv(65536)
            if not piece:
                break
            rest += piece
    else:
        want = int(fields.get(b"content-length", b"0") or b"0")
        while len(rest) < want:
            piece = conn.recv(65536)
            if not piece:
                break
            rest += piece

    return head + b"\r\n\r\n" + rest


def _case_name(raw):
    line = raw.split(b"\r\n", 1)[0].decode("latin-1")
    parts = line.split(" ")
    if len(parts) < 2:
        return None
    target = parts[1]
    if not target.startswith("/s/"):
        return None
    return target[3:].split("/")[0].split("?")[0]
