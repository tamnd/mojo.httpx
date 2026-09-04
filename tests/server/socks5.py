"""A small SOCKS5 proxy for the test suite. RFC 1928 and RFC 1929.

Python has no SOCKS server anywhere in its standard library, so this is the one
piece of the test rig that had to be written from the RFC rather than borrowed.
It is still worth having in Python for the reason the HTTP proxy is: a proxy
built out of our own encoder would agree with our client about whatever both of
them got wrong, and what is being tested is that something written from the
specification accepts what we send.

`--resolve NAME=ADDRESS` is what the interesting test is built on. A name in that
table is answered from the table, and a client that resolved the target locally
would never have sent the name in the first place and would fail on a host that
does not exist. So a request for a mapped name arriving here is proof that the
name went over the wire, which is the property this milestone is about.

`--auth user:pass` makes it demand the username and password method, `--forbid
host:port` makes it answer a request for one destination with reply code 2, and
`--bound ipv4|ipv6|domain` chooses the form of the bound address on a successful
reply. That last one exists because the bound address is the only variable length
field in the reply, so a client that skipped it wrongly would leave bytes on the
socket and break the first thing to read afterwards, which is usually a TLS
handshake and is a long way from the mistake.

Run it with `--port 0` and it prints `PORT <n>` on stdout once it is listening,
the same handshake `server.py` and `proxy.py` use and for the same reason.
"""

from __future__ import annotations

import argparse
import select
import socket
import socketserver
import sys

VERSION = 5
AUTH_VERSION = 1

NO_AUTH = 0x00
USERNAME_PASSWORD = 0x02
NO_ACCEPTABLE_METHOD = 0xFF

CONNECT_COMMAND = 0x01

ATYP_IPV4 = 0x01
ATYP_DOMAIN = 0x03
ATYP_IPV6 = 0x04

SUCCEEDED = 0x00
NOT_ALLOWED = 0x02
HOST_UNREACHABLE = 0x04
COMMAND_NOT_SUPPORTED = 0x07
ADDRESS_NOT_SUPPORTED = 0x08


def _recv_exactly(sock, count):
    """Exactly `count` bytes, or None if the client stopped before that.

    Every field here is fixed length once the one before it has been read, so a
    short read is a client that went away rather than a message that ended.
    """
    out = b""
    while len(out) < count:
        try:
            chunk = sock.recv(count - len(out))
        except OSError:
            return None
        if not chunk:
            return None
        out += chunk
    return out


