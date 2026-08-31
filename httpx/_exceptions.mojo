"""The error taxonomy.

httpx2 gives you a class hierarchy and you catch at whatever level of
granularity you want:

    except httpx.TimeoutException:   # any of the four timeouts
    except httpx.TransportError:     # any network layer failure
    except httpx.HTTPError:          # anything raised for a request

Mojo has exactly one error type. `raise` takes an `Error`, `except e` binds it,
there are no subclasses and no `except SomeType` filtering. So the hierarchy is
reproduced rather than transliterated.

`ErrorKind` is a flat value whose nibbles encode the path from the root of the
httpx2 tree, so asking "is this a timeout" is a mask and a compare rather than a
walk. `Error` itself is a string, so the kind travels as the leading name token
of the message. That is not a trick: httpx2 messages already read
`ConnectError: ...`, so the wire format here is the human readable form and
parsing it back is exact.

    try:
        var r = client.get(url)
    except e:
        if httpx.is_timeout(e):
            retry_later()
        elif httpx.is_status_error(e):
            log(httpx.kind_of(e).name())
        else:
            raise e
"""


struct ErrorKind(Equatable, ImplicitlyCopyable, Movable):
    """A node in the httpx2 error hierarchy.

    The value is read as a sequence of nibbles from the most significant end,
    one per level of the tree. A zero nibble means the path stops there, so an
    ancestor is a prefix of every one of its descendants and membership is a
    masked compare.

        HTTPError           0x10000
        RequestError        0x11000
        TransportError      0x11100
        TimeoutException    0x11110
        ConnectTimeout      0x11111

    Nothing uses zero as a child index, which is what makes the prefix trick
    unambiguous.
    """

    var value: UInt32

    def __init__(out self, value: UInt32):
        self.value = value

    # Not a real node. Anything we cannot identify lands here, and it satisfies
    # no predicate, so an unrecognised error is never mistaken for a timeout.
    comptime UNKNOWN = ErrorKind(0x00000)

    # HTTPError, everything the library raises for a request.
    comptime HTTP_ERROR = ErrorKind(0x10000)

    comptime REQUEST_ERROR = ErrorKind(0x11000)

    comptime TRANSPORT_ERROR = ErrorKind(0x11100)

    comptime TIMEOUT = ErrorKind(0x11110)
    comptime CONNECT_TIMEOUT = ErrorKind(0x11111)
    comptime READ_TIMEOUT = ErrorKind(0x11112)
    comptime WRITE_TIMEOUT = ErrorKind(0x11113)
    comptime POOL_TIMEOUT = ErrorKind(0x11114)

    comptime NETWORK_ERROR = ErrorKind(0x11120)
    comptime CONNECT_ERROR = ErrorKind(0x11121)
    comptime READ_ERROR = ErrorKind(0x11122)
    comptime WRITE_ERROR = ErrorKind(0x11123)
    comptime CLOSE_ERROR = ErrorKind(0x11124)

    comptime PROTOCOL_ERROR = ErrorKind(0x11130)
    comptime LOCAL_PROTOCOL_ERROR = ErrorKind(0x11131)
    comptime REMOTE_PROTOCOL_ERROR = ErrorKind(0x11132)

    comptime PROXY_ERROR = ErrorKind(0x11140)
    comptime UNSUPPORTED_PROTOCOL = ErrorKind(0x11150)

    comptime DECODING_ERROR = ErrorKind(0x11200)
    comptime TOO_MANY_REDIRECTS = ErrorKind(0x11300)
    comptime INVALID_URL = ErrorKind(0x11400)

    comptime HTTP_STATUS_ERROR = ErrorKind(0x12000)

    # StreamError is deliberately not under HTTPError, matching httpx2. These
    # mean the calling code has a bug, not that the network misbehaved.
    comptime STREAM_ERROR = ErrorKind(0x20000)
    comptime STREAM_CONSUMED = ErrorKind(0x21000)
    comptime STREAM_CLOSED = ErrorKind(0x22000)
    comptime RESPONSE_NOT_READ = ErrorKind(0x23000)
    comptime REQUEST_NOT_READ = ErrorKind(0x24000)

    # Usage errors, also outside HTTPError in httpx2.
    comptime COOKIE_CONFLICT = ErrorKind(0x30000)
    comptime INVALID_HEADER = ErrorKind(0x31000)
    comptime INVALID_ARGUMENT = ErrorKind(0x32000)

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value

    def matches(self, ancestor: Self) -> Bool:
        """Whether this kind is `ancestor` or sits underneath it.

        A node matches itself, so `CONNECT_TIMEOUT.matches(CONNECT_TIMEOUT)` is
        true, the same way `except ConnectTimeout` catches a `ConnectTimeout`.
        """
        if ancestor.value == 0:
            return False
        return (self.value & _prefix_mask(ancestor.value)) == ancestor.value

    def name(self) -> String:
        """The httpx2 name for this kind, which is also how it is spelled in a
        message.

        This is deliberately the only way to render a kind. Conforming to
        `Writable` would also make an `ErrorKind` implicitly convertible to an
        `Error`, and then `is_invalid_url(kind_of(e))` would compile: it would
        build an `Error` whose whole text is `InvalidURL`, find no colon to read
        a name from, and answer `False` for every kind. Every predicate below
        takes an `Error`, so that mistake is easy to make and returns a plausible
        answer. Without the conformance it does not compile.
        """
        return String(_name_of(self.value))


