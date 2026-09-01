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
from httpx._ffi.clock import unix_now
from httpx._io.deadline import now_ns
from httpx._models.cookies import Cookies
from httpx._models.headers import Headers
from httpx._models.iterators import ByteChunks, LineChunks, TextChunks
from httpx._models.json import Json, parse_json
from httpx._models.request import Request
from httpx._models.stream import ByteStream, buffered_stream, empty_stream
from httpx._models.url import URL
from httpx._util.charset import (
    DEFAULT_CHARSET,
    UNKNOWN,
    UTF_8,
    DefaultEncoding,
    charset_id,
    decode_charset,
    is_known_charset,
)
from httpx._util.duration import Duration
from httpx._util.erase import ErasedBox
from httpx._util.links import Link, parse_links
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

    var _request: Optional[Request]
    """What was sent to get this, put here by whoever sent it.

    The transport hands the request back inside the response rather than
    consuming it, because the client above needs it again for a redirect, an
    auth challenge or a retry, and rebuilding it from nothing would mean
    guessing at the body.
    """

    var _next_request: Optional[Request]
    """The request that would follow this redirect, when one was worked out.

    Only ever set on a redirect the client was told not to follow, which is how
    a caller steps through a redirect chain themselves.
    """

    var _history: List[ErasedBox]
    """The redirects that led here, oldest first.

    Boxed rather than held as a `List[Response]` because a struct in Mojo 1.0
    cannot contain itself, not even through a list. The box forgets the type on
    the way in and `history` remembers it on the way out, so the field is legal
    and the accessor still hands back responses.
    """

    var _started_ns: UInt64
    """The monotonic clock when the request went out, or zero if nobody timed it.

    Set by the client rather than by the constructor, because the response does
    not exist yet at the moment that matters. Zero means the response was built
    by hand and `elapsed` has nothing to report.
    """

    var _elapsed: Optional[Duration]
    """How long the whole exchange took, once it is over.

    Filled in by `read` and by `close`, which are the two ways an exchange ends,
    so a streamed body is timed to its last byte rather than to its headers.
    """

    var _downloaded: Int

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
        self._request = None
        self._next_request = None
        self._history = List[ErasedBox]()
        self._started_ns = 0
        self._elapsed = None
        self._downloaded = len(self._content)

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
        out._downloaded = 0
        return out^

    def copy(self) raises -> Self:
        """Another response with the same body.

        Only meaningful once the body has been read, which is why the copy
        starts read: a copy of a response that is still arriving would be a
        second handle on one stream, and whichever of the two was read first
        would take the bytes from the other.

        The history is shared rather than duplicated. The responses in it are
        finished and nothing can change them, so a second reference is as good
        as a second copy and costs a count instead of every body in the chain.
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
        out._started_ns = self._started_ns
        out._elapsed = self._elapsed
        out._downloaded = self._downloaded
        if self._request:
            out._request = Optional[Request](self._request.value().copy())
        if self._next_request:
            out._next_request = Optional[Request](
                self._next_request.value().copy()
            )
        for i in range(len(self._history)):
            out._history.append(self._history[i].copy())
        return out^

    def set_request(mut self, var request: Request):
        """Record what was sent to get this response.

        Called by the transport on its way out, with the request it has just
        finished writing. Nothing above the transport should have to do this and
        nothing below it has the request to do it with.
        """
        self._request = Optional[Request](request^)

    def has_request(self) -> Bool:
        return Bool(self._request)

    def request(ref self) raises -> ref[self._request._value] Request:
        """What was sent to get this response.

        Raises rather than handing back an empty request when nothing set one,
        which happens only for a response built by hand. An empty request would
        answer `url` with an empty URL and the caller would have no way to tell
        that apart from a real answer.
        """
        if not self._request:
            raise Error(
                "RuntimeError: this response did not come from sending a"
                " request, so there is nothing to report as its request"
            )
        return self._request.value()

    def url(self) raises -> URL:
        """The URL this response came from.

        After a followed redirect chain that is the last URL in the chain, not
        the one the caller asked for. The one they asked for is on the first
        entry of `history`.
        """
        return self.request().url.copy()

    def cookies(self) raises -> Cookies:
        """The cookies this one response set, and nothing else.

        A fresh jar rather than the client's, so this answers what the server
        just sent rather than what has accumulated over a session. The client's
        jar is `client.cookies` and is the one that decides what goes back out.

        The URL matters, because a `Set-Cookie` naming a domain the responding
        host does not belong to is dropped, so this needs the request that
        produced the response and raises without one.
        """
        var out = Cookies()
        _ = out.extract(self.request().url, self.headers, unix_now())
        return out^

    def history(self) raises -> List[Self]:
        """The redirects that led here, oldest first.

        Copies, because the responses in the chain are shared with anything else
        that took a copy of this one. They have been read and closed by the time
        they get here, so a copy costs a body in memory and nothing else.
        """
        var out = List[Self]()
        for i in range(len(self._history)):
            out.append(self._history[i].get[Self]().copy())
        return out^

    def history_count(self) -> Int:
        """How many redirects led here, without copying any of them."""
        return len(self._history)

    def inherit_history(mut self, var prior: Self):
        """Take on `prior`'s history, and then `prior` itself.

        How a redirect chain is threaded together: each response is handed the
        one before it, so the response the caller finally gets carries the whole
        chain and the client does not have to keep a list of its own alongside.
        """
        var chain = List[ErasedBox]()
        for i in range(len(prior._history)):
            chain.append(prior._history[i].copy())
        chain.append(ErasedBox.make[Self](prior^))
        self._history = chain^

    def set_next_request(mut self, var request: Request):
        self._next_request = Optional[Request](request^)

    def has_next_request(self) -> Bool:
        """Whether there is a redirect here that was not followed."""
        return Bool(self._next_request)

    def next_request(mut self) raises -> Request:
        """The request that follows this redirect, taken rather than borrowed.

        Set only when the client was told not to follow redirects, which is the
        default. Taken because sending it consumes it, and handing a second
        caller a second copy would be a second copy of a body that may only go
        out once. Ask `has_next_request` first.
        """
        if not self._next_request:
            raise Error(
                "RuntimeError: this response has no redirect to follow, so"
                " there is no next request to take"
            )
        return self._next_request.take()

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
        self._downloaded = chunks.num_bytes_downloaded()
        # Only after the last chunk, because trailers are by definition what
        # comes after the body. A response read through the iterators instead
        # never sees them, which is the price of the response not being able to
        # reach back into an iterator that has already been handed out.
        self.trailers = self._stream.trailers()
        self._read = True
        self.is_closed = True
        self._stop_timing()

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

    def num_bytes_downloaded(self) -> Int:
        """How many bytes of the body have arrived.

        For a response that was read, the whole body. For one built by hand, its
        content. For one handed to an iterator, this stops moving at the point
        the iterator took the stream, because from there the bytes go past the
        iterator and the response never sees them. That is what
        `ByteChunks.num_bytes_downloaded` is for, and it is the number a progress
        bar over a streamed download should be reading.
        """
        return self._downloaded

    def begin_timing(mut self, started_ns: UInt64):
        """Record when the request went out, so `elapsed` has something to
        subtract from.

        Called by the client with a reading it took just before handing the
        request to the transport. Not by the transport, because there are three
        of those and only the client is on the path every response takes.

        A response that is already read when it gets here is one the transport
        buffered, so its exchange is over and the clock stops in the same call.
        A streamed one is still open and stops later, in `read` or in `close`.
        """
        self._started_ns = started_ns
        if self._read or self.is_closed:
            self._stop_timing()

    def _stop_timing(mut self):
        """Freeze `elapsed` at the moment the exchange ended.

        Only the first call counts. `read` then `close` is an ordinary sequence
        and the answer should be how long the body took, not how long the caller
        waited before closing.
        """
        if self._started_ns == 0 or self._elapsed:
            return
        self._elapsed = Optional[Duration](
            Duration.between(self._started_ns, now_ns())
        )

    def elapsed(self) raises -> Duration:
        """How long the whole exchange took, headers and body together.

        Available once the body has been read or the response closed, and raises
        before that, which is what httpx2 does. The reason is that a number
        covering only the headers would be the answer to a question nobody asked:
        a response is slow because of its body far more often than because of its
        status line, and quietly reporting the smaller number would hide exactly
        the case worth measuring.

        A response built by hand was never sent, so this raises for one of those
        no matter what has been called on it.
        """
        if not self._elapsed:
            raise Error(
                "RuntimeError: elapsed() is only available once the response"
                " has been read or closed"
            )
        return self._elapsed.value()

    def close(mut self):
        """Give up whatever is still arriving and release the connection.

        Safe to call on a response that is already closed, and safe to call
        without having read the body, which is the point: a caller who decided
        on the status line that they do not want the body should be able to say
        so and get the connection back.
        """
        self._stream.close()
        self.is_closed = True
        self._stop_timing()

    def __enter__(var self) -> Self:
        """Hand the response to the `with` block, which then owns it.

        This is what makes `with client.stream(...) as r:` read the way it does
        in httpx. The block owning the response is what releases the connection:
        the response is destroyed at the end of the block whether the body was
        read or not, and the stream underneath it gives the connection back or
        closes it from its own destructor.

        Consuming rather than borrowing, because Mojo 1.0 will not enter a
        `with` on a value that is neither copyable nor transferred.
        """
        return self^

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

    def links(self) raises -> List[Link]:
        """The `Link` header, parsed, in the order it was written.

        A list rather than the dictionary keyed on `rel` that httpx2 gives back.
        Two links in one header may carry the same relation, which is legal and
        which the dictionary loses, and a link may carry several relations at
        once, which the dictionary hides under a key nobody would guess. Keeping
        the list keeps both, and `link_url` covers the case the dictionary was
        for.
        """
        return parse_links(self.headers.get("link").as_bytes())

    def link_url(self, rel: StringSpan) raises -> Optional[URL]:
        """Where the link with this relation points, ready to fetch.

        The pagination case, which is nearly the whole reason the header exists:
        `link_url("next")` and you have somewhere to go.

        Resolved against this response's URL, because a relative target is legal
        and common and resolving it needs a base the parser does not have. That
        means this raises for a response built by hand, which has no URL to
        resolve against. httpx2 hands back the target unresolved and leaves the
        join to the caller, who then has to remember to do it.
        """
        var found = self.links()
        for i in range(len(found)):
            if found[i].has_rel(rel):
                return self.url().join(found[i].url)
        return None

    def raise_for_status(self) raises:
        """Raise if the status was not a success.

        `HTTPStatusError` for anything outside 2xx, including 1xx and 3xx. A 3xx
        reaching this means redirects were not being followed, so the caller got
        a response they cannot use as an answer, and treating it as success would
        hand them a body that is usually empty.

        Returns nothing, where httpx2 returns the response so the call can be
        chained onto. A `Response` here is not copyable, so a method that gave
        one back would have to consume the receiver, and `r.raise_for_status()`
        on its own line is a small price for `r` still being usable afterwards.

        Raises a different error, about the response never having been sent, if
        it was built by hand. There is no URL to name in the message, and a
        status error that could not say which request failed would be worse than
        the complaint.
        """
        if self.is_success():
            return

        var url = self.url()
        var phrase = self.reason_phrase.copy()
        if phrase == "":
            phrase = String(status_text(self.status_code))

        var kind: StaticString
        if self.is_informational():
            kind = "Informational response"
        elif self.has_redirect_status():
            kind = "Redirect response"
        elif self.is_client_error():
            kind = "Client error"
        elif self.is_server_error():
            kind = "Server error"
        else:
            kind = "Invalid status code"

        var message = String(kind, " '", self.status_code)
        if phrase != "":
            # Only when there is one. A status nobody registered and no server
            # named would otherwise be quoted with a trailing space in it.
            message += String(" ", phrase)
        message += String("' for url '", url, "'")
        if self.is_redirect():
            # Worth naming, because a 3xx arriving here means the caller turned
            # following off and the location is the thing they will want next.
            message += String(
                ", redirect location '", self.headers.get("location"), "'"
            )
        raise new_error(ErrorKind.HTTP_STATUS_ERROR, message^)

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