def _splice(left, right):
    """Copy bytes each way until one side stops, then stop.

    The same select loop as the HTTP proxy's, for the same reason: two threads
    would need a way to tell each other to stop, and getting that wrong leaves a
    thread per tunnel alive for the length of the test run.
    """
    both = [left, right]
    while both:
        ready, _, bad = select.select(both, [], both, 10)
        if bad or not ready:
            return
        for sock in ready:
            other = right if sock is left else left
            try:
                chunk = sock.recv(65536)
            except OSError:
                return
            if not chunk:
                return
            try:
                other.sendall(chunk)
            except OSError:
                return


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        sock = self.request
        try:
            self._serve(sock)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _serve(self, sock):
        if not self._greet(sock):
            return
        target = self._read_request(sock)
        if target is None:
            return
        host, port = target

        if self.server.forbidden == "%s:%d" % (host, port):
            self._reply(sock, NOT_ALLOWED)
            return

        # The whole point of the mapping. A name that got this far was sent as a
        # name, so answering it from the table is answering it at the proxy.
        address = self.server.resolve.get(host, host)
        try:
            upstream = socket.create_connection((address, port), timeout=10)
        except OSError as reason:
            self._log("cannot reach %s:%d: %s" % (host, port, reason))
            self._reply(sock, HOST_UNREACHABLE)
            return

        self._reply(sock, SUCCEEDED)
        try:
            _splice(sock, upstream)
        finally:
            upstream.close()

    def _greet(self, sock):
        head = _recv_exactly(sock, 2)
        if head is None or head[0] != VERSION:
            return False
        methods = _recv_exactly(sock, head[1])
        if methods is None:
            return False

        if self.server.credential is not None:
            if USERNAME_PASSWORD not in methods:
                sock.sendall(bytes([VERSION, NO_ACCEPTABLE_METHOD]))
                return False
            sock.sendall(bytes([VERSION, USERNAME_PASSWORD]))
            return self._authenticate(sock)

        if NO_AUTH not in methods:
            sock.sendall(bytes([VERSION, NO_ACCEPTABLE_METHOD]))
            return False
        sock.sendall(bytes([VERSION, NO_AUTH]))
        return True

    def _authenticate(self, sock):
        head = _recv_exactly(sock, 2)
        if head is None or head[0] != AUTH_VERSION:
            return False
        username = _recv_exactly(sock, head[1])
        length = _recv_exactly(sock, 1)
        if username is None or length is None:
            return False
        password = _recv_exactly(sock, length[0])
        if password is None:
            return False

        if (username, password) != self.server.credential:
            self._log("refusing %r" % (username,))
            sock.sendall(bytes([AUTH_VERSION, 1]))
            return False
        sock.sendall(bytes([AUTH_VERSION, 0]))
        return True

    def _read_request(self, sock):
        head = _recv_exactly(sock, 4)
        if head is None or head[0] != VERSION:
            return None
        if head[1] != CONNECT_COMMAND:
            self._reply(sock, COMMAND_NOT_SUPPORTED)
            return None

        kind = head[3]
        if kind == ATYP_IPV4:
            raw = _recv_exactly(sock, 4)
            host = socket.inet_ntoa(raw) if raw else None
        elif kind == ATYP_IPV6:
            raw = _recv_exactly(sock, 16)
            host = socket.inet_ntop(socket.AF_INET6, raw) if raw else None
        elif kind == ATYP_DOMAIN:
            length = _recv_exactly(sock, 1)
            if length is None:
                return None
            raw = _recv_exactly(sock, length[0])
            host = raw.decode("ascii", "replace") if raw else None
        else:
            self._reply(sock, ADDRESS_NOT_SUPPORTED)
            return None

        port = _recv_exactly(sock, 2)
        if host is None or port is None:
            return None
        self._log("connect to %s:%d" % (host, int.from_bytes(port, "big")))
        return (host, int.from_bytes(port, "big"))

    def _reply(self, sock, code):
        """The reply, with the bound address in whichever form was asked for.

        The address is zeros in every form. It is the proxy's own end of the
        connection it made, which matters to a `BIND` and to nothing here, and a
        client that read the length right does not care what the bytes were.
        """
        out = bytes([VERSION, code, 0])
        if self.server.bound == "ipv6":
            out += bytes([ATYP_IPV6]) + bytes(16)
        elif self.server.bound == "domain":
            name = b"proxy.invalid"
            out += bytes([ATYP_DOMAIN, len(name)]) + name
        else:
            out += bytes([ATYP_IPV4]) + bytes(4)
        out += bytes(2)
        sock.sendall(out)

    def _log(self, message):
        if self.server.verbose:
            sys.stderr.write("socks5: %s\n" % message)


class Socks5(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 256

    verbose = False

    credential = None
    """The exact `(username, password)` pair to demand, or None to demand none.

    Bytes rather than text, because RFC 1929 carries them as bytes and the point
    of comparing them here is to compare what actually arrived.
    """

    forbidden = None
    """A `host:port` to answer with reply code 2, or None to refuse none."""

    bound = "ipv4"
    """The form of the bound address on a successful reply."""

    resolve = {}
    """Names this proxy answers itself, mapped to an address to connect to."""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--auth", default=None, help="user:pass to demand")
    parser.add_argument(
        "--forbid", default=None, help="host:port to answer with reply code 2"
    )
    parser.add_argument(
        "--bound",
        default="ipv4",
        choices=["ipv4", "ipv6", "domain"],
        help="the form of the bound address on a successful reply",
    )
    parser.add_argument(
        "--resolve",
        action="append",
        default=[],
        help="NAME=ADDRESS, answered here rather than looked up",
    )
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    proxy = Socks5((args.host, args.port), Handler)
    proxy.verbose = args.verbose
    if args.auth is not None:
        username, _, password = args.auth.partition(":")
        proxy.credential = (username.encode("utf-8"), password.encode("utf-8"))
    proxy.forbidden = args.forbid
    proxy.bound = args.bound
    proxy.resolve = {}
    for mapping in args.resolve:
        name, _, address = mapping.partition("=")
        proxy.resolve[name] = address
    print("PORT %d" % proxy.server_address[1], flush=True)
    try:
        proxy.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
