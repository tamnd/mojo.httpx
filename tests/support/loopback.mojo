"""A loopback listener the tests drive by hand.

There are no threads in Mojo 1.0, so the tests cannot run a server in the
background and a client in the foreground. What they can do is drive both sides
from the same loop, and for the exchanges these tests need that is enough: a
request and a canned response both fit inside the kernel's socket buffers, so
each side can write its whole part without the other side reading yet.

Driving both ends by hand also removes the timing from the tests. A threaded
server would make every assertion about timeouts depend on how quickly the other
thread got scheduled, which is exactly the kind of test that passes on a laptop
and fails in CI at three in the morning.

The port is always zero at bind time and read back afterwards, so two test runs
on the same machine never collide.
"""

from std.ffi import c_int, c_size_t, c_ssize_t, c_uint

from httpx._exceptions import ErrorKind, new_error
from httpx._ffi.c import errno, strerror
from httpx._ffi.netdb import (
    AF_UNSPEC,
    SockAddr,
    bind_addr,
    getsockname,
    resolve,
)
from httpx._ffi.socket import (
    AF_INET,
    AF_INET6,
    POLLIN,
    POLLOUT,
    SOCK_STREAM,
    SOL_SOCKET,
    SO_REUSEADDR,
    PollFd,
    accept,
    close,
    listen,
    poll,
    recv,
    send,
    setsockopt_int,
    shutdown,
    socket,
    suppress_sigpipe,
)
from httpx._io.socket import start_connect

comptime LOOPBACK_V4 = "127.0.0.1"
comptime LOOPBACK_V6 = "::1"

comptime SPARE_LOOPBACK_V4 = "127.0.0.2"
"""A second loopback address, for the one case where the first one lies.

Every address in 127.0.0.0/8 is loopback and Linux configures the whole range,
so this is a real address there and under WSL2. macOS configures only
127.0.0.1, so it is not one there, which is why nothing uses this without
checking first. See `dead_address`.
"""

comptime REFUSAL_PROBE_MS = 250
"""How long a probe waits before deciding an address is not refusing.

Generous, because the answer only has to arrive faster than a person notices
and being wrong about it makes nine tests pass for the wrong reason. A refusal
on loopback arrives in microseconds, so the budget is only ever spent on an
address that is hanging, which is the case this exists to detect.
"""

comptime PROBE_SLICE_MS = 10
"""How long one poll inside a probe may block for. Small enough that the common
answer costs one slice and not the whole budget."""


struct Loopback(Movable):
    """A listening socket on loopback, with the port the kernel handed out."""

    var _fd: c_int
    var addr: SockAddr
    """Where to connect to reach this listener, port already filled in."""
    var port: UInt16

    def __init__(
        out self, host: StringSpan = LOOPBACK_V4, backlog: Int = 8
    ) raises:
        var candidates = resolve(host, 0, AF_UNSPEC)
        if len(candidates) == 0:
            raise new_error(
                ErrorKind.CONNECT_ERROR, String("no address for ", host)
            )
        var want = candidates[0]

        self._fd = socket(want.family, SOCK_STREAM, c_int(0))
        if self._fd < 0:
            raise new_error(
                ErrorKind.NETWORK_ERROR,
                String(
                    "could not open a listening socket: ", strerror(errno())
                ),
            )
        # Without this a test that runs twice in quick succession fails on the
        # second run, because the previous listener is still in TIME_WAIT.
        _ = setsockopt_int(self._fd, SOL_SOCKET, SO_REUSEADDR, c_int(1))
        _ = suppress_sigpipe(self._fd)

        if bind_addr(self._fd, want) != 0:
            var reason = strerror(errno())
            _ = close(self._fd)
            self._fd = c_int(-1)
            raise new_error(
                ErrorKind.NETWORK_ERROR, String("could not bind: ", reason)
            )
        if listen(self._fd, c_int(backlog)) != 0:
            var reason = strerror(errno())
            _ = close(self._fd)
            self._fd = c_int(-1)
            raise new_error(
                ErrorKind.NETWORK_ERROR, String("could not listen: ", reason)
            )

        # Port zero was a request, not an address. This is where it becomes one.
        var bound = getsockname(self._fd)
        self.port = bound.port()
        self.addr = want.with_port(self.port)

    def __moveinit__(out self, deinit other: Self):
        self._fd = other._fd
        self.addr = other.addr
        self.port = other.port
        other._fd = c_int(-1)

    def __deinit__(deinit self):
        if self._fd >= 0:
            _ = close(self._fd)

    def is_ipv6(self) -> Bool:
        return self.addr.family == AF_INET6

    def accept_within(mut self, ms: Int = 2000) raises -> Peer:
        """Take the next connection, or raise if none arrives in `ms`.

        The wait is bounded so that a bug in the code under test shows up as a
        failed assertion after two seconds rather than as a suite that hangs.
        """
        var fds = PollFd(self._fd, POLLIN, Int16(0))
        var ready = poll(Pointer(to=fds), c_uint(1), c_int(ms))
        if ready <= 0:
            raise new_error(
                ErrorKind.NETWORK_ERROR,
                String("nothing connected to the listener within ", ms, "ms"),
            )
        var fd = accept(self._fd)
        if fd < 0:
            raise new_error(
                ErrorKind.NETWORK_ERROR,
                String("accept failed: ", strerror(errno())),
            )
        _ = suppress_sigpipe(fd)
        return Peer(fd)

    def has_pending(self, ms: Int = 500) -> Bool:
        """Whether a connection is waiting to be accepted, or arrives shortly.

        This used to poll for zero milliseconds, on the grounds that the caller
        is asking about now. That was a race. A connect on loopback returns once
        the handshake is under way, and the listener's accept queue is filled a
        moment later on the other side of the kernel, so asking whether it had
        already happened lost often enough to fail three tests every few runs
        for no reason to do with the code under test.

        Half a second is far longer than a loopback handshake takes and still
        short enough that a client which never connected at all fails quickly.
        """
        var fds = PollFd(self._fd, POLLIN, Int16(0))
        return poll(Pointer(to=fds), c_uint(1), c_int(ms)) > 0

    def close(mut self):
        if self._fd >= 0:
            _ = close(self._fd)
            self._fd = c_int(-1)


