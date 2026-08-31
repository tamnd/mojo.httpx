"""errno constants, and the rule for turning one into an `ErrorKind`.

The numbers differ between macOS and Linux. Not by a little: `EAGAIN` is 35 on
macOS and 11 on Linux, and everything in the socket range is shifted. Getting
one wrong does not fail loudly, it produces a client that treats a would block
as a connection reset under load on one platform only. So the values are
selected at compile time and `tools/baseline/check_errno.py` verifies the whole
table against the values the host platform actually reports.

The mapping to `ErrorKind` depends on what we were doing when the call failed.
The same `ECONNRESET` is a `ConnectError` during the handshake and a
`ReadError` halfway through a response body, and httpx2 draws that distinction
too, so `kind_for_errno` takes the operation as an argument.
"""

from std.ffi import c_int
from std.sys import CompilationTarget

from httpx._exceptions import ErrorKind
from httpx._ffi.c import strerror

comptime _MACOS = CompilationTarget.is_macos()

# Values that agree on both platforms.
comptime EPERM = c_int(1)
comptime ENOENT = c_int(2)
comptime EINTR = c_int(4)
comptime EIO = c_int(5)
comptime EBADF = c_int(9)
comptime ENOMEM = c_int(12)
comptime EACCES = c_int(13)
comptime EFAULT = c_int(14)
comptime EBUSY = c_int(16)
comptime EEXIST = c_int(17)
comptime EINVAL = c_int(22)
comptime ENFILE = c_int(23)
comptime EMFILE = c_int(24)
comptime EPIPE = c_int(32)

# Values that do not.
comptime EAGAIN = c_int(35) if _MACOS else c_int(11)
comptime EWOULDBLOCK = EAGAIN
"""Identical to `EAGAIN` on both platforms. Kept as its own name because the
libc manual pages use both and it is easier to read a wrapper that quotes the
name the page uses."""

comptime EINPROGRESS = c_int(36) if _MACOS else c_int(115)
comptime EALREADY = c_int(37) if _MACOS else c_int(114)
comptime ENOTSOCK = c_int(38) if _MACOS else c_int(88)
comptime EDESTADDRREQ = c_int(39) if _MACOS else c_int(89)
comptime EMSGSIZE = c_int(40) if _MACOS else c_int(90)
comptime EPROTOTYPE = c_int(41) if _MACOS else c_int(91)
comptime ENOPROTOOPT = c_int(42) if _MACOS else c_int(92)
comptime EPROTONOSUPPORT = c_int(43) if _MACOS else c_int(93)
comptime ESOCKTNOSUPPORT = c_int(44) if _MACOS else c_int(94)
comptime ENOTSUP = c_int(45) if _MACOS else c_int(95)
comptime EOPNOTSUPP = c_int(102) if _MACOS else c_int(95)
"""Darwin gives `ENOTSUP` and `EOPNOTSUPP` different numbers, 45 and 102. Linux
makes them the same number, 95. Treat them as one condition and always test for
both, because on Linux a single `if` covers it and on macOS it does not."""
comptime EPFNOSUPPORT = c_int(46) if _MACOS else c_int(96)
comptime EAFNOSUPPORT = c_int(47) if _MACOS else c_int(97)
comptime EADDRINUSE = c_int(48) if _MACOS else c_int(98)
comptime EADDRNOTAVAIL = c_int(49) if _MACOS else c_int(99)
comptime ENETDOWN = c_int(50) if _MACOS else c_int(100)
comptime ENETUNREACH = c_int(51) if _MACOS else c_int(101)
comptime ENETRESET = c_int(52) if _MACOS else c_int(102)
comptime ECONNABORTED = c_int(53) if _MACOS else c_int(103)
comptime ECONNRESET = c_int(54) if _MACOS else c_int(104)
comptime ENOBUFS = c_int(55) if _MACOS else c_int(105)
comptime EISCONN = c_int(56) if _MACOS else c_int(106)
comptime ENOTCONN = c_int(57) if _MACOS else c_int(107)
comptime ESHUTDOWN = c_int(58) if _MACOS else c_int(108)
comptime ETOOMANYREFS = c_int(59) if _MACOS else c_int(109)
comptime ETIMEDOUT = c_int(60) if _MACOS else c_int(110)
comptime ECONNREFUSED = c_int(61) if _MACOS else c_int(111)
comptime ELOOP = c_int(62) if _MACOS else c_int(40)
comptime ENAMETOOLONG = c_int(63) if _MACOS else c_int(36)
comptime EHOSTDOWN = c_int(64) if _MACOS else c_int(112)
comptime EHOSTUNREACH = c_int(65) if _MACOS else c_int(113)


