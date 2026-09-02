"""A TCP stream: an owned descriptor, non blocking, with a deadline on every
wait.

Everything below this is a raw syscall that reports failure through errno and
never waits. Everything above it deals in bytes and errors with names. This
module is the join, and it makes three decisions that the rest of the library
then depends on.

Sockets are always non blocking, including in the sync client. Blocking mode
cannot be interrupted and has no per operation timeout that works on every
platform, so a blocking read is a client that hangs. Instead every read and
write loops: try the syscall, and if it would block, wait on `poll` for as long
as the deadline allows and try again. That is slightly more code and it is the
only shape that makes the timeout guarantee true.

The descriptor is owned. `TcpStream` closes it in `__deinit__` and cannot be
copied, so there is exactly one owner and no path where a descriptor is closed
twice. A double close is worse than a leak: the number gets reused, and the
second close lands on somebody else's connection.

SIGPIPE is suppressed per socket on Darwin and per call on Linux. Writing to a
connection the peer has reset is an everyday event for an HTTP client, and the
default disposition of SIGPIPE kills the process.
"""

from std.ffi import c_int, c_size_t, c_uint

from httpx._exceptions import ErrorKind, new_error
from httpx._ffi.c import errno
from httpx._ffi.errno import (
    EINPROGRESS,
    ETIMEDOUT,
    Op,
    errno_message,
    interrupted,
    kind_for_errno,
    would_block,
)
from httpx._ffi.netdb import SockAddr, connect_addr
from httpx._ffi.socket import (
    AF_INET6,
    IPPROTO_IPV6,
    IPV6_V6ONLY,
    MSG_NOSIGNAL,
    POLLERR,
    POLLHUP,
    POLLIN,
    POLLNVAL,
    POLLOUT,
    SHUT_RDWR,
    SHUT_WR,
    SO_ERROR,
    SOL_SOCKET,
    PollFd,
    close,
    getsockopt_int,
    poll,
    recv,
    send,
    set_nonblocking,
    set_tcp_nodelay,
    setsockopt_int,
    shutdown,
    socket,
    suppress_sigpipe,
)
from httpx._io.deadline import Deadline

comptime INVALID_FD = c_int(-1)
"""What `_fd` holds once the stream has been closed or moved from."""


