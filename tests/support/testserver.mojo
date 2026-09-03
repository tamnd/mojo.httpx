"""Starting and stopping the local test server.

The server itself is `tests/server/server.py`, and the note at the top of that
file explains why it is Python. This is the part that runs it: one process per
test, on a port the kernel picks, torn down when the value goes out of scope.

The readiness handshake is the first line of the server's stdout, which it
writes once it is listening and which carries the port. Waiting for that line
rather than sleeping is what keeps this from being the flaky part of the suite,
and taking the port from it is what lets tests run in parallel and in any order
without agreeing on a number in advance.
"""

from std.python import Python, PythonObject

from httpx._exceptions import ErrorKind, new_error

comptime SERVER_SCRIPT = "tests/server/server.py"
"""Relative to the repository root, which is where the test runner runs."""


struct TestServer(Movable):
    """A live HTTP server on loopback, for as long as this value exists."""

    var host: String
    var port: UInt16
    var _proc: PythonObject
    var _running: Bool

    def __init__(out self, host: StringSpan = "127.0.0.1") raises:
        var sub = Python.import_module("subprocess")
        var sys = Python.import_module("sys")

        var argv = Python.list()
        argv.append(sys.executable)
        argv.append(SERVER_SCRIPT)
        argv.append("--host")
        argv.append(String(host))
        argv.append("--port")
        argv.append("0")

        self.host = String(host)
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
        return String("http://", self.host, ":", self.port, path)

    def authority(self) -> String:
        return String(self.host, ":", self.port)


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