struct Op(Equatable, ImplicitlyCopyable, Movable, Writable):
    """What we were doing when the call failed.

    The same errno means different things at different points in a connection's
    life, and httpx2 reports them as different exceptions, so the operation has
    to travel with the error code.
    """

    var value: UInt8

    def __init__(out self, value: UInt8):
        self.value = value

    comptime CONNECT = Op(0)
    comptime READ = Op(1)
    comptime WRITE = Op(2)
    comptime CLOSE = Op(3)
    comptime RESOLVE = Op(4)
    comptime POLL = Op(5)
    comptime SOCKET = Op(6)
    comptime FCNTL = Op(7)

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.name())

    def name(self) -> StaticString:
        if self == Op.CONNECT:
            return "connect"
        if self == Op.READ:
            return "read"
        if self == Op.WRITE:
            return "write"
        if self == Op.CLOSE:
            return "close"
        if self == Op.RESOLVE:
            return "resolve"
        if self == Op.POLL:
            return "wait on"
        if self == Op.SOCKET:
            return "open a socket for"
        if self == Op.FCNTL:
            return "configure the socket for"
        return "unknown"


def would_block(code: c_int) -> Bool:
    """True when the call did not fail, it just has nothing to say yet.

    Non blocking sockets return this constantly and it must never reach the
    caller as an error. `EINPROGRESS` is the same idea for a connect that has
    been started but not finished.
    """
    return code == EAGAIN or code == EWOULDBLOCK or code == EINPROGRESS


def interrupted(code: c_int) -> Bool:
    """True when a signal cut the call short and it should simply be retried."""
    return code == EINTR


def kind_for_errno(code: c_int, op: Op) -> ErrorKind:
    """Map an errno value to the error kind httpx2 would have raised.

    `EAGAIN` and `EINTR` are deliberately absent. They are flow control, not
    failures, and reaching this function with either of them is a bug in the
    caller rather than something to be classified. They come back as
    `ConnectError`, `ReadError` or `WriteError` for the operation so that a
    caller which does leak one still gets a sensible error rather than an
    unlabelled one, but the loop that produced it is the thing to fix.
    """
    # A timeout reported by the kernel rather than by our own deadline. Which
    # timeout it is depends entirely on where we were.
    if code == ETIMEDOUT:
        if op == Op.CONNECT:
            return ErrorKind.CONNECT_TIMEOUT
        if op == Op.READ:
            return ErrorKind.READ_TIMEOUT
        if op == Op.WRITE:
            return ErrorKind.WRITE_TIMEOUT
        return ErrorKind.TIMEOUT

    # Everything else is a network error, and the operation picks the leaf.
    return _network_kind(op)


def _network_kind(op: Op) -> ErrorKind:
    if op == Op.CONNECT or op == Op.RESOLVE:
        return ErrorKind.CONNECT_ERROR
    if op == Op.READ:
        return ErrorKind.READ_ERROR
    if op == Op.WRITE:
        return ErrorKind.WRITE_ERROR
    if op == Op.CLOSE:
        return ErrorKind.CLOSE_ERROR
    # Creating or configuring the socket is part of establishing the
    # connection as far as a caller is concerned, so it reads as a connect
    # failure rather than as an unlabelled network one.
    if op == Op.SOCKET or op == Op.FCNTL:
        return ErrorKind.CONNECT_ERROR
    return ErrorKind.NETWORK_ERROR