struct TcpStream(Movable):
    """One connected TCP socket, owned outright.

    Not copyable, because two copies would both close the same descriptor. Move
    it or hold it by reference.
    """

    var _fd: c_int
    var _peer: String
    """Where this connects to, in text, for error messages.

    Kept on the stream rather than looked up on demand, because the interesting
    time to know the peer is when the connection has already failed and asking
    the kernel no longer works.
    """

    var _readable: Bool
    var _writable: Bool

    def __init__(out self, fd: c_int, peer: String):
        self._fd = fd
        self._peer = peer
        self._readable = True
        self._writable = True

    # No `__moveinit__`. The synthesised one moves each field and consumes the
    # source outright, so the descriptor has exactly one owner at every point
    # and `__deinit__` never runs on a stream that was moved from. Writing one
    # by hand that also cleared the source's descriptor would be describing a
    # destructor that does not run.

    def __deinit__(deinit self):
        if self._fd >= 0:
            _ = close(self._fd)

    def fd(self) -> c_int:
        """The raw descriptor, for the poll set and for TLS to wrap.

        Reading it does not transfer ownership. Nothing outside this module may
        close it.
        """
        return self._fd

    def peer(self) -> String:
        """Who this is connected to, for error messages.

        Copies rather than handing back the field, so that reading the name of
        a peer never takes the name away from the stream that is still using it.
        Only error paths ask, so the copy costs nothing that matters.
        """
        return self._peer.copy()

    def is_open(self) -> Bool:
        return self._fd >= 0

    def read[
        o: MutOrigin
    ](mut self, buf: Span[UInt8, o], deadline: Deadline) raises -> Int:
        """Read into `buf`, waiting until the deadline for the first byte.

        Returns zero at end of stream, which is the peer closing cleanly. That
        is only a complete message when the framing said the body ends there,
        and the HTTP layer is what knows, which is why this reports it as a
        value rather than raising.
        """
        while True:
            deadline.check(String("read from ", self._peer))
            var n = self.try_read(buf)
            if n >= 0:
                return Int(n)
            var code = errno()
            if interrupted(code):
                continue
            if not would_block(code):
                raise new_error(
                    kind_for_errno(code, Op.READ),
                    errno_message(code, Op.READ, self._peer),
                )
            _ = self._wait(POLLIN, deadline)

    def write[
        o: ImmOrigin
    ](mut self, data: Span[UInt8, o], deadline: Deadline) raises:
        """Write all of `data`, looping over short writes.

        A short write is normal, not an error: the kernel takes what fits in the
        send buffer and returns. Treating the return value as all or nothing is
        how a large request body gets silently truncated.
        """
        var sent = 0
        while sent < data.__len__():
            deadline.check(String("write to ", self._peer))
            var n = self.try_write(data, sent)
            if n > 0:
                sent += Int(n)
                continue
            var code = errno()
            if interrupted(code):
                continue
            if not would_block(code):
                raise new_error(
                    kind_for_errno(code, Op.WRITE),
                    errno_message(code, Op.WRITE, self._peer),
                )
            _ = self._wait(POLLOUT, deadline)

    def has_data_waiting(self) raises -> Bool:
        """Whether a read right now would return something.

        Used by the pool to tell a reusable idle connection from one the server
        closed while it sat there. A connection with data waiting on it before a
        request was sent is also not reusable, because whatever is there belongs
        to the previous exchange.

        Deliberately does not take a deadline: the wait is zero milliseconds, so
        this cannot block, which is why it is spelled as a poll with an explicit
        zero rather than through `_wait`.
        """
        var fds = PollFd(self._fd, POLLIN, Int16(0))
        var rc = poll(Pointer(to=fds), c_uint(1), c_int(0))
        if rc <= 0:
            return False
        return (fds.revents & (POLLIN | POLLHUP | POLLERR)) != 0

    def is_closed_by_peer(self) raises -> Bool:
        """Whether the far end has hung up on an idle connection.

        A connection the server closed while it was idle becomes readable and
        reads zero bytes. Checking before reuse turns a confusing failure on the
        next request into a connection quietly discarded and replaced.
        """
        if not self.has_data_waiting():
            return False
        var probe = List[UInt8](length=1, fill=0)
        # MSG_PEEK, so the byte stays in the kernel buffer if there is one. A
        # connection with real data waiting on it is also unusable, but it is
        # unusable for a different reason and the caller decides which.
        comptime MSG_PEEK = c_int(2)
        var n = recv(
            self._fd,
            Pointer(to=probe[0]),
            c_size_t(1),
            MSG_PEEK,
        )
        return n == 0

    def wait_readable(mut self, deadline: Deadline) raises -> Bool:
        """Block until a read would return something, or the deadline expires.

        Public because TLS drives its own read loop. OpenSSL asks for more
        socket data by returning WANT_READ rather than by blocking, so the
        waiting has to happen one level above `read`, and a TLS layer that
        polled the descriptor itself would be a second place where a deadline
        turns into a timeout in milliseconds.
        """
        return self._wait(POLLIN, deadline)

    def wait_writable(mut self, deadline: Deadline) raises -> Bool:
        """The same for a write. See `wait_readable`."""
        return self._wait(POLLOUT, deadline)

    def shutdown_write(mut self):
        """Send a FIN, leaving the socket readable.

        This is how a request body with no declared length is terminated. A
        close instead would discard a response the server has already sent.
        """
        if self._fd >= 0 and self._writable:
            _ = shutdown(self._fd, SHUT_WR)
            self._writable = False

    def close(mut self):
        """Release the descriptor. Safe to call more than once."""
        if self._fd >= 0:
            _ = shutdown(self._fd, SHUT_RDWR)
            _ = close(self._fd)
            self._fd = INVALID_FD
        self._readable = False
        self._writable = False

    def try_read[o: MutOrigin](mut self, buf: Span[UInt8, o]) -> Int:
        """One `recv`, with no waiting. Negative means errno has the reason.

        Taking the address of the first element is sound because the caller's
        span is non empty by the check below and a span's elements are
        contiguous, so `count` bytes from that address stay inside it.

        Notes end of stream itself rather than leaving it to `read`, because the
        async stream drives this same call from its own loop and a second place
        remembering to do the bookkeeping is a second place to forget.
        """
        if buf.__len__() == 0:
            return 0
        var n = Int(
            recv(
                self._fd,
                Pointer(to=buf[0]),
                c_size_t(buf.__len__()),
                c_int(0),
            )
        )
        if n == 0:
            self._readable = False
        return n

    def try_write[
        o: ImmOrigin
    ](mut self, data: Span[UInt8, o], offset: Int = 0) -> Int:
        """One `send` of everything from `offset` on, with no waiting.

        Negative means errno has the reason. Same contiguity argument as
        `try_read`. `MSG_NOSIGNAL` is zero on Darwin, where `SO_NOSIGPIPE` was
        set when the socket was made, so the SIGPIPE suppression is covered on
        both platforms.

        The caller passes an offset rather than a slice of its own because
        `data[offset:]` inside a coroutine that suspends crashes the Mojo 1.0.0
        compiler, and the async stream writes in exactly that shape. One
        signature both callers can use beats a second entry point that only the
        async one needs, so the synchronous `write` passes an offset too.
        """
        var remaining = data.__len__() - offset
        if remaining <= 0:
            return 0
        return Int(
            send(
                self._fd,
                Pointer(to=data[offset]),
                c_size_t(remaining),
                MSG_NOSIGNAL,
            )
        )

    def _wait(mut self, events: Int16, deadline: Deadline) raises -> Bool:
        """Wait for one of `events`, for as long as the deadline allows.

        Returns False when the wait timed out without the socket becoming ready,
        which the callers treat as a reason to go round again and let
        `deadline.check` produce the error. That keeps every timeout message in
        one place instead of one per call site.
        """
        var fds = PollFd(self._fd, events, Int16(0))
        var rc = poll(
            Pointer(to=fds), c_uint(1), c_int(deadline.remaining_ms())
        )
        if rc < 0:
            var code = errno()
            if interrupted(code):
                return False
            raise new_error(
                kind_for_errno(code, Op.POLL),
                errno_message(code, Op.POLL, self._peer),
            )
        if rc == 0:
            return False
        if (fds.revents & POLLNVAL) != 0:
            raise new_error(
                ErrorKind.READ_ERROR,
                String("polled a descriptor that is not open: ", self._peer),
            )
        return True