struct Peer(Movable):
    """The server side of an accepted connection.

    Blocking, unlike everything in `httpx._io`. The client under test is the
    side that has to cope with a network that stalls, and the test server is the
    side that decides when it does, so blocking here keeps the tests readable.
    """

    var _fd: c_int

    def __init__(out self, fd: c_int):
        self._fd = fd

    def __moveinit__(out self, deinit other: Self):
        self._fd = other._fd
        other._fd = c_int(-1)

    def __deinit__(deinit self):
        if self._fd >= 0:
            _ = close(self._fd)

    def fd(self) -> c_int:
        return self._fd

    def ready(self, ms: Int = 0) -> Bool:
        """Whether a read would return something right now.

        For a test server that has to answer without blocking. Every other read
        here blocks, which is fine when the server side is the only thing on its
        worker, and not fine when a test runs more server tasks than the machine
        has workers: the client that still has to write would never get one.
        """
        var fds = PollFd(self._fd, POLLIN, Int16(0))
        return poll(Pointer(to=fds), c_uint(1), c_int(ms)) > 0

    def send_text(mut self, text: StringSpan) raises:
        """Write all of `text`, looping over short writes."""
        self.send_bytes(text.as_bytes())

    def send_bytes[o: ImmOrigin](mut self, bytes: Span[UInt8, o]) raises:
        """Write all of `bytes`, looping over short writes.

        The one a binary protocol needs. `send_text` cannot carry frames, since
        a Mojo string literal has to be valid UTF-8 and an HTTP/2 frame header
        is nine octets that very often are not.
        """
        var at = 0
        while at < bytes.__len__():
            var n = send(
                self._fd,
                Pointer(to=bytes[at]),
                c_size_t(bytes.__len__() - at),
                c_int(0),
            )
            if n <= 0:
                raise new_error(
                    ErrorKind.NETWORK_ERROR,
                    String("test server could not write: ", strerror(errno())),
                )
            at += Int(n)

    def recv_bytes(mut self, limit: Int = 65536) raises -> List[UInt8]:
        """Read whatever has arrived, once. Empty means the peer closed."""
        var buf = List[UInt8](length=limit, fill=0)
        var n = recv(self._fd, Pointer(to=buf[0]), c_size_t(limit), c_int(0))
        if n < 0:
            raise new_error(
                ErrorKind.NETWORK_ERROR,
                String("test server could not read: ", strerror(errno())),
            )
        var out = List[UInt8]()
        out.extend(Span(buf)[: Int(n)])
        return out^

    def recv_exactly(
        mut self, count: Int, ms: Int = 2000
    ) raises -> List[UInt8]:
        """Read exactly `count` octets, however many packets they arrive in.

        Raises rather than looping forever, because a test that hangs tells you
        nothing and a test that fails tells you where.
        """
        var out = List[UInt8]()
        var waited = 0
        while len(out) < count:
            if waited >= ms:
                raise new_error(
                    ErrorKind.NETWORK_ERROR,
                    String(
                        "test server waited for ",
                        count,
                        " bytes and saw ",
                        len(out),
                    ),
                )
            var fds = PollFd(self._fd, POLLIN, Int16(0))
            if poll(Pointer(to=fds), c_uint(1), c_int(10)) <= 0:
                waited += 10
                continue
            var piece = self.recv_bytes(count - len(out))
            if len(piece) == 0:
                break
            out.extend(piece^)
        return out^

    def recv_text(mut self, limit: Int = 65536) raises -> String:
        """Read whatever has arrived, once. Empty means the peer closed."""
        var buf = List[UInt8](length=limit, fill=0)
        var n = recv(self._fd, Pointer(to=buf[0]), c_size_t(limit), c_int(0))
        if n < 0:
            raise new_error(
                ErrorKind.NETWORK_ERROR,
                String("test server could not read: ", strerror(errno())),
            )
        return String(StringSpan(from_utf8=Span(buf)[: Int(n)]))

    def recv_until(
        mut self, marker: StringSpan, ms: Int = 2000
    ) raises -> String:
        """Read until `marker` appears, so a request split across packets reads
        as one. Raises rather than looping forever if it never arrives."""
        var seen = String()
        var waited = 0
        while marker not in seen:
            if waited >= ms:
                raise new_error(
                    ErrorKind.NETWORK_ERROR,
                    String("test server never saw the end of the message"),
                )
            var fds = PollFd(self._fd, POLLIN, Int16(0))
            if poll(Pointer(to=fds), c_uint(1), c_int(10)) <= 0:
                waited += 10
                continue
            var piece = self.recv_text()
            if piece.byte_length() == 0:
                break
            seen += piece
        return seen^

    def half_close(mut self):
        """Send a FIN without releasing the descriptor, so the client sees the
        end of the response while the socket is still readable from here."""
        _ = shutdown(self._fd, c_int(1))

    def close(mut self):
        if self._fd >= 0:
            _ = close(self._fd)
            self._fd = c_int(-1)


