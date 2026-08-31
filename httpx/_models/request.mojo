"""A request, as a value.

Deliberately small at this stage. The protocol layer needs somewhere to read a
method, a target and a set of headers from, and something to hold the body it is
about to write. Everything the user facing API adds on top, the content types,
the streaming bodies, the extensions, arrives later and does not change what is
here.

The one decision in this file that matters is that a request holds a `URL` and
not a target string. The target depends on how the request is being sent: origin
form to a server, absolute form through a proxy, authority form for CONNECT. A
request that had already made that choice could not be sent through a proxy
without being rebuilt.
"""

from httpx._exceptions import ErrorKind, new_error
from httpx._models.headers import Headers, is_token_byte
from httpx._models.url import URL


def normalize_method(method: StringSpan) raises -> String:
    """Check that `method` is a token and hand it back uppercased.

    Methods are case sensitive in RFC 9110 and every method anybody actually
    uses is already uppercase, so uppercasing turns `get` into something a
    server will answer rather than into a 501. This is what httpx does and the
    reason to match it is that a user writing `get` meant `GET`.

    The token check is not politeness. A method containing a space or a control
    byte would put a second request line into the first one.
    """
    var bytes = method.as_bytes()
    if bytes.__len__() == 0:
        raise new_error(
            ErrorKind.LOCAL_PROTOCOL_ERROR, String("the method cannot be empty")
        )
    var out = String()
    for i in range(bytes.__len__()):
        var byte = bytes[i]
        if not is_token_byte(byte):
            raise new_error(
                ErrorKind.LOCAL_PROTOCOL_ERROR,
                String("not a valid method: ", method),
            )
        if byte >= UInt8(ord("a")) and byte <= UInt8(ord("z")):
            out += chr(Int(byte) - 32)
        else:
            out += chr(Int(byte))
    return out^


struct Request(Movable, Writable):
    """One request, ready to be handed to a transport."""

    var method: String
    var url: URL
    var headers: Headers
    var content: List[UInt8]
    """The whole body, in memory.

    A body that does not fit in memory is a streaming body, and streaming is
    built on top of this rather than instead of it. Until then a request that
    has no body carries an empty list, which is not the same as a request whose
    body happens to be zero bytes long. The framing rules tell them apart by
    looking at the method, not at this.
    """

    def __init__(
        out self,
        method: StringSpan,
        var url: URL,
        var headers: Headers = Headers(),
        var content: List[UInt8] = List[UInt8](),
    ) raises:
        self.method = normalize_method(method)
        self.url = url^
        self.headers = headers^
        self.content = content^

    def copy(self) raises -> Self:
        var out = Self(self.method, self.url.copy_with(), self.headers.copy())
        out.content = self.content.copy()
        return out^

    def has_body(self) -> Bool:
        return len(self.content) > 0

    def write_to[W: Writer](self, mut writer: W):
        # The method and the URL, which is what identifies a request in a log
        # line or a test failure. Never the headers: they hold credentials.
        writer.write("<Request ", self.method, " ", self.url, ">")