def open_stream(
    addr: SockAddr, peer: String, deadline: Deadline
) raises -> TcpStream:
    """Connect to one already resolved address and hand back the stream.

    The whole connect is non blocking. `connect` on a non blocking socket
    returns `EINPROGRESS`, the socket becomes writable when the attempt
    finishes, and the result is read out of `SO_ERROR`. A blocking connect would
    ignore the deadline entirely, since no platform offers a per call connect
    timeout.
    """
    var pending = start_connect(addr, peer)
    return finish_connect(pending^, deadline)


struct PendingConnect(Movable):
    """A connect that has been started and has not finished.

    Happy Eyeballs needs several of these in flight at once, which is why
    starting and finishing are separate calls rather than one function.
    """

    var _stream: Optional[TcpStream]
    """Optional so the winner can be taken out of it.

    A plain field would read better and does not compile: moving a field out of
    an owned value whose type has a `__deinit__` leaves the rest of the value
    with nothing to destroy, and the ownership checker rejects it. An `Optional`
    is the supported way to say that a value leaves early, and `take` is the
    only thing that empties this one.
    """

    var started_ns: UInt64
    var failed: Bool
    """Set when the connect failed synchronously, so the race can skip it
    without the caller having to special case a stream that was never open."""

    var reason: String

    def __init__(out self, var stream: TcpStream, started_ns: UInt64):
        self._stream = Optional[TcpStream](stream^)
        self.started_ns = started_ns
        self.failed = False
        self.reason = String()

    def fd(self) -> c_int:
        return self._stream.value().fd()

    def peer(self) -> String:
        return self._stream.value().peer()

    def take_stream(mut self) -> TcpStream:
        """The connected stream, leaving this attempt with nothing.

        Called once, by whoever decided this attempt won. Calling it twice is a
        bug and traps rather than handing back a descriptor that is already
        owned somewhere else.
        """
        return self._stream.take()

    def finished(mut self) raises -> Bool:
        """Whether the connect has finished, and whether it worked.

        Returns True when the socket is connected, False when the attempt is
        still going, and raises when it failed. Does not wait, which is what
        lets one caller drive several attempts at once.
        """
        if self.failed:
            raise new_error(ErrorKind.CONNECT_ERROR, self.reason)
        var fds = PollFd(self.fd(), POLLOUT, Int16(0))
        var rc = poll(Pointer(to=fds), c_uint(1), c_int(0))
        if rc < 0:
            var code = errno()
            if interrupted(code):
                return False
            raise new_error(
                kind_for_errno(code, Op.POLL),
                errno_message(code, Op.POLL, self.peer()),
            )
        if rc == 0:
            return False
        return self._take_error()

    def _take_error(mut self) raises -> Bool:
        """Read `SO_ERROR` and turn it into the connect's verdict.

        This is the only way a non blocking connect reports what happened. A
        socket that became writable with a non zero `SO_ERROR` did not connect,
        and reading also clears the value, so this runs exactly once.
        """
        var code = c_int(0)
        var rc = getsockopt_int(self.fd(), SOL_SOCKET, SO_ERROR, code)
        if rc < 0:
            var failure = errno()
            raise new_error(
                kind_for_errno(failure, Op.CONNECT),
                errno_message(failure, Op.CONNECT, self.peer()),
            )
        if code == 0:
            return True
        raise new_error(
            kind_for_errno(code, Op.CONNECT),
            errno_message(code, Op.CONNECT, self.peer()),
        )