comptime _COLON = UInt8(ord(":"))
comptime _SPACE = UInt8(ord(" "))


def _prefix_mask(value: UInt32) -> UInt32:
    """A mask covering exactly the non-zero nibbles of `value`.

    The nibbles are contiguous from the top by construction, so this selects the
    part of a descendant that has to match.
    """
    var mask: UInt32 = 0
    for i in range(8):
        var shift = UInt32(i * 4)
        if (value >> shift) & 0xF != 0:
            mask |= UInt32(0xF) << shift
    return mask


def _name_of(value: UInt32) -> StaticString:
    if value == 0x10000:
        return "HTTPError"
    if value == 0x11000:
        return "RequestError"
    if value == 0x11100:
        return "TransportError"
    if value == 0x11110:
        return "TimeoutException"
    if value == 0x11111:
        return "ConnectTimeout"
    if value == 0x11112:
        return "ReadTimeout"
    if value == 0x11113:
        return "WriteTimeout"
    if value == 0x11114:
        return "PoolTimeout"
    if value == 0x11120:
        return "NetworkError"
    if value == 0x11121:
        return "ConnectError"
    if value == 0x11122:
        return "ReadError"
    if value == 0x11123:
        return "WriteError"
    if value == 0x11124:
        return "CloseError"
    if value == 0x11130:
        return "ProtocolError"
    if value == 0x11131:
        return "LocalProtocolError"
    if value == 0x11132:
        return "RemoteProtocolError"
    if value == 0x11140:
        return "ProxyError"
    if value == 0x11150:
        return "UnsupportedProtocol"
    if value == 0x11200:
        return "DecodingError"
    if value == 0x11300:
        return "TooManyRedirects"
    if value == 0x11400:
        return "InvalidURL"
    if value == 0x12000:
        return "HTTPStatusError"
    if value == 0x20000:
        return "StreamError"
    if value == 0x21000:
        return "StreamConsumed"
    if value == 0x22000:
        return "StreamClosed"
    if value == 0x23000:
        return "ResponseNotRead"
    if value == 0x24000:
        return "RequestNotRead"
    if value == 0x30000:
        return "CookieConflict"
    if value == 0x31000:
        return "InvalidHeader"
    if value == 0x32000:
        return "InvalidArgument"
    return "UnknownError"


