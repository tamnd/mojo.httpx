"""Starting and stopping the local forward proxy.

The proxy itself is `tests/server/proxy.py`, and the note at the top of that file
explains what it does and what it refuses. This is the part that runs it: one
process per test, on a port the kernel picks, torn down when the value goes out
of scope.

Nearly the same shape as `TestServer`, and deliberately not shared with it. The
two differ in what they take on the command line and in what a test does with
them, and a common base whose only job was to hold a `Popen` would make both of
them harder to read than the twenty lines it saved.

The same warning about lifetimes applies here as there. Mojo ends a value's life
at its last use, so a test that reads the proxy's address and then makes the
request has shut the proxy down before the request goes out. Pass the proxy into
whatever makes the request.
"""

from std.python import Python, PythonObject

from tests.support.testserver import port_from

comptime PROXY_SCRIPT = "tests/server/proxy.py"
"""Relative to the repository root, which is where the test runner runs."""


struct TestProxy(Movable):
    """A live forward proxy on loopback, for as long as this value exists."""

    var host: String
    var port: UInt16
    var _proc: PythonObject
    var _running: Bool

    def __init__(
        out self,
        auth: StringSpan = "",
        forbid: StringSpan = "",
        host: StringSpan = "127.0.0.1",
    ) raises:
        """A proxy, demanding `auth` as `user:pass` if it is not empty.

        `forbid` is a `host:port` this proxy answers a CONNECT to with a 403,
        which is how a proxy that will not reach a destination says so and is
        the only interesting failure a tunnel has that forwarding does not.
        """
        var sub = Python.import_module("subprocess")
        var sys = Python.import_module("sys")

        var argv = Python.list()
        argv.append(sys.executable)
        argv.append(PROXY_SCRIPT)
        argv.append("--host")
        argv.append(String(host))
        argv.append("--port")
        argv.append("0")
        if len(auth.as_bytes()) > 0:
            argv.append("--auth")
            argv.append(String(auth))
        if len(forbid.as_bytes()) > 0:
            argv.append("--forbid")
            argv.append(String(forbid))

        self.host = String(host)
        self._proc = sub.Popen(argv, stdout=sub.PIPE)
        self._running = True
        var line = String(self._proc.stdout.readline().decode("utf-8"))
        self.port = port_from(line)

    def __moveinit__(out self, deinit other: Self):
        self.host = other.host^
        self.port = other.port
        self._proc = other._proc^
        self._running = other._running
        other._running = False

    def __deinit__(deinit self):
        if self._running:
            # Swallowed rather than reported, so that a destructor cannot
            # replace whatever the test was actually failing on.
            try:
                self._proc.terminate()
                _ = self._proc.wait()
            except:
                pass

    def stop(mut self):
        """End the proxy now rather than when this value is dropped."""
        if not self._running:
            return
        self._running = False
        try:
            self._proc.terminate()
            _ = self._proc.wait()
        except:
            pass

    def url(self) -> String:
        """What to hand `Proxy(...)`."""
        return String("http://", self.host, ":", self.port)

    def url_with(self, username: StringSpan, password: StringSpan) -> String:
        """The same address with credentials in it, the way an environment
        variable carries them."""
        return String(
            "http://", username, ":", password, "@", self.host, ":", self.port
        )
