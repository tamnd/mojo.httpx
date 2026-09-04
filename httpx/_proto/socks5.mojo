"""Asking a SOCKS5 proxy for a pipe to somewhere else. RFC 1928 and RFC 1929.

SOCKS is not an HTTP proxy and the difference is the whole reason it is worth
having. An HTTP proxy reads the request, which is why an `https://` target needs
a `CONNECT` to stop it reading. A SOCKS proxy never reads anything: it is told a
host and a port up front, and after a short binary handshake the socket is a pipe
to that address carrying whatever the two ends put on it. So there is one path
here rather than two, and `http://` and `https://` targets both tunnel.

The name is sent rather than an address, always. Resolving the target locally and
sending the four bytes would work with every proxy in existence, and it would
also announce the destination to whoever is watching the local resolver, which is
the exact thing most people run a SOCKS proxy to avoid. An address is only ever
sent when the caller wrote one, because then there was no name to leak.

This runs on a raw `TcpStream` for the same reason `h1.tunnel` does. The pipe has
to exist before TLS starts, since TLS is the thing being tunnelled, so the order
is connect to the proxy, do the handshake on the bare socket, and only then hand
the socket to `TlsStream` with the target's name on it. The proxy sees a host and
a port and no more, and the certificate that comes back is the server's own.

The bound address on the reply is read and thrown away rather than skipped. It is
a variable length field, so the only way to know where the reply ends is to
consume it, and a byte of it left on the socket would be the first byte OpenSSL
sees. That would fail somewhere far away from the mistake.
"""

from httpx._exceptions import ErrorKind, new_error
from httpx._io.deadline import Deadline
from httpx._io.socket import TcpStream
from httpx._util.ip import looks_like_ipv4, parse_ipv4, parse_ipv6

comptime VERSION = UInt8(5)
"""The version byte on the greeting and on the request. Only 5 is SOCKS5."""

comptime AUTH_VERSION = UInt8(1)
"""The version byte on the username and password exchange.

One rather than five, because RFC 1929 versions the sub-negotiation separately
from the protocol that carries it. A proxy that answers with five here has a bug
worth being told about rather than worth working around, since the next thing
after a lenient read would be reading the status byte off by one.
"""

comptime NO_AUTH = UInt8(0x00)
comptime USERNAME_PASSWORD = UInt8(0x02)
comptime NO_ACCEPTABLE_METHOD = UInt8(0xFF)

comptime CONNECT_COMMAND = UInt8(0x01)

comptime ATYP_IPV4 = UInt8(0x01)
comptime ATYP_DOMAIN = UInt8(0x03)
comptime ATYP_IPV6 = UInt8(0x04)

comptime MAX_FIELD = 255
"""What a single length byte can describe, and so the cap on a name and on a
credential. Longer than any real host name and shorter than a password someone
might paste, which is why the credential is the one that gets checked."""


def open_socks5(
    mut tcp: TcpStream,
    host: StringSpan,
    port: UInt16,
    username: StringSpan,
    password: StringSpan,
    deadline: Deadline,
) raises:
    """Turn `tcp` into a pipe to `host` and `port`, or raise saying why not.

    `host` is the target as the caller wrote it, with an IPv6 literal already out
    of its brackets, which is the form `Origin` keeps. A name goes over as a name
    so the proxy resolves it, and an address goes over as an address.

    `username` and `password` are empty when the proxy wants no credentials, and
    that is not the same as empty credentials: with nothing here the greeting
    does not offer the username and password method at all, so a proxy that
    demands it says no immediately rather than after a failed login.

    One deadline covers the whole handshake because the whole handshake is part
    of connecting. A caller who allowed two seconds to connect meant two seconds
    to have a usable connection, not two seconds for each leg of getting one.
    """
    _negotiate(tcp, username, password, deadline)
    _connect(tcp, host, port, deadline)


