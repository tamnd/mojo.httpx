"""Asking a proxy for a pipe to somewhere else.

`CONNECT` is how an https request gets through a forward proxy. The client asks
the proxy to open a TCP connection to a host and port and then to stop reading
what goes over it, and from the 200 onwards the socket carries whatever the two
ends put on it. For us that is a TLS handshake to the real server, which is the
whole point: the proxy relays the bytes and never sees the request inside them.

That is also why this runs on a raw `TcpStream` rather than on a `Stream`. The
tunnel has to be open before TLS starts, because TLS is the thing being tunnelled,
and `TlsStream` does its handshake as part of construction. So the order is
connect to the proxy, exchange CONNECT over the bare socket, and only then hand
the socket to `TlsStream` with the target's name on it.

The request here is written by hand instead of going through the request writer.
A CONNECT is not a request for a resource: it has no body, no path, no framing
headers and an authority form target, so nearly every decision the writer makes
is one this does not want. The three lines it does write are easier to be sure
about than a set of arguments that turn the writer off.

The reply is a full HTTP response and is parsed as one, which matters for the
failure cases. A proxy that refuses answers 403 or 407 with a body explaining
itself, and reading that as a head rather than looking for `200` in the first
line is what lets the error name the status the proxy actually sent.
"""

from httpx._exceptions import ErrorKind, new_error
from httpx._io.buffer import ByteBuffer
from httpx._io.deadline import Deadline
from httpx._io.socket import TcpStream
from httpx._models.headers import Headers
from httpx._proto.h1.head import ResponseHead, parse_head

comptime READ_SIZE = 8192
"""One page-ish read at a time, matching the HTTP/1.1 connection reader.

A CONNECT reply is a few hundred bytes and arrives in one packet in every case
anybody has seen, so this is sized for the shape of the code rather than for
throughput.
"""


def open_tunnel(
    mut tcp: TcpStream,
    authority: StringSpan,
    headers: Headers,
    deadline: Deadline,
) raises:
    """Turn `tcp` into a pipe to `authority`, or raise saying why not.

    `authority` is `host:port` with an IPv6 address still in its brackets, which
    is the only target form CONNECT takes. `headers` are the proxy's own headers,
    `Proxy-Authorization` among them, and they belong on this request and not on
    the request that goes through the tunnel afterwards: the credential is for
    the hop in front, and sending it inside the tunnel would hand the proxy's
    password to the server on the other end.

    One deadline covers both halves because the whole exchange is part of
    connecting. A caller who set `connect` to two seconds meant two seconds to
    have a usable connection, not two seconds per leg of getting one.
    """
    _write_connect(tcp, authority, headers, deadline)

    var buf = ByteBuffer()
    while True:
        var found = parse_head(buf)
        if found:
            _check_reply(found.take(), buf, authority)
            return
        var scratch = List[UInt8](length=READ_SIZE, fill=0)
        var n = tcp.read(Span(scratch), deadline.renewed())
        if n == 0:
            raise new_error(
                ErrorKind.PROXY_ERROR,
                String(
                    (
                        "the proxy closed the connection without answering the"
                        " CONNECT for "
                    ),
                    authority,
                ),
            )
        buf.extend(Span(scratch)[:n])


def _write_connect(
    mut tcp: TcpStream,
    authority: StringSpan,
    headers: Headers,
    deadline: Deadline,
) raises:
    """Send the request, in one write.

    One write rather than one per line so that the whole head leaves in a single
    segment. A proxy will reassemble either way, but a head split across packets
    is a shape that some middleboxes handle badly and there is no reason to
    produce it.
    """
    var out = String("CONNECT ", authority, " HTTP/1.1\r\n")
    out += "Host: "
    out += authority
    out += "\r\n"
    for field in headers.items():
        out += field[0]
        out += ": "
        out += field[1]
        out += "\r\n"
    out += "\r\n"
    tcp.write(out.as_bytes(), deadline)


def _check_reply(
    var head: ResponseHead, buf: ByteBuffer, authority: StringSpan
) raises:
    """Accept a 2xx, and turn anything else into an error worth reading."""
    if head.status_code < 200 or head.status_code >= 300:
        raise new_error(
            ErrorKind.PROXY_ERROR,
            String(
                "the proxy answered ",
                head.status_code,
                " ",
                head.reason_phrase,
                " to the CONNECT for ",
                authority,
                _hint_for(head.status_code),
            ),
        )

    if not buf.is_empty():
        # The tunnel is now handed to OpenSSL, which reads from the file
        # descriptor itself and has nowhere to be given bytes we already took
        # off it, so anything left here would be silently dropped and the
        # handshake would fail somewhere much less obvious. In practice this is
        # unreachable: the client speaks first inside a tunnel, so after a 200
        # there is nothing for the proxy to have sent.
        raise new_error(
            ErrorKind.PROXY_ERROR,
            String(
                "the proxy sent ",
                len(buf),
                " bytes after accepting the CONNECT for ",
                authority,
                ", which is not something a tunnel is allowed to do",
            ),
        )


def _hint_for(status_code: Int) -> String:
    """The sentence worth adding for the two statuses people actually hit."""
    if status_code == 407:
        return String(
            ", so it wants credentials: put them in the proxy URL or set"
            " Proxy-Authorization on the Proxy"
        )
    if status_code == 403:
        return String(
            ", so it is refusing this destination rather than failing to reach"
            " it"
        )
    return String()
