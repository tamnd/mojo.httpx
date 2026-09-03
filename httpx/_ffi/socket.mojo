"""The socket syscalls, as thin wrappers that report failure through errno.

Every function here is a direct call into libc and returns exactly what libc
returned, including a negative result on failure. Nothing in this module
raises. Deciding that a negative return is an error, reading errno, and turning
it into an `ErrorKind` belongs one layer up in `_io`, because only that layer
knows whether a would block is a problem or the normal state of affairs.

Addresses are deliberately absent. Building a `sockaddr_in` by hand means
getting the Darwin `sin_len` byte right, the family width right, and the byte
order right, and then doing it again for IPv6 with a scope id. `getaddrinfo`
already does all of that correctly, so `connect_to` takes the `sockaddr` that
resolution produced and passes it straight through. See `netdb.mojo`.
"""

from std.ffi import c_int, c_size_t, c_ssize_t, c_uint, external_call
from std.sys import CompilationTarget

from httpx._ffi.c import Ptr, set_errno, socklen_t
from httpx._ffi.errno import EINVAL

# The calls that take a caller supplied buffer are generic over the pointer's
# origin rather than demanding the untracked `Ptr`. That lets a caller write
# `Pointer(to=buf)` and keep the compiler's lifetime tracking, instead of
# laundering a perfectly good local through an untracked pointer just to
# satisfy a signature. Only pointers that genuinely come from C stay untracked.

comptime _MACOS = CompilationTarget.is_macos()

comptime AF_UNSPEC = c_int(0)
comptime AF_UNIX = c_int(1)
comptime AF_INET = c_int(2)
comptime AF_INET6 = c_int(30) if _MACOS else c_int(10)
"""IPv6 is 30 on Darwin and 10 on Linux. IPv4 is 2 on both."""

comptime SOCK_STREAM = c_int(1)
comptime SOCK_DGRAM = c_int(2)

comptime IPPROTO_TCP = c_int(6)
comptime IPPROTO_IPV6 = c_int(41)

comptime SOL_SOCKET = c_int(0xFFFF) if _MACOS else c_int(1)
comptime SO_REUSEADDR = c_int(0x0004) if _MACOS else c_int(2)
comptime SO_KEEPALIVE = c_int(0x0008) if _MACOS else c_int(9)
comptime SO_SNDBUF = c_int(0x1001) if _MACOS else c_int(7)
comptime SO_RCVBUF = c_int(0x1002) if _MACOS else c_int(8)
comptime SO_ERROR = c_int(0x1007) if _MACOS else c_int(4)
"""Reading `SO_ERROR` is how a non blocking connect reports its result. The
connect itself returns `EINPROGRESS` and the real answer arrives here once the
socket becomes writable."""

comptime SO_NOSIGPIPE = c_int(0x1022)
"""Darwin only. See `suppress_sigpipe`."""

comptime TCP_NODELAY = c_int(1)
comptime IPV6_V6ONLY = c_int(27) if _MACOS else c_int(26)

comptime MSG_NOSIGNAL = c_int(0) if _MACOS else c_int(0x4000)
"""Linux suppresses SIGPIPE per call with this flag. Darwin has no such flag
and uses the `SO_NOSIGPIPE` socket option instead, so on Darwin this is zero
and passing it is a no op. Use `suppress_sigpipe` and you get the right one."""

comptime SIGPIPE = c_int(13)
"""Thirteen on both platforms. See `ignore_sigpipe_for_the_process`."""

comptime SIG_DFL = 0
comptime SIG_IGN = 1
comptime SIG_ERR = -1
"""The three dispositions `signal` deals in, as the integers they are.

A disposition is a function pointer, and zero and one are not addresses but
sentinels that mean terminate and discard. Held as `Int` here rather than as a
pointer type because the only things this file does with one are pass these two
constants in and hand back whatever came out.
"""

comptime SHUT_RD = c_int(0)
comptime SHUT_WR = c_int(1)
comptime SHUT_RDWR = c_int(2)

comptime F_GETFL = c_int(3)
comptime F_SETFL = c_int(4)
comptime O_NONBLOCK = c_int(0x0004) if _MACOS else c_int(0o4000)

comptime POLLIN = Int16(0x0001)
comptime POLLPRI = Int16(0x0002)
comptime POLLOUT = Int16(0x0004)
comptime POLLERR = Int16(0x0008)
comptime POLLHUP = Int16(0x0010)
comptime POLLNVAL = Int16(0x0020)
"""The poll flags happen to agree on both platforms."""


@fieldwise_init
struct PollFd(ImplicitlyCopyable, Movable):
    """`struct pollfd`. Three fields, no padding, eight bytes on both platforms.

    This is the one C structure we declare rather than address by offset,
    because it is small enough that the layout is unambiguous: an `int`
    followed by two `short`s packs the same way everywhere we run.
    """

    var fd: c_int
    var events: Int16
    var revents: Int16


def socket(domain: c_int, type: c_int, protocol: c_int) -> c_int:
    """Create a socket. Returns the descriptor, or a negative value on failure.
    """
    return external_call["socket", c_int](domain, type, protocol)


