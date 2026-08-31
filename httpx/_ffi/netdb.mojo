"""Name resolution: `getaddrinfo`, and reading `struct addrinfo` safely.

Resolution is where a client meets the messiest part of the platform, so this
module is explicit about two decisions.

The first is how the result is read. `struct addrinfo` is forty eight bytes on
both platforms and the first five fields sit at the same offsets on both. The
two pointer fields in the middle do not: macOS declares `ai_canonname` before
`ai_addr` and Linux declares them the other way round. Reading `ai_addr` from
the wrong slot hands `connect` a pointer to a hostname string, and the failure
looks like a DNS problem rather than a layout problem. So the fields are read
at explicit byte offsets, stated once below with the C declaration beside them,
rather than through a declared Mojo struct. Mojo makes no promise that its
field layout matches the C ABI, and this is not a structure worth being
approximately right about.

The second is who owns the memory. `getaddrinfo` allocates a linked list that
`freeaddrinfo` must release, and the obvious design of handing the caller a
borrowed view into that list is a use after free waiting to happen. Mojo
destroys a value after its last use, so a list whose last mention is the call
that produced a view is freed while the view is still being read. That is not
hypothetical, it is what the first version of this module did, and the symptom
was an address whose first eight bytes had been replaced by the allocator's
free list pointer.

So nothing borrowed escapes. `resolve` copies each address into an owned
`SockAddr` and frees the C list before it returns. An address is thirty two
bytes and a resolution is at most a handful of them, which is nothing next to
the DNS round trip that produced them.
"""

from std.ffi import CStringSlice, c_int, external_call
from std.sys import CompilationTarget

from httpx._exceptions import ErrorKind, new_error
from httpx._ffi.c import (
    CStr,
    Ptr,
    c_string,
    cstr_to_string,
    errno,
    socklen_t,
    strerror,
)
from httpx._ffi.socket import (
    AF_INET,
    AF_INET6,
    AF_UNSPEC,
    SOCK_STREAM,
    bind_to,
    connect_to,
)

comptime _MACOS = CompilationTarget.is_macos()

comptime AI_PASSIVE = c_int(0x0001)
comptime AI_CANONNAME = c_int(0x0002)
comptime AI_NUMERICHOST = c_int(0x0004)
comptime AI_NUMERICSERV = c_int(0x1000) if _MACOS else c_int(0x0400)
comptime AI_ADDRCONFIG = c_int(0x0400) if _MACOS else c_int(0x0020)
comptime AI_V4MAPPED = c_int(0x0800) if _MACOS else c_int(0x0008)
comptime AI_ALL = c_int(0x0100) if _MACOS else c_int(0x0010)

comptime NI_NUMERICHOST = c_int(0x0002) if _MACOS else c_int(1)
comptime NI_NUMERICSERV = c_int(0x1000) if _MACOS else c_int(2)

comptime ADDRINFO_SIZE = 48
"""`sizeof(struct addrinfo)` on both platforms, LP64."""

comptime SOCKADDR_MAX = 32
"""How many bytes we keep for one address.

`sockaddr_in` is sixteen and `sockaddr_in6` is twenty eight, and those are the
only two families we ask for. Thirty two is the next power of two, which is
what `SIMD` needs, and it leaves a little headroom. An entry longer than this
is skipped rather than truncated.
"""

comptime AddrBytes = SIMD[DType.uint8, SOCKADDR_MAX]
"""The address bytes as a plain value.

A `sockaddr` is a small fixed size lump of bytes with no ownership, so it is
stored as one. `Array` would be the obvious choice but it is not implicitly
copyable, and a struct holding one cannot be either, which would put a
`.copy()` at every use of what is morally an integer with a length attached.
"""

# struct addrinfo {
#     int              ai_flags;      // 0
#     int              ai_family;     // 4
#     int              ai_socktype;   // 8
#     int              ai_protocol;   // 12
#     socklen_t        ai_addrlen;    // 16, four bytes then four of padding
#     ...two pointers, order differs, see below...
#     struct addrinfo *ai_next;       // 40
# };
comptime _OFF_FLAGS = 0
comptime _OFF_FAMILY = 4
comptime _OFF_SOCKTYPE = 8
comptime _OFF_PROTOCOL = 12
comptime _OFF_ADDRLEN = 16
comptime _OFF_NEXT = 40

