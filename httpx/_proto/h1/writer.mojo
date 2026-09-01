"""Turning a request into bytes.

The whole head goes into one buffer and leaves in one write. That is not an
optimisation for its own sake: a request line that arrives in its own packet
ahead of its headers is a request that some servers and most intrusion detection
systems see differently from one that arrives whole, and being predictable on
the wire is worth more than saving a copy.

Everything written here is validated first. A header value containing a newline
is a second request, so the check that stops one is the difference between a
library and a header injection vector. The models already check what they are
given, and this checks again on the way out, because the cost is a scan of a few
hundred bytes and the failure mode is somebody else's data.
"""

from httpx._bytes import _CR, _LF, equal_ascii_ci
from httpx._exceptions import ErrorKind, new_error
from httpx._models.headers import Headers
from httpx._models.request import Request
from httpx._models.url import URL


struct TargetForm(Equatable, ImplicitlyCopyable, Movable):
    """Which of the four request target shapes RFC 9112 section 3.2 defines.

    A caller picks the form rather than the request carrying it, because the
    same request goes out in origin form to a server and in absolute form to a
    proxy, and the request has no way of knowing which it is about to be.
    """

    var value: Int

    comptime ORIGIN = Self(0)
    """`/path?query`. What a server gets."""

    comptime ABSOLUTE = Self(1)
    """`http://host/path?query`. What an HTTP proxy gets."""

    comptime AUTHORITY = Self(2)
    """`host:port`. `CONNECT` only."""

    comptime ASTERISK = Self(3)
    """`*`. `OPTIONS` asking about the server rather than a resource."""

    def __init__(out self, value: Int):
        self.value = value

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value


def _local(message: String) -> Error:
    """We are about to send something malformed. Better to refuse."""
    return new_error(ErrorKind.LOCAL_PROTOCOL_ERROR, message)


def request_target(url: URL, form: TargetForm) raises -> String:
    """The text that goes between the method and the version."""
    if form == TargetForm.ASTERISK:
        return String("*")
    if form == TargetForm.AUTHORITY:
        # `CONNECT` names a place to open a socket to, not a resource, and the
        # port is required even when it is the scheme default because there is
        # no scheme in the target to take a default from.
        var port = url.effective_port()
        if not port:
            raise _local("a CONNECT target needs a port")
        return String(
            StringSpan(from_utf8=url.raw_host()), ":", Int(port.value())
        )
    if form == TargetForm.ABSOLUTE:
        return String(
            StringSpan(from_utf8=url.raw_scheme()),
            "://",
            url.netloc(),
            url.raw_path(),
        )
    return url.raw_path()


def host_header_value(url: URL) raises -> String:
    """What goes in `Host`, which is the netloc and never the userinfo.

    Sending credentials in `Host` would put them in the access log of every hop,
    and `netloc` is the accessor that leaves them out.
    """
    var host = url.netloc()
    if host.byte_length() == 0:
        raise _local("a request needs a host")
    return host^


def serialize_head(
    request: Request, form: TargetForm = TargetForm.ORIGIN
) raises -> List[UInt8]:
    """The request line, the headers and the blank line, as one buffer.

    `Host` goes first and comes from the URL rather than from the headers.
    RFC 9112 section 3.2 says it should be first, some servers care, and taking
    it from the URL means a request cannot be sent to one host while claiming
    to be for another unless the caller sets it deliberately.
    """
    var out = List[UInt8]()
    _write(out, request.method.as_bytes())
    out.append(_SP)
    var target = request_target(request.url, form)
    _check_no_control(target.as_bytes(), "the request target")
    _write(out, target.as_bytes())
    out.append(_SP)
    _write(out, "HTTP/1.1".as_bytes())
    _write_crlf(out)

    if "host" not in request.headers:
        _write_field(
            out, "Host".as_bytes(), host_header_value(request.url).as_bytes()
        )

    for i in range(len(request.headers)):
        _write_field(
            out, request.headers.raw_name(i), request.headers.raw_value(i)
        )

    _write_crlf(out)
    return out^