def connect_to[
    o: ImmOrigin
](fd: c_int, addr: Pointer[UInt8, o], addrlen: socklen_t) -> c_int:
    """Start a connection to an already built `sockaddr`.

    Named `connect_to` rather than `connect` because the socket is not the
    subject of the sentence and because `connect` reads like a method on
    something. `addr` and `addrlen` come straight from `getaddrinfo`.

    On a non blocking socket this almost always returns -1 with `EINPROGRESS`.
    That is success in progress, not failure. Wait for the socket to become
    writable and then read `SO_ERROR`.
    """
    return external_call["connect", c_int](fd, addr, addrlen)


def bind_to[
    o: ImmOrigin
](fd: c_int, addr: Pointer[UInt8, o], addrlen: socklen_t) -> c_int:
    """Claim a local address. Same `sockaddr` contract as `connect_to`.

    A client rarely binds. This is here for the tests, which need a listener on
    a loopback port to prove the address bytes are the ones the kernel wants,
    and for the local address pinning some deployments require.
    """
    return external_call["bind", c_int](fd, addr, addrlen)


def listen(fd: c_int, backlog: c_int) -> c_int:
    """Mark a bound socket as accepting connections.

    Only the test listener uses this. `backlog` is a hint and every platform
    silently clamps it.
    """
    return external_call["listen", c_int](fd, backlog)


def accept(fd: c_int) -> c_int:
    """Accept a connection and discard the peer address.

    The test server is the only caller and it does not need the peer address.
    Passing null for both arguments is the documented way to say so, and the
    nulls are typed pointers rather than a zero int so that the whole register
    is zero on a 64 bit target.
    """
    return external_call["accept", c_int](
        fd, Optional[Ptr[UInt8]](), Optional[Ptr[socklen_t]]()
    )


def send[
    o: ImmOrigin
](
    fd: c_int, buf: Pointer[UInt8, o], count: c_size_t, flags: c_int
) -> c_ssize_t:
    """Write to a socket. Returns the number of bytes taken, which may be fewer
    than `count`, or a negative value on failure.

    A short write is normal and is not an error. The caller loops.
    """
    return external_call["send", c_ssize_t](fd, buf, count, flags)


def recv[
    o: MutOrigin
](
    fd: c_int, buf: Pointer[UInt8, o], count: c_size_t, flags: c_int
) -> c_ssize_t:
    """Read from a socket. Returns the number of bytes read, zero at end of
    stream, or a negative value on failure.

    Zero means the peer closed cleanly. For HTTP/1.1 that is only a valid end
    of message when the framing said so, and a response cut short here is a
    `RemoteProtocolError` rather than a complete body. Getting that distinction
    wrong is how a client silently truncates a response.
    """
    return external_call["recv", c_ssize_t](fd, buf, count, flags)


def shutdown(fd: c_int, how: c_int) -> c_int:
    """Half close a connection without releasing the descriptor.

    `SHUT_WR` is the one that matters: it sends a FIN so the server knows the
    request body is complete, while leaving the socket readable for the
    response. Closing instead would discard a response already in flight.
    """
    return external_call["shutdown", c_int](fd, how)


def close(fd: c_int) -> c_int:
    """Close a descriptor.

    Never retry this on `EINTR`. On Linux the descriptor is already gone by the
    time the signal is reported, so a retry closes whatever number was handed
    out next, which in a threaded program is somebody else's socket.
    """
    return external_call["close", c_int](fd)


def setsockopt_int(
    fd: c_int, level: c_int, option: c_int, value: c_int
) -> c_int:
    """Set an integer valued socket option, which is nearly all of them."""
    var v = value
    return external_call["setsockopt", c_int](
        fd,
        level,
        option,
        Pointer(to=v),
        socklen_t(4),
    )


def getsockopt_int(
    fd: c_int, level: c_int, option: c_int, mut value: c_int
) -> c_int:
    """Read an integer valued socket option into `value`."""
    var length = socklen_t(4)
    return external_call["getsockopt", c_int](
        fd,
        level,
        option,
        Pointer(to=value),
        Pointer(to=length),
    )


def _fcntl(fd: c_int, cmd: c_int, arg: c_int) -> c_int:
    """`fcntl`, called in a way that survives the Apple variadic ABI.

    `fcntl` is declared `int fcntl(int, int, ...)`, so its third argument is a
    variadic one, and the platforms disagree about where a variadic argument
    lives. On Linux, on both x86-64 and aarch64, it goes in the next argument
    register, which is what an ordinary three argument call already does. On
    Apple arm64 every variadic argument goes on the stack instead, so a three
    argument call leaves the register set and the callee reads whatever happens
    to be at the top of the stack.

    That failure is silent. `F_SETFL` returns success and simply does not apply
    the flags, which shows up much later as a read that blocks forever on a
    socket the caller believes is non blocking.

    Mojo has no way to declare a call variadic, so the argument is passed twice.
    Position three is where Linux looks. Position nine is the first stack slot
    under the ordinary calling convention, which is where Apple arm64 looks. The
    positions the platform does not use are ignored, so one call shape is
    correct on both, with no compile time branch and no second signature for the
    same symbol, which Mojo rejects anyway.

    `set_nonblocking` reads the flags back afterwards, so if a future toolchain
    lays these arguments out differently it fails loudly instead of hanging.
    """
    comptime Z = c_int(0)
    return external_call["fcntl", c_int](fd, cmd, arg, Z, Z, Z, Z, Z, arg)