def errno_name(code: c_int) -> StaticString:
    """The symbolic name of an errno value, for error messages.

    A message that reads `ECONNREFUSED (61) Connection refused` is worth the
    table. `61` on its own means nothing to a reader on the other platform.
    """
    if code == EPERM:
        return "EPERM"
    if code == ENOENT:
        return "ENOENT"
    if code == EINTR:
        return "EINTR"
    if code == EIO:
        return "EIO"
    if code == EBADF:
        return "EBADF"
    if code == ENOMEM:
        return "ENOMEM"
    if code == EACCES:
        return "EACCES"
    if code == EFAULT:
        return "EFAULT"
    if code == EBUSY:
        return "EBUSY"
    if code == EEXIST:
        return "EEXIST"
    if code == EINVAL:
        return "EINVAL"
    if code == ENFILE:
        return "ENFILE"
    if code == EMFILE:
        return "EMFILE"
    if code == EPIPE:
        return "EPIPE"
    if code == EAGAIN:
        return "EAGAIN"
    if code == EINPROGRESS:
        return "EINPROGRESS"
    if code == EALREADY:
        return "EALREADY"
    if code == ENOTSOCK:
        return "ENOTSOCK"
    if code == EDESTADDRREQ:
        return "EDESTADDRREQ"
    if code == EMSGSIZE:
        return "EMSGSIZE"
    if code == EPROTOTYPE:
        return "EPROTOTYPE"
    if code == ENOPROTOOPT:
        return "ENOPROTOOPT"
    if code == EPROTONOSUPPORT:
        return "EPROTONOSUPPORT"
    if code == ESOCKTNOSUPPORT:
        return "ESOCKTNOSUPPORT"
    if code == ENOTSUP:
        return "ENOTSUP"
    if code == EOPNOTSUPP:
        return "EOPNOTSUPP"
    if code == EPFNOSUPPORT:
        return "EPFNOSUPPORT"
    if code == EAFNOSUPPORT:
        return "EAFNOSUPPORT"
    if code == EADDRINUSE:
        return "EADDRINUSE"
    if code == EADDRNOTAVAIL:
        return "EADDRNOTAVAIL"
    if code == ENETDOWN:
        return "ENETDOWN"
    if code == ENETUNREACH:
        return "ENETUNREACH"
    if code == ENETRESET:
        return "ENETRESET"
    if code == ECONNABORTED:
        return "ECONNABORTED"
    if code == ECONNRESET:
        return "ECONNRESET"
    if code == ENOBUFS:
        return "ENOBUFS"
    if code == EISCONN:
        return "EISCONN"
    if code == ENOTCONN:
        return "ENOTCONN"
    if code == ESHUTDOWN:
        return "ESHUTDOWN"
    if code == ETOOMANYREFS:
        return "ETOOMANYREFS"
    if code == ETIMEDOUT:
        return "ETIMEDOUT"
    if code == ECONNREFUSED:
        return "ECONNREFUSED"
    if code == ELOOP:
        return "ELOOP"
    if code == ENAMETOOLONG:
        return "ENAMETOOLONG"
    if code == EHOSTDOWN:
        return "EHOSTDOWN"
    if code == EHOSTUNREACH:
        return "EHOSTUNREACH"
    return "errno"


def errno_message(code: c_int, op: Op, what: StringSpan) -> String:
    """The text of an error raised because a libc call failed.

    Reads `connect to 10.0.0.1:443 failed: ECONNREFUSED (61) Connection
    refused`. The symbolic name is there because the number is platform
    specific, the number is there because that is what shows up in a strace,
    and the libc text is there because it is the part a user can act on.
    """
    return String(
        op.name(),
        " ",
        what,
        " failed: ",
        errno_name(code),
        " (",
        Int(code),
        ") ",
        strerror(code),
    )