def framing_headers(
    method: StringSpan,
    headers: Headers,
    content_length: Optional[Int],
    streaming: Bool = False,
) raises -> Headers:
    """The framing fields a request needs, given what the caller already set.

    A caller who set `Content-Length` themselves is taken at their word right up
    to the point where the word contradicts the body, because a length that
    disagrees with what is about to be written is the client side of the same
    desync this library refuses to accept from a server.

    `streaming` says the body is being pulled as it is written, so there is no
    length to declare unless the caller declared one. A caller who knows the
    size of what they are about to stream, an upload from a file being the usual
    case, can set `Content-Length` and get a length framed body instead, which
    is worth doing because some servers and more proxies still handle chunked
    request bodies badly.
    """
    var out = Headers()
    var has_length = "content-length" in headers
    var has_encoding = "transfer-encoding" in headers

    if has_length and has_encoding:
        raise _local(
            "a request cannot have both Content-Length and Transfer-Encoding"
        )

    if has_encoding:
        # The caller is streaming and said so. Nothing to add.
        return out^

    if has_length:
        if content_length:
            var declared = _parse_declared_length(headers)
            if declared != content_length.value():
                raise _local(
                    String(
                        "the Content-Length says ",
                        declared,
                        " but the body is ",
                        content_length.value(),
                        " bytes",
                    )
                )
        return out^

    if content_length:
        out.append("Content-Length", String(content_length.value()))
        return out^

    if streaming:
        out.append("Transfer-Encoding", "chunked")
        return out^

    # No body and no framing set. A `GET` with `Content-Length: 0` is legal and
    # makes some servers and more WAFs treat the request as suspicious, so the
    # methods that never carry a body get nothing. The methods that usually do
    # get an explicit zero, because a `POST` with no framing at all reads to
    # some servers as a body that has not arrived yet.
    if _body_is_expected(method):
        out.append("Content-Length", "0")
    return out^


def chunk[o: ImmOrigin](data: Span[UInt8, o]) raises -> List[UInt8]:
    """One chunk, sized and terminated.

    A zero length chunk is not written at all. On the wire it looks exactly
    like the terminal chunk, so writing one would end the body in the middle of
    it.
    """
    var out = List[UInt8]()
    if data.__len__() == 0:
        return out^
    _write(out, _hex(data.__len__()).as_bytes())
    _write_crlf(out)
    _write(out, data)
    _write_crlf(out)
    return out^


def terminal_chunk(trailers: Headers) raises -> List[UInt8]:
    """The `0` chunk, any trailers, and the blank line that ends the body."""
    var out = List[UInt8]()
    _write(out, "0".as_bytes())
    _write_crlf(out)
    for i in range(len(trailers)):
        _write_field(out, trailers.raw_name(i), trailers.raw_value(i))
    _write_crlf(out)
    return out^


comptime _SP = UInt8(0x20)
comptime _COLON = UInt8(0x3A)
comptime _HEX_DIGITS = "0123456789abcdef"


def _write[o: ImmOrigin](mut out: List[UInt8], data: Span[UInt8, o]):
    out.extend(data)


def _write_crlf(mut out: List[UInt8]):
    out.append(_CR)
    out.append(_LF)


def _write_field[
    n: ImmOrigin, v: ImmOrigin
](mut out: List[UInt8], name: Span[UInt8, n], value: Span[UInt8, v]):
    _write(out, name)
    out.append(_COLON)
    out.append(_SP)
    _write(out, value)
    _write_crlf(out)


def _check_no_control[
    o: ImmOrigin
](data: Span[UInt8, o], what: StringSpan) raises:
    """Refuse anything that could end the line early.

    The models check this on the way in. Checking again on the way out is cheap
    and means a value that reached the buffer by some route the models do not
    cover still cannot become a second request line.
    """
    for i in range(data.__len__()):
        var byte = data[i]
        if byte == _CR or byte == _LF or byte == UInt8(0):
            raise _local(String("there is a control character in ", what))


def _body_is_expected(method: StringSpan) -> Bool:
    """Whether a request with this method normally carries a body.

    Only used to decide whether an absent body is spelled `Content-Length: 0` or
    not spelled at all. Both are legal for every method, so getting this wrong
    is a matter of taste rather than of correctness, and the taste is httpx's.
    """
    var bytes = method.as_bytes()
    if equal_ascii_ci(bytes, "GET".as_bytes()):
        return False
    if equal_ascii_ci(bytes, "HEAD".as_bytes()):
        return False
    if equal_ascii_ci(bytes, "DELETE".as_bytes()):
        return False
    if equal_ascii_ci(bytes, "OPTIONS".as_bytes()):
        return False
    if equal_ascii_ci(bytes, "CONNECT".as_bytes()):
        return False
    if equal_ascii_ci(bytes, "TRACE".as_bytes()):
        return False
    return True


def _parse_declared_length(headers: Headers) raises -> Int:
    var text = headers["content-length"]
    try:
        return Int(text)
    except:
        raise _local(String("the Content-Length is not a number: ", text))


def _hex(value: Int) raises -> String:
    """Lowercase, no prefix, no padding, which is what a chunk size is.

    Built as bytes and turned into a string once. Indexing a string by position
    is not a thing in Mojo, for the good reason that a position in UTF-8 means
    three different things, and hex digits are the case where none of that
    matters.
    """
    if value == 0:
        return String("0")
    var digits = _HEX_DIGITS.as_bytes()
    var reversed = List[UInt8]()
    var left = value
    while left > 0:
        reversed.append(digits[left & 15])
        left >>= 4
    var out = List[UInt8]()
    for i in range(len(reversed)):
        out.append(reversed[len(reversed) - 1 - i])
    return String(StringSpan(from_utf8=Span(out)))