def kind_from_name(name: StringSpan) -> ErrorKind:
    """Look a kind up by its httpx2 name.

    Returns `UNKNOWN` for anything unrecognised, which is what makes it safe to
    run over an arbitrary error message.
    """
    if name == "HTTPError":
        return ErrorKind.HTTP_ERROR
    if name == "RequestError":
        return ErrorKind.REQUEST_ERROR
    if name == "TransportError":
        return ErrorKind.TRANSPORT_ERROR
    if name == "TimeoutException":
        return ErrorKind.TIMEOUT
    if name == "ConnectTimeout":
        return ErrorKind.CONNECT_TIMEOUT
    if name == "ReadTimeout":
        return ErrorKind.READ_TIMEOUT
    if name == "WriteTimeout":
        return ErrorKind.WRITE_TIMEOUT
    if name == "PoolTimeout":
        return ErrorKind.POOL_TIMEOUT
    if name == "NetworkError":
        return ErrorKind.NETWORK_ERROR
    if name == "ConnectError":
        return ErrorKind.CONNECT_ERROR
    if name == "ReadError":
        return ErrorKind.READ_ERROR
    if name == "WriteError":
        return ErrorKind.WRITE_ERROR
    if name == "CloseError":
        return ErrorKind.CLOSE_ERROR
    if name == "ProtocolError":
        return ErrorKind.PROTOCOL_ERROR
    if name == "LocalProtocolError":
        return ErrorKind.LOCAL_PROTOCOL_ERROR
    if name == "RemoteProtocolError":
        return ErrorKind.REMOTE_PROTOCOL_ERROR
    if name == "ProxyError":
        return ErrorKind.PROXY_ERROR
    if name == "UnsupportedProtocol":
        return ErrorKind.UNSUPPORTED_PROTOCOL
    if name == "DecodingError":
        return ErrorKind.DECODING_ERROR
    if name == "TooManyRedirects":
        return ErrorKind.TOO_MANY_REDIRECTS
    if name == "InvalidURL":
        return ErrorKind.INVALID_URL
    if name == "HTTPStatusError":
        return ErrorKind.HTTP_STATUS_ERROR
    if name == "StreamError":
        return ErrorKind.STREAM_ERROR
    if name == "StreamConsumed":
        return ErrorKind.STREAM_CONSUMED
    if name == "StreamClosed":
        return ErrorKind.STREAM_CLOSED
    if name == "ResponseNotRead":
        return ErrorKind.RESPONSE_NOT_READ
    if name == "RequestNotRead":
        return ErrorKind.REQUEST_NOT_READ
    if name == "CookieConflict":
        return ErrorKind.COOKIE_CONFLICT
    if name == "InvalidHeader":
        return ErrorKind.INVALID_HEADER
    if name == "InvalidArgument":
        return ErrorKind.INVALID_ARGUMENT
    return ErrorKind.UNKNOWN


def new_error(kind: ErrorKind, message: StringSpan) -> Error:
    """Build an error of `kind`.

    The result reads as `Name: message`, which is both what the user sees and
    what `kind_of` reads back.
    """
    return Error(String(kind.name(), ": ", message))


def kind_of(imm e: Error) -> ErrorKind:
    """Recover the kind from an error.

    Returns `UNKNOWN` for an error this library did not raise, so predicates are
    safe to run over anything.
    """
    var text = String(e)
    var bytes = text.as_bytes()
    var n = len(bytes)
    for i in range(n):
        # The name runs up to the first colon. Stopping at a space too keeps a
        # message that merely contains a colon from being read as a name.
        if bytes[i] == _COLON:
            return kind_from_name(text[byte=0:i])
        if bytes[i] == _SPACE:
            return ErrorKind.UNKNOWN
    return ErrorKind.UNKNOWN


def message_of(imm e: Error) -> String:
    """The error text with the leading kind name stripped.

    Returns the whole string when there is no recognised name, so nothing is
    ever lost.
    """
    var text = String(e)
    if kind_of(e) == ErrorKind.UNKNOWN:
        return text
    var bytes = text.as_bytes()
    var n = len(bytes)
    for i in range(n):
        if bytes[i] == _COLON:
            var start = i + 1
            while start < n and bytes[start] == _SPACE:
                start += 1
            return String(text[byte=start:n])
    return text