# macOS: char *ai_canonname at 24, struct sockaddr *ai_addr at 32.
# Linux:  struct sockaddr *ai_addr at 24, char *ai_canonname at 32.
comptime _OFF_CANONNAME = 24 if _MACOS else 32
comptime _OFF_ADDR = 32 if _MACOS else 24

comptime MAX_HOST_TEXT = 46
"""Longest numeric text form of an address, with room for the nul.

An IPv6 address with an embedded IPv4 tail and a scope id is the worst case and
fits in forty six bytes. `NI_MAXHOST` is 1025, but that is sized for reverse
DNS names and we only ever ask for the numeric form.
"""


struct SockAddr(ImplicitlyCopyable, Movable, Writable):
    """One resolved address, owned outright.

    A copy of the `sockaddr` bytes `getaddrinfo` produced, plus the family and
    the length needed to hand them back to `connect`. Nothing in here points
    anywhere, so it can be stored in a pool, sorted, retried, and outlive the
    resolution that produced it.
    """

    var bytes: AddrBytes
    var length: socklen_t
    var family: c_int
    var socktype: c_int
    var protocol: c_int

    def __init__(
        out self,
        bytes: AddrBytes,
        length: socklen_t,
        family: c_int,
        socktype: c_int,
        protocol: c_int,
    ):
        self.bytes = bytes
        self.length = length
        self.family = family
        self.socktype = socktype
        self.protocol = protocol

    def is_ipv6(self) -> Bool:
        return self.family == AF_INET6

    def is_ipv4(self) -> Bool:
        return self.family == AF_INET

    def port(self) -> UInt16:
        """The port, read straight out of the address bytes.

        `sin_port` and `sin6_port` are both at offset two and both in network
        byte order, and that is true on macOS despite its leading `sin_len`
        byte, because the length takes the space the wider family field uses on
        Linux. One rule covers all four combinations.
        """
        return (UInt16(self.bytes[2]) << 8) | UInt16(self.bytes[3])

    def with_port(self, port: UInt16) -> Self:
        """The same address with a different port.

        Used when one resolution is reused for a redirect to another port on
        the same host, which saves a lookup that would return the same answer.
        """
        var b = self.bytes
        b[2] = UInt8(port >> 8)
        b[3] = UInt8(port & 0xFF)
        return Self(b, self.length, self.family, self.socktype, self.protocol)

    def text(self) -> String:
        """The numeric text form, for error messages and logs.

        Always numeric. Asking `getnameinfo` for a name would mean a reverse
        lookup, which is a network round trip hiding inside what looks like a
        formatting call, and the answer is attacker controlled anyway.
        """
        var host = List[UInt8](length=MAX_HOST_TEXT, fill=0)
        var rc = external_call["getnameinfo", c_int](
            Pointer(to=self.bytes).unsafe_bitcast[UInt8](),
            self.length,
            Ptr[UInt8](unsafe_from_address=Int(host.unsafe_ptr())),
            socklen_t(MAX_HOST_TEXT),
            c_int(0),
            socklen_t(0),
            NI_NUMERICHOST,
        )
        if rc != 0:
            return String("unknown address")
        var n = 0
        while n < MAX_HOST_TEXT and host[n] != 0:
            n += 1
        # Skipping UTF-8 validation is sound here because NI_NUMERICHOST makes
        # getnameinfo write a numeric address, which is ASCII by construction,
        # and the loop above stopped at the terminator so no uninitialised tail
        # of the buffer is included.
        return String(StringSpan(unsafe_from_utf8=Span(host)[:n]))

    def write_to[W: Writer](self, mut writer: W):
        # Bracket IPv6 the way a URL would, so a logged address can be pasted
        # back into one without the reader having to remember the rule.
        if self.is_ipv6():
            writer.write("[", self.text(), "]")
        else:
            writer.write(self.text())


