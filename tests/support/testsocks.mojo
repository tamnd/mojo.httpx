"""Starting and stopping the local SOCKS5 proxy.

The proxy itself is `tests/server/socks5.py`, and the note at the top of that
file explains what it does and what each switch is for. This is the part that
runs it: one process per test, on a port the kernel picks, torn down when the
value goes out of scope.

The same shape as `TestProxy` and deliberately not shared with it, for the reason
given there. The same warning about lifetimes applies too. Mojo ends a value's
life at its last use, so a test that reads the proxy's address and then makes the
request has shut the proxy down before the request goes out. Pass the proxy into
whatever makes the request.
"""

from std.python import Python, PythonObject

from tests.support.testserver import port_from

comptime SOCKS_SCRIPT = "tests/server/socks5.py"
"""Relative to the repository root, which is where the test runner runs."""


struct TestSocks(Movable):
    """A live SOCKS5 proxy on loopback, for as long as this value exists."""

    var host: String
    var port: UInt16
    var _proc: PythonObject
    var _running: Bool

    def __init__(
        out self,
        auth: StringSpan = "",
        forbid: StringSpan = "",
        bound: StringSpan = "",
        resolve: StringSpan = "",
        host: StringSpan = "127.0.0.1",
    ) raises:
        """A proxy, with whichever of its behaviours the test needs.

        `auth` is `user:pass` to demand, `forbid` is a `host:port` to refuse,
        `bound` is the form of the bound address to answer with, and `resolve`
        is a `NAME=ADDRESS` this proxy answers itself. That last one is how a
        test can tell that a name went over the wire rather than through the
        local resolver: an unresolvable name that works is a name the proxy
        looked up.
        """
        var sub = Python.import_module("subprocess")
        var sys = Python.import_module("sys")

        var argv = Python.list()
        argv.append(sys.executable)
        argv.append(SOCKS_SCRIPT)
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
        if len(bound.as_bytes()) > 0:
            argv.append("--bound")
            argv.append(String(bound))
        if len(resolve.as_bytes()) > 0:
            argv.append("--resolve")
            argv.append(String(resolve))

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
        return String("socks5://", self.host, ":", self.port)

    def url_with(self, username: StringSpan, password: StringSpan) -> String:
        """The same address with credentials in it, the way an environment
        variable carries them."""
        return String(
            "socks5://", username, ":", password, "@", self.host, ":", self.port
        )