# Predicates. One per interior node of the hierarchy, which together are the
# public catching API. This is the closest Mojo gets to `except TimeoutException`.


def is_http_error(imm e: Error) -> Bool:
    return kind_of(e).matches(ErrorKind.HTTP_ERROR)


def is_request_error(imm e: Error) -> Bool:
    return kind_of(e).matches(ErrorKind.REQUEST_ERROR)


def is_transport_error(imm e: Error) -> Bool:
    return kind_of(e).matches(ErrorKind.TRANSPORT_ERROR)


def is_timeout(imm e: Error) -> Bool:
    return kind_of(e).matches(ErrorKind.TIMEOUT)


def is_network_error(imm e: Error) -> Bool:
    return kind_of(e).matches(ErrorKind.NETWORK_ERROR)


def is_protocol_error(imm e: Error) -> Bool:
    return kind_of(e).matches(ErrorKind.PROTOCOL_ERROR)


def is_local_protocol_error(imm e: Error) -> Bool:
    """Whether we produced a message the protocol does not allow.

    Worth separating from the remote case because the two need different
    reactions. This one is a bug in the calling code and no amount of retrying
    will help.
    """
    return kind_of(e) == ErrorKind.LOCAL_PROTOCOL_ERROR


def is_remote_protocol_error(imm e: Error) -> Bool:
    """Whether the server sent something the protocol does not allow.

    The connection cannot be reused after one of these, because not knowing
    where the message ended means not knowing where the next one starts.
    """
    return kind_of(e) == ErrorKind.REMOTE_PROTOCOL_ERROR


def is_proxy_error(imm e: Error) -> Bool:
    return kind_of(e).matches(ErrorKind.PROXY_ERROR)


def is_unsupported_protocol(imm e: Error) -> Bool:
    """Whether the URL asked for a scheme this library does not speak.

    A transport error rather than a URL error, because the URL is fine and it is
    the routing of it that cannot be done. That also means a caller catching
    transport failures catches this one, which is what someone passing user
    supplied URLs wants.
    """
    return kind_of(e).matches(ErrorKind.UNSUPPORTED_PROTOCOL)


def is_decoding_error(imm e: Error) -> Bool:
    return kind_of(e).matches(ErrorKind.DECODING_ERROR)


def is_status_error(imm e: Error) -> Bool:
    return kind_of(e).matches(ErrorKind.HTTP_STATUS_ERROR)


def is_stream_error(imm e: Error) -> Bool:
    return kind_of(e).matches(ErrorKind.STREAM_ERROR)


def is_connect_timeout(imm e: Error) -> Bool:
    return kind_of(e) == ErrorKind.CONNECT_TIMEOUT


def is_read_timeout(imm e: Error) -> Bool:
    return kind_of(e) == ErrorKind.READ_TIMEOUT


def is_write_timeout(imm e: Error) -> Bool:
    return kind_of(e) == ErrorKind.WRITE_TIMEOUT


def is_pool_timeout(imm e: Error) -> Bool:
    return kind_of(e) == ErrorKind.POOL_TIMEOUT


def is_connect_error(imm e: Error) -> Bool:
    return kind_of(e) == ErrorKind.CONNECT_ERROR


def is_too_many_redirects(imm e: Error) -> Bool:
    return kind_of(e) == ErrorKind.TOO_MANY_REDIRECTS


def is_invalid_url(imm e: Error) -> Bool:
    return kind_of(e) == ErrorKind.INVALID_URL


def is_invalid_header(imm e: Error) -> Bool:
    return kind_of(e) == ErrorKind.INVALID_HEADER


def is_invalid_argument(imm e: Error) -> Bool:
    """Whether a value handed to this library was one it cannot work with.

    Outside `HTTPError` on purpose, alongside the other usage errors. A caller
    catching request failures should not also catch its own bad configuration,
    because the two need entirely different fixes.
    """
    return kind_of(e) == ErrorKind.INVALID_ARGUMENT


def is_cookie_conflict(imm e: Error) -> Bool:
    return kind_of(e) == ErrorKind.COOKIE_CONFLICT