def start_connect(addr: SockAddr, peer: String) raises -> PendingConnect:
    """Create the socket, set it up, and start connecting. Does not wait.

    Named without a deadline because it genuinely cannot block: the socket is
    non blocking before `connect` is called, so the call returns immediately
    whatever the network is doing.
    """
    from httpx._io.deadline import now_ns

    var fd = socket(addr.family, addr.socktype, addr.protocol)
    if fd < 0:
        var code = errno()
        raise new_error(
            kind_for_errno(code, Op.SOCKET),
            errno_message(code, Op.SOCKET, peer),
        )
    var stream = TcpStream(fd, peer)

    if set_nonblocking(fd) < 0:
        var code = errno()
        raise new_error(
            kind_for_errno(code, Op.FCNTL), errno_message(code, Op.FCNTL, peer)
        )
    # Neither of these is worth failing a connection over. Nagle costs latency
    # and SIGPIPE suppression is belt and braces next to MSG_NOSIGNAL, so a
    # kernel that refuses either still gives a working connection.
    _ = set_tcp_nodelay(fd)
    _ = suppress_sigpipe(fd)
    if addr.is_ipv6():
        # One address, one family. Without this, a v6 socket on a dual stack
        # host may also accept v4 mapped traffic, which makes the Happy Eyeballs
        # race between the two families meaningless.
        _ = setsockopt_int(fd, IPPROTO_IPV6, IPV6_V6ONLY, c_int(1))

    var pending = PendingConnect(stream^, now_ns())
    var rc = connect_addr(fd, addr)
    if rc == 0:
        return pending^
    var code = errno()
    if code == EINPROGRESS:
        return pending^
    pending.failed = True
    pending.reason = errno_message(code, Op.CONNECT, peer)
    return pending^


def finish_connect(
    var pending: PendingConnect, deadline: Deadline
) raises -> TcpStream:
    """Wait for one started connect to finish, or for the deadline to pass."""
    var peer = pending.peer()
    while True:
        deadline.check(String("connect to ", peer))
        if pending.finished():
            return pending.take_stream()
        var fds = PollFd(pending.fd(), POLLOUT, Int16(0))
        var rc = poll(
            Pointer(to=fds), c_uint(1), c_int(deadline.remaining_ms())
        )
        if rc < 0 and not interrupted(errno()):
            var code = errno()
            raise new_error(
                kind_for_errno(code, Op.POLL),
                errno_message(code, Op.POLL, peer),
            )
