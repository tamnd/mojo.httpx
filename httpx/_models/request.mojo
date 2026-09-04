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
from httpx._models.stream import ByteStream
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
    """One request, ready to be handed to a transport.

    ```mojo
    from httpx import Client, Headers, Request, URL


    def main() raises:
        var headers = Headers()
        headers["Accept"] = "application/json"
        var request = Request("GET", URL("https://example.com/users"), headers^)
        with Client() as client:
            print(client.send(request^).status_code)
    ```
    """

    var method: String
    var url: URL
    var headers: Headers
    var content: List[UInt8]
    """The whole body, in memory.

    Empty for a request that has no body and empty for a request whose body is
    a stream. The framing rules tell those apart by the method and by whether
    there is a stream, not by looking at this.
    """

    var _stream: Optional[ByteStream]
    """A body that is not in memory and may not exist yet.

    An upload read from a file, or bytes produced as they are needed. Sent as
    `Transfer-Encoding: chunked` unless the caller set a `Content-Length`
    themselves, which they can do when they know the size in advance and want
    the server to know it too.
    """

    var _body_gone: Bool
    """Set on the copy of a request whose body was a stream.

    A stream cannot be copied, only shared, and two requests sharing one body
    would each send half of it. So the copy is made without the body and
    remembers that it is missing one, which turns an unsendable request into an
    error at the point of sending rather than a request that quietly goes out
    empty.
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
        self._stream = None
        self._body_gone = False

    @staticmethod
    def streaming(
        method: StringSpan,
        var url: URL,
        var stream: ByteStream,
        var headers: Headers = Headers(),
    ) raises -> Self:
        """A request whose body is pulled as it is written.

        The counterpart of `Response.streaming`, and for the same reason: an
        upload large enough to matter should not have to be in memory twice, and
        a body that is being produced as it goes has no length to declare.

        Sent one chunk at a time, so this can only be sent once. A retry, a
        redirect or an auth challenge that needs the body again cannot have it,
        and says so rather than sending an empty one.
        """
        var out = Self(method, url^, headers^)
        out._stream = Optional[ByteStream](stream^)
        return out^

    def copy(self) raises -> Self:
        var out = Self(self.method, self.url.copy_with(), self.headers.copy())
        out.content = self.content.copy()
        # A streaming body is not copied, because there is only one of it. What
        # the copy carries instead is the knowledge that it is missing.
        out._body_gone = self._body_gone or Bool(self._stream)
        return out^

    def has_body(self) -> Bool:
        return len(self.content) > 0 or Bool(self._stream)

    def has_stream(self) -> Bool:
        return Bool(self._stream)

    def body_was_taken(self) -> Bool:
        """Whether this request once had a streaming body and no longer does.

        The question a redirect asks before trying to send the same body to a
        new location. A body that was pulled from a source as it went out is not
        somewhere it can be pulled from again, and this is how the caller finds
        that out instead of silently sending nothing.
        """
        return self._body_gone

    def take_stream(mut self) raises -> ByteStream:
        """The body, taken rather than borrowed, because it can only go once.

        Raises on a request that never had one and on a copy of a request that
        did, which is the whole point of the second case: a redirect handler
        that tried to replay a streamed upload finds out here instead of sending
        an empty body to the new location.
        """
        if self._body_gone:
            raise new_error(
                ErrorKind.REQUEST_NOT_READ,
                String(
                    "this request's body was a stream and has already been"
                    " handed to another request, so it cannot be sent again."
                    " Read the body into memory and build the request with"
                    " content= if it has to be sent more than once"
                ),
            )
        if not self._stream:
            raise new_error(
                ErrorKind.REQUEST_NOT_READ,
                String("this request does not have a streaming body"),
            )
        self._body_gone = True
        return self._stream.take()

    def write_to[W: Writer](self, mut writer: W):
        # The method and the URL, which is what identifies a request in a log
        # line or a test failure. Never the headers: they hold credentials.
        writer.write("<Request ", self.method, " ", self.url, ">")