def connect_addr(fd: c_int, addr: SockAddr) -> c_int:
    """Start a connection to a resolved address.

    This exists so that no caller outside `_ffi` ever has to produce a pointer
    to a `sockaddr`. Returns what `connect` returned, which on a non blocking
    socket is normally -1 with `EINPROGRESS`.
    """
    return connect_to(
        fd, Pointer(to=addr.bytes).unsafe_bitcast[UInt8](), addr.length
    )


def bind_addr(fd: c_int, addr: SockAddr) -> c_int:
    """Bind a socket to a resolved address. Used by the test server."""
    return bind_to(
        fd, Pointer(to=addr.bytes).unsafe_bitcast[UInt8](), addr.length
    )


def getsockname(fd: c_int) raises -> SockAddr:
    """The local address a socket is bound to.

    The reason this exists is binding to port zero. The kernel picks a free
    port and the only way to learn which one is to ask afterwards, which is how
    the test server gets a port without racing another process for a fixed one.
    """
    var bytes = AddrBytes(0)
    var length = socklen_t(SOCKADDR_MAX)
    var rc = external_call["getsockname", c_int](
        fd,
        Pointer(to=bytes).unsafe_bitcast[UInt8](),
        Pointer(to=length),
    )
    if rc != 0:
        raise new_error(
            ErrorKind.NETWORK_ERROR,
            String("getsockname failed: ", strerror(errno())),
        )
    # The family sits at offset zero on Linux and at offset one on macOS, after
    # the length byte. Both are a single byte for the families we use, so this
    # reads the same value on both.
    var family = c_int(Int(bytes[1])) if _MACOS else c_int(Int(bytes[0]))
    return SockAddr(bytes, length, family, SOCK_STREAM, c_int(0))


def gai_strerror(code: c_int) -> String:
    """The libc description of a `getaddrinfo` return code.

    These are `EAI_` values and have nothing to do with errno. Handing one to
    `strerror` produces a confidently wrong message, which is why resolution
    has its own function here.
    """
    return cstr_to_string(external_call["gai_strerror", CStr](code))


def is_ip_literal(host: StringSpan) -> Bool:
    """True when `host` is an address written out rather than a name to look up.

    A colon anywhere means IPv6, because a colon cannot appear in a hostname.
    The whole string has to be scanned for it rather than stopped at the first
    unexpected byte, since an IPv6 literal starts with hex digits and a zone id
    ends with whatever the interface is called. Failing that, it is IPv4 only if
    every byte is a digit or a dot, which no registrable name can be, since the
    last label of a name may not be all digits.

    This only decides which resolver flags to use, so being conservative is
    safe: a literal misread as a name still resolves, just with a flag that does
    not apply to it.
    """
    var bytes = host.as_bytes()
    if bytes.__len__() == 0:
        return False
    for i in range(bytes.__len__()):
        if bytes[i] == UInt8(ord(":")):
            return True
    for i in range(bytes.__len__()):
        var byte = bytes[i]
        if not (
            (byte >= UInt8(ord("0")) and byte <= UInt8(ord("9")))
            or byte == UInt8(ord("."))
        ):
            return False
    return True