def fcntl_get_flags(fd: c_int) -> c_int:
    """The file status flags, or a negative value on failure."""
    return _fcntl(fd, F_GETFL, c_int(0))


def fcntl_set_flags(fd: c_int, flags: c_int) -> c_int:
    return _fcntl(fd, F_SETFL, flags)


def set_nonblocking(fd: c_int) -> c_int:
    """Put a socket into non blocking mode.

    Read the flags, add the bit, write them back. Setting `O_NONBLOCK` without
    reading first would clear whatever else was there, `O_APPEND` among them.

    The result is read back rather than trusted. `F_SETFL` reports success
    without checking that it understood its argument, and a socket that is still
    blocking after this returns is a hang rather than an error, so the extra
    call is worth its cost once per connection. A mismatch comes back as -1 with
    errno set to `EINVAL`.
    """
    var flags = fcntl_get_flags(fd)
    if flags < 0:
        return flags
    var rc = fcntl_set_flags(fd, flags | O_NONBLOCK)
    if rc < 0:
        return rc
    if (fcntl_get_flags(fd) & O_NONBLOCK) == 0:
        set_errno(EINVAL)
        return c_int(-1)
    return c_int(0)


def suppress_sigpipe(fd: c_int) -> c_int:
    """Stop a write to a closed socket from killing the process.

    The default disposition of SIGPIPE terminates the program, and writing to a
    connection the peer has already reset is an ordinary event for an HTTP
    client, so this is not optional. Darwin does it per socket with
    `SO_NOSIGPIPE` and Linux does it per call with `MSG_NOSIGNAL`, which is why
    both appear in this file. On Linux this is a no op and the flag on `send`
    does the work.
    """

    comptime if _MACOS:
        return setsockopt_int(fd, SOL_SOCKET, SO_NOSIGPIPE, c_int(1))
    return 0


def ignore_sigpipe_for_the_process() -> Bool:
    """Stop a write this library did not make from killing the process.

    Everything above writes with `send` and `MSG_NOSIGNAL`, so nothing this
    library does can raise SIGPIPE. OpenSSL is the exception. Its socket BIO
    writes with plain `write`, there is no option to make it do otherwise, and
    on Linux there is no per socket way to suppress the signal either, so a
    handshake against a peer that has already gone away kills the program with
    no message at all. That is not theoretical: it is a server closing the
    connection between the TCP accept and the ClientHello, which happens to
    real clients against real load balancers, and it was found here by a test
    doing exactly that on a Linux host.

    Darwin is covered already and is left alone. `SO_NOSIGPIPE` is set on every
    socket this library connects, and it holds for OpenSSL's writes too because
    it is a property of the socket rather than of the call.

    An existing handler is put back. Turning SIGPIPE off is process wide state,
    which a library has no business taking from a program that has already said
    what it wants, so what this does is fill in a disposition nobody had set. A
    program that wants the signal for itself keeps it, and pays for that by
    having to survive OpenSSL raising one.

    Returns whether SIGPIPE is now ignored, for a caller that wants to say so.
    """

    comptime if _MACOS:
        return True

    # `signal` takes and returns a function pointer, and the two values that
    # matter are sentinels rather than addresses. Sound as `Int` because it is
    # pointer sized on both platforms and neither value is ever called.
    var previous = external_call["signal", Int, c_int, Int](SIGPIPE, SIG_IGN)
    if previous == SIG_ERR:
        return False
    if previous != SIG_DFL and previous != SIG_IGN:
        # Somebody was already listening. Put their handler back and leave the
        # signal alone. Same call, same argument kinds, same reasoning.
        _ = external_call["signal", Int, c_int, Int](SIGPIPE, previous)
        return False
    return True


def set_tcp_nodelay(fd: c_int) -> c_int:
    """Turn off Nagle's algorithm.

    A request that fits in one write should leave immediately. With Nagle on,
    a small body sent after the headers can sit in the kernel waiting for an
    acknowledgement that the server will not send until it has the body.
    """
    return setsockopt_int(fd, IPPROTO_TCP, TCP_NODELAY, c_int(1))


def poll[
    o: MutOrigin
](fds: Pointer[PollFd, o], nfds: c_uint, timeout_ms: c_int) -> c_int:
    """Wait for one of `nfds` descriptors to become ready.

    `poll` is the portable floor. It is linear in the number of descriptors,
    which is fine for a client holding tens of connections and wrong for a
    server holding thousands, so M2 adds kqueue on Darwin and epoll on Linux
    behind the same interface. A negative `timeout_ms` waits forever, which no
    caller in this library is allowed to do. Every wait carries a deadline.
    """
    return external_call["poll", c_int](fds, nfds, timeout_ms)
