"""A response, as a value.

Small for the same reason `Request` is: the protocol layer needs somewhere to
put what it parsed. Encoding detection, the streaming state machine and the
convenience accessors come later and sit on top of these fields rather than
replacing them.

`reason_phrase` and `http_version` are kept verbatim rather than being derived
from the status code. A server that answers `200 Totally Fine` said that, and a
client that reported `200 OK` instead would be making debugging harder to no
purpose.
"""

from httpx._exceptions import ErrorKind, new_error
from httpx._models.headers import Headers
from httpx._models.iterators import ByteChunks, LineChunks, TextChunks
from httpx._models.json import Json, parse_json
from httpx._models.stream import ByteStream, buffered_stream, empty_stream
from httpx._util.charset import (
    DEFAULT_CHARSET,
    UNKNOWN,
    UTF_8,
    DefaultEncoding,
    charset_id,
    decode_charset,
    is_known_charset,
)
from httpx._util.media import parse_media_type


def status_text(code: Int) -> StaticString:
    """The registered reason phrase for a status code.

    Used when a server sends an empty phrase, which is legal, so that a log line
    still says something. Never used to override a phrase the server sent.
    """
    if code == 100:
        return "Continue"
    if code == 101:
        return "Switching Protocols"
    if code == 200:
        return "OK"
    if code == 201:
        return "Created"
    if code == 202:
        return "Accepted"
    if code == 204:
        return "No Content"
    if code == 206:
        return "Partial Content"
    if code == 301:
        return "Moved Permanently"
    if code == 302:
        return "Found"
    if code == 303:
        return "See Other"
    if code == 304:
        return "Not Modified"
    if code == 307:
        return "Temporary Redirect"
    if code == 308:
        return "Permanent Redirect"
    if code == 400:
        return "Bad Request"
    if code == 401:
        return "Unauthorized"
    if code == 403:
        return "Forbidden"
    if code == 404:
        return "Not Found"
    if code == 405:
        return "Method Not Allowed"
    if code == 408:
        return "Request Timeout"
    if code == 409:
        return "Conflict"
    if code == 410:
        return "Gone"
    if code == 413:
        return "Content Too Large"
    if code == 415:
        return "Unsupported Media Type"
    if code == 418:
        return "I'm a teapot"
    if code == 421:
        return "Misdirected Request"
    if code == 422:
        return "Unprocessable Content"
    if code == 429:
        return "Too Many Requests"
    if code == 500:
        return "Internal Server Error"
    if code == 501:
        return "Not Implemented"
    if code == 502:
        return "Bad Gateway"
    if code == 503:
        return "Service Unavailable"
    if code == 504:
        return "Gateway Timeout"
    return ""