def dead_address(host: StringSpan = LOOPBACK_V4) raises -> SockAddr:
    """An address that refuses a connection, checked rather than assumed.

    Nine tests need a connect to fail promptly rather than time out, because a
    refusal and a timeout are different errors with different names and the
    assertions exist so that a broken deadline path cannot pass by looking like
    a refusal. What makes that hard is that there is no portable way to name an
    address which is guaranteed to refuse.

    The usual technique is the first half of this: bind a loopback listener,
    keep the port the kernel handed out, and close it. The number was real a
    moment ago so it is almost certainly still free, and on Linux and macOS
    connecting to it is refused at once.

    Under WSL2 it is not. A localhost relay sits between the guest and the
    Windows side, and it answers on 127.0.0.1 for a port that was recently
    bound, so the connect succeeds and the test fails for a reason that has
    nothing to do with the library. Issue 43 has the measurements.

    So the result is checked and there is a second technique behind it. The
    relay only stands in the way of 127.0.0.1: on any other loopback address a
    connect to a port that was never bound is refused properly, with
    ECONNREFUSED, the same as everywhere else. Reserving the number on
    127.0.0.1 and then offering it on 127.0.0.2 gets both halves, since the
    number is known to be free and was never bound on the address being handed
    out.

    That second address does not exist on macOS, where only 127.0.0.1 is
    configured on lo0 and a connect to 127.0.0.2 hangs rather than being
    refused, which is exactly why the fallback is second and is itself checked
    before being returned. Every host in the fleet gets the first technique
    except the one that cannot use it.

    A failure to find either raises with the reason, rather than handing back an
    address that answers. A test asserting on a refusal is worth nothing if the
    address it was given is alive, and a helper that quietly returns one turns
    nine real checks into nine that pass by accident.
    """
    var reserved = Loopback(host)
    var addr = reserved.addr
    var port = reserved.port
    reserved.close()
    if _refuses(addr):
        return addr

    if String(host) != LOOPBACK_V4:
        raise new_error(
            ErrorKind.NETWORK_ERROR,
            String(
                "a connect to ",
                host,
                ":",
                port,
                (
                    " was neither refused nor left pending, and there is no"
                    " second loopback address to fall back to for this family"
                ),
            ),
        )

    var spare = resolve(SPARE_LOOPBACK_V4, port, AF_UNSPEC)
    if len(spare) > 0 and _refuses(spare[0]):
        return spare[0]
    raise new_error(
        ErrorKind.NETWORK_ERROR,
        String(
            "no address on this machine refuses a connection: neither ",
            LOOPBACK_V4,
            ":",
            port,
            " nor ",
            SPARE_LOOPBACK_V4,
            ":",
            port,
            (
                " came back refused, so the tests that need a failing connect"
                " cannot be given one"
            ),
        ),
    )


def _refuses(addr: SockAddr) raises -> Bool:
    """Whether a connect to `addr` comes back refused within the probe budget.

    False both for an address that connected and for one still pending when the
    budget ran out. The two are different problems and neither is what a caller
    asked for, so neither is worth telling apart here.

    Costs a socket and up to a quarter of a second, which is why `dead_address`
    tries the address most likely to work first. On every host but one the
    answer arrives on the first poll.
    """
    var attempt = start_connect(addr, String("probe for a dead address"))
    var waited = 0
    while waited < REFUSAL_PROBE_MS:
        var fds = PollFd(attempt.fd(), POLLOUT, Int16(0))
        _ = poll(Pointer(to=fds), c_uint(1), c_int(PROBE_SLICE_MS))
        try:
            if attempt.finished():
                return False
        except:
            # The only way `finished` raises is a connect that failed, which is
            # the answer this is looking for.
            return True
        waited += PROBE_SLICE_MS
    return False


def has_ipv6_loopback() -> Bool:
    """Whether `::1` can be bound on this machine.

    Not every CI container has IPv6 configured, and a test that asserts the
    Happy Eyeballs ordering against a real socket has to skip rather than fail
    when there is no IPv6 to order.
    """
    try:
        var listener = Loopback(LOOPBACK_V6)
        listener.close()
        return True
    except:
        return False
