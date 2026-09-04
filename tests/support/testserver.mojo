"""Starting and stopping the local test server.

The server itself is `tests/server/server.py`, and the note at the top of that
file explains why it is Python. This is the part that runs it: one process per
test, on a port the kernel picks, torn down when the value goes out of scope.

The readiness handshake is the first line of the server's stdout, which it
writes once it is listening and which carries the port. Waiting for that line
rather than sleeping is what keeps this from being the flaky part of the suite,
and taking the port from it is what lets tests run in parallel and in any order
without agreeing on a number in advance.

`TestServer(tls=True)` serves the same routes over https with the self signed
certificate in `tests/fixtures/tls`. A client talking to it has to be told to trust
that certificate, which `tls_verify()` returns, because the whole point of the
certificate check is that a client does not trust a name it has never heard of.
"""

from std.python import Python, PythonObject

from httpx._exceptions import ErrorKind, new_error
from httpx._stream.config import SSLVerify

comptime SERVER_SCRIPT = "tests/server/server.py"
"""Relative to the repository root, which is where the test runner runs."""

comptime SERVER_CERT = "tests/fixtures/tls/server.pem"
"""The certificate `--tls` serves, which is also its own trust anchor."""


struct TestServer(Movable):
    """A live HTTP server on loopback, for as long as this value exists."""

    var host: String
    var port: UInt16
    var tls: Bool
    var _proc: PythonObject
    var _running: Bool

    def __init__(out self, tls: Bool = False, host: StringSpan = "") raises:
        """A server on loopback, over https if `tls` is set.

        The default host depends on `tls`. A plain server is addressed by its
        address, and an https one by the name `localhost`, because that is the
        name on the certificate and a certificate checked against a name nobody
        put on it is the check not happening.
        """
        var name = String(host)
        if name == "":
            name = String("localhost") if tls else String("127.0.0.1")

        var sub = Python.import_module("subprocess")
        var sys = Python.import_module("sys")

        var argv = Python.list()
        argv.append(sys.executable)
        argv.append(SERVER_SCRIPT)
        argv.append("--host")
        argv.append(name)
        argv.append("--port")
        argv.append("0")
        if tls:
            argv.append("--tls")

        self.host = name^
        self.tls = tls
        self._proc = sub.Popen(argv, stdout=sub.PIPE)
        self._running = True

        # Blocks until the server says it is listening. If the server dies
        # instead, the pipe closes and this comes back empty rather than
        # hanging, which turns a broken server into a readable failure.
        var line = String(self._proc.stdout.readline().decode("utf-8"))
        self.port = port_from(line)

    def __moveinit__(out self, deinit other: Self):
        self.host = other.host^
        self.port = other.port
        self.tls = other.tls
        self._proc = other._proc^
        self._running = other._running
        other._running = False

    def __deinit__(deinit self):
        if self._running:
            # Swallowed rather than reported. A destructor that raised would
            # replace whatever the test was actually failing on.
            try:
                self._proc.terminate()
                _ = self._proc.wait()
            except:
                pass

    def stop(mut self):
        """End the server now rather than when this value is dropped.

        Needed by any test that asserts on what happens after the server is
        gone, and by any test that would otherwise keep it alive to the end of
        the function through a later use.
        """
        if not self._running:
            return
        self._running = False
        try:
            self._proc.terminate()
            _ = self._proc.wait()
        except:
            pass
        self._wait_until_refused()

    def _wait_until_refused(mut self):
        """Block until the port stops accepting, which it does once the server
        process is really gone.

        `wait` reaps the process, so the kernel has closed its sockets, but the
        FIN on a connection that is already open still has to be delivered. A
        test that asserts on what happens after the server is gone was racing
        that delivery: the pool would check an idle connection, find it not yet
        readable, hand it out, and the request would fail as a truncated
        response rather than as the connect error the test was written for.

        One refused connection is proof the delivery has happened, because it
        cannot be refused until the listening socket is gone, and the listening
        socket and the FINs go at the same moment.
        """
        try:
            var socket = Python.import_module("socket")
            var target = Python.tuple(self.host, Int(self.port))
            var at = 0
            while at < 200:
                try:
                    var probe = socket.create_connection(target, 0.05)
                    probe.close()
                except:
                    return
                at += 1
        except:
            pass

    def url(self, path: StringSpan) -> String:
        """The address of `path` on this server.

        Watch where the last use of the server falls. Mojo ends a value's life
        at its last use, so a test that calls this and then makes the request
        has already shut the server down by the time the request goes out, and
        the failure is a connection refused on a port that existed a moment
        ago. Pass the server into whatever makes the request, so that it stays
        borrowed until the call returns.
        """
        return String(self.scheme(), "://", self.host, ":", self.port, path)

    def scheme(self) -> String:
        return String("https") if self.tls else String("http")

    def authority(self) -> String:
        return String(self.host, ":", self.port)

    @staticmethod
    def tls_verify() -> SSLVerify:
        """What to pass as `verify=` to reach a `tls=True` server.

        The certificate is self signed and is its own trust anchor, so the file
        the server presents is also the file a client verifies it against. There
        is no `verify=False` anywhere in the suite on purpose: a test that turned
        verification off would pass just as happily against a client that never
        checked anything.
        """
        return SSLVerify.from_file(String(SERVER_CERT))


def port_from(line: StringSpan) raises -> UInt16:
    """Read the port out of a `PORT <n>` greeting.

    Shared with `TestProxy`, which speaks the same handshake, so this is public
    rather than private to this module.
    """
    var text = String(line).strip()
    if not text.startswith("PORT "):
        raise new_error(
            ErrorKind.CONNECT_ERROR,
            String(
                "the test server did not report a port, it said '", text, "'"
            ),
        )
    return UInt16(Int(String(text[byte=5:]).strip()))