struct Response(Movable, Writable):
    """One parsed response."""

    var status_code: Int
    var reason_phrase: String
    var http_version: String
    """`HTTP/1.1` or `HTTP/1.0`, as the server wrote it.

    Kept because it decides whether the connection can be reused: 1.0 needs an
    explicit `Connection: keep-alive` and 1.1 does not.
    """

    var headers: Headers
    var _content: List[UInt8]
    """The body, once it has been read. Meaningless before then.

    Private because reading it before the body has arrived would hand back an
    empty list that looks exactly like an empty body. `content()` is the way in
    and it says so instead.
    """

    var _stream: ByteStream
    """Where the rest of the body is coming from.

    A buffered source holding nothing once the body has been read, so that every
    response has one and no code path has to check.
    """

    var _read: Bool
    """Whether the whole body is in `_content`."""

    var is_stream_consumed: Bool
    """Whether the stream has been handed to an iterator.

    Public because httpx2 exposes it and because it answers the question a
    caller actually has after catching a `StreamConsumed`, which is whether they
    are the one who consumed it.
    """

    var is_closed: Bool
    """Whether anything more can be read from this response."""

    var trailers: Headers
    """The fields after the last chunk of a chunked body.

    Almost always empty. Kept separate from `headers` rather than merged into
    them, because a field that arrived after the body was read cannot have been
    used to frame it, and merging would let a trailer answer a question the head
    already answered.
    """

    var default_encoding: DefaultEncoding
    """What to read the body as when the response does not say.

    UTF-8 unless the caller changes it. Set on the client and carried down to
    every response it produces, which is the only place a caller can express
    knowledge about a service that mislabels its bodies.
    """

    def __init__(
        out self,
        status_code: Int,
        var reason_phrase: String = String(),
        var http_version: String = String("HTTP/1.1"),
        var headers: Headers = Headers(),
        var content: List[UInt8] = List[UInt8](),
        var trailers: Headers = Headers(),
        var default_encoding: DefaultEncoding = DefaultEncoding(),
    ):
        """A response whose body is already in hand.

        What a test double builds and what the transport returns for a body it
        read to the end. Nothing is left to arrive, so the response starts read
        and closed and `content()` works straight away.
        """
        self.status_code = status_code
        self.reason_phrase = reason_phrase^
        self.http_version = http_version^
        self.headers = headers^
        self._content = content^
        self._stream = empty_stream()
        self._read = True
        self.is_stream_consumed = True
        self.is_closed = True
        self.trailers = trailers^
        self.default_encoding = default_encoding^

    @staticmethod
    def streaming(
        status_code: Int,
        var stream: ByteStream,
        var reason_phrase: String = String(),
        var http_version: String = String("HTTP/1.1"),
        var headers: Headers = Headers(),
        var default_encoding: DefaultEncoding = DefaultEncoding(),
    ) -> Self:
        """A response whose body has not been read yet.

        A separate constructor rather than an overload, because the difference
        between the two is not one argument, it is which half of the state
        machine the response starts in, and a reader should not have to work
        that out from an argument type.
        """
        var out = Self(status_code, reason_phrase^, http_version^, headers^)
        out._stream = stream^
        out._read = False
        out.is_stream_consumed = False
        out.is_closed = False
        out.default_encoding = default_encoding^
        return out^

    def copy(self) -> Self:
        """Another response with the same body.

        Only meaningful once the body has been read, which is why the copy
        starts read: a copy of a response that is still arriving would be a
        second handle on one stream, and whichever of the two was read first
        would take the bytes from the other.
        """
        var out = Self(
            self.status_code,
            self.reason_phrase.copy(),
            self.http_version.copy(),
            self.headers.copy(),
        )
        out._content = self._content.copy()
        out.trailers = self.trailers.copy()
        out.default_encoding = self.default_encoding.copy()
        return out^

    def read(mut self) raises:
        """Pull the whole body into memory, if it is not there already.

        Idempotent. Calling it on a response that has been read is what a
        redirect handler and an auth flow both end up doing, and making that an
        error would mean every caller checking first.
        """
        if self._read:
            return
        var chunks = self.iter_raw()
        while chunks.has_next():
            self._content.extend(Span(chunks.next()))
        self._read = True
        self.is_closed = True

    def content(ref self) raises -> Span[UInt8, origin_of(self._content)]:
        """The body as bytes.

        Raises when the body has not been read, rather than handing back the
        empty list that is sitting there, because an empty body and a body that
        has not arrived are different answers and a caller acting on the wrong
        one has no way to find out.

        A borrowed span rather than a copy. A response body can be large and the
        common uses, parsing it or writing it somewhere, do not need to own it.
        """
        if not self._read:
            raise new_error(
                ErrorKind.RESPONSE_NOT_READ,
                String(
                    "the body of this response has not been read, call read()"
                    " or use one of the iterators"
                ),
            )
        return Span(self._content)

    def close(mut self):
        """Give up whatever is still arriving and release the connection.

        Safe to call on a response that is already closed, and safe to call
        without having read the body, which is the point: a caller who decided
        on the status line that they do not want the body should be able to say
        so and get the connection back.
        """
        self._stream.close()
        self.is_closed = True

    def iter_raw(mut self, chunk_size: Int = 0) raises -> ByteChunks:
        """The body exactly as it arrives, before any content decoding.

        Consumes the stream. A second call raises, because the bytes went to the
        first caller and there is nowhere to get them back from.
        """
        if self.is_stream_consumed:
            raise new_error(
                ErrorKind.STREAM_CONSUMED,
                String(
                    "this response body has already been streamed, and a body"
                    " can only be read once"
                ),
            )
        if self.is_closed:
            raise new_error(
                ErrorKind.STREAM_CLOSED,
                String("this response is closed and has nothing left to read"),
            )
        self.is_stream_consumed = True
        # Closed at the moment the stream is handed over rather than when the
        # iterator finishes with it. From here the response cannot produce
        # anything itself, and saying otherwise would let a second reader in.
        self.is_closed = True
        return ByteChunks(self._stream.copy(), chunk_size)

    def iter_bytes(mut self, chunk_size: Int = 0) raises -> ByteChunks:
        """The body with any content encoding undone.

        The same bytes as `iter_raw` today, because the codecs are not written
        yet. The two are separate calls anyway, because they answer different
        questions and only one of them changes when gzip lands.

        Works on a response that has already been read, where `iter_raw` would
        refuse. That is httpx2's behaviour and it is the right one: re-reading
        bytes that are sitting in memory costs nothing and asks nothing of the
        connection.
        """
        if self._read:
            return ByteChunks(buffered_stream(self._content.copy()), chunk_size)
        return self.iter_raw(chunk_size)

    def iter_text(mut self, chunk_size: Int = 0) raises -> TextChunks:
        """The body decoded to text, in chunks of that many characters.

        A character that straddles a chunk boundary is held back until the rest
        of it arrives, so the text is the same whatever sizes the server wrote
        in. Characters rather than bytes because that is what httpx2 counts, and
        a chunk measured in bytes could not keep that promise anyway.
        """
        var id = self._encoding_id()
        if self._read:
            return TextChunks(
                buffered_stream(self._content.copy()), id, chunk_size
            )
        var stream = self._take_stream()
        return TextChunks(stream^, id, chunk_size)

    def iter_lines(mut self) raises -> LineChunks:
        """The body decoded to text and split into lines, terminators removed.

        Every separator Python's `splitlines` recognises, because that is what
        httpx2's line decoder reproduces. So `\\n`, `\\r\\n` and `\\r`, and also
        the vertical tab, the form feed, the three information separators, and
        U+0085, U+2028 and U+2029.
        """
        var id = self._encoding_id()
        if self._read:
            return LineChunks(buffered_stream(self._content.copy()), id)
        var stream = self._take_stream()
        return LineChunks(stream^, id)

    def _take_stream(mut self) raises -> ByteStream:
        """Hand the live stream over, with the same guards `iter_raw` applies.

        The text and line iterators go through here rather than through
        `iter_raw` so that they are not also re-chunking the bytes on the way,
        but a body can still only be read once and the errors have to say the
        same thing.
        """
        if self.is_stream_consumed:
            raise new_error(
                ErrorKind.STREAM_CONSUMED,
                String(
                    "this response body has already been streamed, and a body"
                    " can only be read once"
                ),
            )
        if self.is_closed:
            raise new_error(
                ErrorKind.STREAM_CLOSED,
                String("this response is closed and has nothing left to read"),
            )
        self.is_stream_consumed = True
        self.is_closed = True
        return self._stream.copy()

    def charset_encoding(self) -> Optional[String]:
        """The `charset` parameter of the content type, or nothing.

        Lowercased, because charset labels are case insensitive and a caller
        comparing the result against a literal should not have to know that.
        Nothing is returned when there is no content type, no `charset`, or an
        empty one, and all three mean the same thing to `encoding`.
        """
        var raw = self.headers.get_span("content-type")
        if not raw:
            return None
        var media = parse_media_type(raw.value())
        var found = media.param("charset")
        if not found or found.value() == "":
            return None
        return found.value().lower()

    def encoding(self) raises -> String:
        """The encoding the body will be read as.

        The charset from the content type when it names something this can
        decode, and `default_encoding` otherwise. An unknown label falls back
        rather than failing, which is what httpx2 does with a label Python has no
        codec for and is the only sensible answer: a server that names an
        encoding nobody implements has still sent a body, and it is almost always
        UTF-8.
        """
        var declared = self.charset_encoding()
        if declared and is_known_charset(declared.value()):
            return declared.value()
        if self.default_encoding.detect and not self._read:
            # A detector has nothing to look at until the body is in memory, so
            # a streaming response gets the plain default instead of being asked
            # to guess from nothing. httpx2 does the same, for the same reason.
            return String(DEFAULT_CHARSET)
        return self.default_encoding.resolve(self._content)

    def _encoding_id(self) raises -> Int:
        var id = charset_id(self.encoding())
        if id == UNKNOWN:
            return UTF_8
        return id

    def text(self) raises -> String:
        """The body decoded as text, with anything undecodable replaced.

        Never fails on the bytes. A body that does not decode still deserves to
        be shown, and every undecodable sequence becomes U+FFFD, which is what
        httpx2 gives back because Python's incremental decoder is asked for
        `errors="replace"`. The `raises` is for the detector hook on
        `default_encoding`, which is the caller's own code and may fail.

        A caller who needs to know whether the body really was the encoding it
        claimed reads `content` and decodes that strictly. `r.json()` already
        does, so a body that lies about its encoding fails there rather than
        arriving as replacement characters.
        """
        return decode_charset(self.content(), self.encoding())

    def json(self) raises -> Json:
        """The body parsed as JSON.

        The content type is not consulted. Plenty of real services send JSON
        labelled `text/plain` or with no type at all, and refusing to parse a
        body that is obviously JSON because of a header the caller cannot
        change would only mean the caller reaches past this to `parse_json`.
        A body that is not JSON raises either way.
        """
        return parse_json(self.content())

    def is_informational(self) -> Bool:
        return 100 <= self.status_code and self.status_code < 200

    def is_success(self) -> Bool:
        return 200 <= self.status_code and self.status_code < 300

    def is_redirect(self) -> Bool:
        """3xx with a `Location`.

        A 3xx without one cannot be followed, so calling it a redirect would
        promise something the caller cannot act on. This is the same rule httpx
        uses and it is why `is_redirect` is not just a range check.
        """
        if not (300 <= self.status_code and self.status_code < 400):
            return False
        return "location" in self.headers

    def has_redirect_status(self) -> Bool:
        """3xx, whether or not it can be followed."""
        return 300 <= self.status_code and self.status_code < 400

    def is_client_error(self) -> Bool:
        return 400 <= self.status_code and self.status_code < 500

    def is_server_error(self) -> Bool:
        return 500 <= self.status_code and self.status_code < 600

    def is_error(self) -> Bool:
        return 400 <= self.status_code and self.status_code < 600

    def write_to[W: Writer](self, mut writer: W):
        writer.write("<Response [", self.status_code)
        if self.reason_phrase.byte_length() > 0:
            writer.write(" ", self.reason_phrase)
        else:
            var known = status_text(self.status_code)
            if known != "":
                writer.write(" ", known)
        writer.write("]>")