def resolve(
    host: StringSpan, port: UInt16, family: c_int = AF_UNSPEC
) raises -> List[SockAddr]:
    """Resolve a host and port to the addresses to try, in the resolver's order.

    `family` defaults to unspecified, which returns both IPv4 and IPv6 in the
    order the platform prefers. That order is the point: it is what makes Happy
    Eyeballs possible in M2. Pinning it to one family is a choice a caller
    makes deliberately, not a default.

    Raises if the name cannot be resolved. The message carries the host, the
    port and the `EAI_` text, because a resolution failure with no host in it
    is unactionable.
    """
    var hints = List[UInt8](length=ADDRINFO_SIZE, fill=0)
    var h = Ptr[UInt8](unsafe_from_address=Int(hints.unsafe_ptr()))
    h.unsafe_offset(_OFF_FAMILY).unsafe_bitcast[c_int]()[] = family
    h.unsafe_offset(_OFF_SOCKTYPE).unsafe_bitcast[c_int]()[] = SOCK_STREAM

    # The port is always a number here, so there is no reason to let the
    # resolver open /etc/services and look for a name it will not find.
    var flags = AI_NUMERICSERV
    if not is_ip_literal(host):
        # Do not offer AAAA records on a machine with no IPv6 route, or every
        # connection pays a failed attempt before falling back.
        #
        # Only for names. glibc counts a host whose only IPv6 address is the
        # loopback as having no IPv6 configured, so AI_ADDRCONFIG makes it
        # refuse to parse `::1` at all, on a machine where connecting to `::1`
        # works perfectly. RFC 3493 defines the flag in terms of what a lookup
        # should return, and a literal is not a lookup.
        flags |= AI_ADDRCONFIG
    h.unsafe_offset(_OFF_FLAGS).unsafe_bitcast[c_int]()[] = flags

    # Both of these must outlive the call, so they are named rather than built
    # inline in the argument list.
    var node = c_string(host)
    var service = c_string(String(port))

    var head = Optional[Ptr[UInt8]](None)
    var rc = external_call["getaddrinfo", c_int](
        CStringSlice(node),
        CStringSlice(service),
        h,
        Pointer(to=head),
    )
    # libc read `hints` through a raw pointer the compiler cannot see, so say
    # plainly that the buffer was still needed up to here.
    _ = hints^

    if rc != 0:
        raise new_error(
            ErrorKind.CONNECT_ERROR,
            String(
                "could not resolve ",
                host,
                " port ",
                port,
                ": ",
                gai_strerror(rc),
            ),
        )
    if not head:
        # Documented as impossible when rc is zero. Treated as a failure rather
        # than trusted, because the alternative is dereferencing null.
        raise new_error(
            ErrorKind.CONNECT_ERROR,
            String("resolver returned no addresses for ", host),
        )

    var out = List[SockAddr]()
    var cur = head
    while cur:
        var p = cur.value()
        _copy_one(p, out)
        cur = p.unsafe_offset(_OFF_NEXT).unsafe_bitcast[
            Optional[Ptr[UInt8]]
        ]()[]

    external_call["freeaddrinfo", NoneType](head.value())

    if len(out) == 0:
        raise new_error(
            ErrorKind.CONNECT_ERROR,
            String("no usable addresses for ", host, " port ", port),
        )
    return out^


def _copy_one(p: Ptr[UInt8], mut out: List[SockAddr]):
    """Copy one `struct addrinfo` entry into an owned `SockAddr`.

    An entry we cannot represent is skipped rather than raised on, because a
    resolver returning one odd family alongside two good addresses should still
    produce a working connection. `resolve` raises only if nothing survives.
    """
    var length = p.unsafe_offset(_OFF_ADDRLEN).unsafe_bitcast[socklen_t]()[]
    if length == 0 or Int(length) > SOCKADDR_MAX:
        return
    var addr = p.unsafe_offset(_OFF_ADDR).unsafe_bitcast[
        Optional[Ptr[UInt8]]
    ]()[]
    if not addr:
        return

    var src = addr.value()
    var bytes = AddrBytes(0)
    for i in range(Int(length)):
        bytes[i] = src.unsafe_offset(i)[]

    # The three reads below are sound for the same reason as the two above:
    # `p` points at a `struct addrinfo` that getaddrinfo filled in and that
    # `resolve` has not yet freed, and the offsets are the ones named at the
    # top of this file with the C declaration beside them.
    out.append(
        SockAddr(
            bytes,
            length,
            p.unsafe_offset(_OFF_FAMILY).unsafe_bitcast[c_int]()[],
            p.unsafe_offset(_OFF_SOCKTYPE).unsafe_bitcast[c_int]()[],
            p.unsafe_offset(_OFF_PROTOCOL).unsafe_bitcast[c_int]()[],
        )
    )