def _negotiate(
    mut tcp: TcpStream,
    username: StringSpan,
    password: StringSpan,
    deadline: Deadline,
) raises:
    """Offer what we can do, and do whatever the proxy picks out of it."""
    var credentialed = (
        len(username.as_bytes()) > 0 or len(password.as_bytes()) > 0
    )

    var greeting = List[UInt8]()
    greeting.append(VERSION)
    if credentialed:
        greeting.append(UInt8(2))
        greeting.append(NO_AUTH)
        greeting.append(USERNAME_PASSWORD)
    else:
        greeting.append(UInt8(1))
        greeting.append(NO_AUTH)
    tcp.write(Span(greeting), deadline)

    var reply = _read_exactly(tcp, 2, deadline)
    _check_version(reply[0], VERSION, "greeting")
    var method = reply[1]
    if method == NO_AUTH:
        return
    if method == USERNAME_PASSWORD and credentialed:
        _authenticate(tcp, username, password, deadline)
        return
    if method == NO_ACCEPTABLE_METHOD:
        var hint = String(
            " and it would not accept the username and password offered"
        ) if credentialed else String(
            " and it will not take an unauthenticated connection, so it"
            " probably wants a username and password in the proxy URL"
        )
        raise new_error(
            ErrorKind.PROXY_ERROR,
            String(
                "the SOCKS5 proxy rejected every authentication method offered",
                hint,
            ),
        )
    # Either a method that was never offered or the password method when there
    # was no password to send. Both mean the proxy is answering a greeting other
    # than the one that went out, and carrying on would write the next message
    # into a conversation that is already out of step.
    raise new_error(
        ErrorKind.PROXY_ERROR,
        String(
            "the SOCKS5 proxy chose authentication method ",
            Int(method),
            ", which was not one of the methods offered to it",
        ),
    )


def _authenticate(
    mut tcp: TcpStream,
    username: StringSpan,
    password: StringSpan,
    deadline: Deadline,
) raises:
    """The RFC 1929 exchange: the credentials as bytes, and a yes or a no.

    In the clear, on the hop to the proxy, which is what the method is. It is
    worth knowing rather than worth refusing: the alternative on offer is GSSAPI,
    almost nothing implements it, and a client that would not speak the method
    every SOCKS proxy actually deploys would just not work.
    """
    var user_bytes = username.as_bytes()
    var password_bytes = password.as_bytes()
    if len(user_bytes) > MAX_FIELD or len(password_bytes) > MAX_FIELD:
        raise new_error(
            ErrorKind.INVALID_ARGUMENT,
            String(
                "a SOCKS5 username and password are each at most ",
                MAX_FIELD,
                " bytes, and these are ",
                len(user_bytes),
                " and ",
                len(password_bytes),
            ),
        )

    var out = List[UInt8]()
    out.append(AUTH_VERSION)
    out.append(UInt8(len(user_bytes)))
    out.extend(user_bytes)
    out.append(UInt8(len(password_bytes)))
    out.extend(password_bytes)
    tcp.write(Span(out), deadline)

    var reply = _read_exactly(tcp, 2, deadline)
    _check_version(reply[0], AUTH_VERSION, "username and password reply")
    if reply[1] != UInt8(0):
        raise new_error(
            ErrorKind.PROXY_ERROR,
            String(
                (
                    "the SOCKS5 proxy rejected the username and password, with"
                    " status "
                ),
                Int(reply[1]),
            ),
        )


def _connect(
    mut tcp: TcpStream, host: StringSpan, port: UInt16, deadline: Deadline
) raises:
    """Ask for the pipe, and check that the answer is one."""
    var out = List[UInt8]()
    out.append(VERSION)
    out.append(CONNECT_COMMAND)
    out.append(UInt8(0))
    out.extend(address_bytes(host))
    out.append(UInt8(port >> 8))
    out.append(UInt8(port & 0xFF))
    tcp.write(Span(out), deadline)

    var head = _read_exactly(tcp, 4, deadline)
    _check_version(head[0], VERSION, "reply")
    if head[1] != UInt8(0):
        raise new_error(
            ErrorKind.PROXY_ERROR,
            String(
                "the SOCKS5 proxy would not reach ",
                host,
                ":",
                port,
                ": ",
                reply_message(head[1]),
            ),
        )
    _consume_address(tcp, head[3], deadline)


def address_bytes(host: StringSpan) raises -> List[UInt8]:
    """`host` as an address type byte followed by the address itself.

    A name is sent as a name. See the note at the top of the module about why
    that is the point rather than a shortcut: resolving here and sending the
    result would tell the local resolver where the request is going.

    The two literal forms are still handled, because a caller who typed an
    address had no name to protect and a proxy that got the address as a name
    would have to resolve it back into the same bytes.
    """
    var out = List[UInt8]()
    var bytes = host.as_bytes()

    if _has_colon(bytes):
        # Only an address can contain a colon, since a host name cannot, so one
        # byte decides this without having to try a parse and take the failure.
        var groups = parse_ipv6(bytes)
        out.append(ATYP_IPV6)
        for group in groups:
            out.append(UInt8(group >> 8))
            out.append(UInt8(group & 0xFF))
        return out^

    if looks_like_ipv4(bytes):
        var dotted = parse_ipv4(bytes)
        out.append(ATYP_IPV4)
        for part in dotted.split("."):
            out.append(UInt8(Int(part)))
        return out^

    if len(bytes) == 0:
        raise new_error(
            ErrorKind.INVALID_URL,
            String("a SOCKS5 request needs a host and this one is empty"),
        )
    if len(bytes) > MAX_FIELD:
        raise new_error(
            ErrorKind.INVALID_URL,
            String(
                "'",
                host,
                "' is ",
                len(bytes),
                " bytes and a SOCKS5 request can name at most ",
                MAX_FIELD,
            ),
        )
    out.append(ATYP_DOMAIN)
    out.append(UInt8(len(bytes)))
    out.extend(bytes)
    return out^


def reply_message(code: UInt8) -> String:
    """What the proxy's refusal code means, in words.

    Spelled out rather than left as a number because these are the errors a
    person actually sees, and the difference between the proxy not being allowed
    to reach the host and not being able to is the difference between fixing a
    rule and fixing a network.
    """
    if code == UInt8(1):
        return String("the proxy failed for a reason it did not describe")
    if code == UInt8(2):
        return String("its rules do not allow that destination")
    if code == UInt8(3):
        return String("the network is unreachable from the proxy")
    if code == UInt8(4):
        return String("the host is unreachable from the proxy")
    if code == UInt8(5):
        return String("the connection was refused")
    if code == UInt8(6):
        return String("the time to live expired")
    if code == UInt8(7):
        return String("it does not support the CONNECT command")
    if code == UInt8(8):
        return String("it does not support that kind of address")
    return String("it answered with reply code ", Int(code))


def _consume_address(
    mut tcp: TcpStream, address_type: UInt8, deadline: Deadline
) raises:
    """Read the bound address and port off the socket and drop them.

    Dropped because nothing here wants them. The bound address is the proxy's
    own end of the connection it made, which is of interest to a `BIND` and to
    nothing else. Read because the field is variable length and the socket has
    to be left at the start of the tunnel.
    """
    var length: Int
    if address_type == ATYP_IPV4:
        length = 4
    elif address_type == ATYP_IPV6:
        length = 16
    elif address_type == ATYP_DOMAIN:
        var prefix = _read_exactly(tcp, 1, deadline)
        length = Int(prefix[0])
    else:
        # Unreadable rather than merely odd. Without knowing how long the
        # address is there is no way to find the end of the reply, so the socket
        # cannot be handed on and there is nothing to do but say so.
        raise new_error(
            ErrorKind.PROXY_ERROR,
            String(
                (
                    "the SOCKS5 proxy accepted the connection but described its"
                    " address with type "
                ),
                Int(address_type),
                ", which is not one this client can find the end of",
            ),
        )
    _ = _read_exactly(tcp, length + 2, deadline)


def _check_version(seen: UInt8, expected: UInt8, what: StringSpan) raises:
    if seen == expected:
        return
    raise new_error(
        ErrorKind.PROXY_ERROR,
        String(
            "the SOCKS5 ",
            what,
            " started with version ",
            Int(seen),
            " rather than ",
            Int(expected),
            ", so whatever is on this port is not the proxy it was taken for",
        ),
    )


def _read_exactly(
    mut tcp: TcpStream, count: Int, deadline: Deadline
) raises -> List[UInt8]:
    """Exactly `count` bytes, or a raise.

    Every field in this protocol is fixed length once the field before it has
    been read, so a short read is never an ending here, only a message that has
    not all arrived. Looping is what makes the parsing above able to say what it
    read rather than having to cope with half of it.
    """
    var out = List[UInt8](length=count, fill=0)
    var filled = 0
    while filled < count:
        var n = tcp.read(Span(out)[filled:], deadline.renewed())
        if n == 0:
            raise new_error(
                ErrorKind.PROXY_ERROR,
                String(
                    "the SOCKS5 proxy closed the connection after ",
                    filled,
                    " of the ",
                    count,
                    " bytes its answer needed",
                ),
            )
        filled += n
    return out^


def _has_colon[o: ImmOrigin](text: Span[UInt8, o]) -> Bool:
    for i in range(len(text)):
        if text[i] == UInt8(ord(":")):
            return True
    return False
