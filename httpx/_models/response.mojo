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

from httpx._models.headers import Headers
from httpx._models.json import Json, parse_json
from httpx._util.charset import (
    DefaultEncoding,
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
    var content: List[UInt8]
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
        self.status_code = status_code
        self.reason_phrase = reason_phrase^
        self.http_version = http_version^
        self.headers = headers^
        self.content = content^
        self.trailers = trailers^
        self.default_encoding = default_encoding^

    def copy(self) -> Self:
        var out = Self(
            self.status_code,
            self.reason_phrase.copy(),
            self.http_version.copy(),
            self.headers.copy(),
        )
        out.content = self.content.copy()
        out.trailers = self.trailers.copy()
        out.default_encoding = self.default_encoding.copy()
        return out^

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
        return self.default_encoding.resolve(self.content)

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
        return decode_charset(Span(self.content), self.encoding())

    def json(self) raises -> Json:
        """The body parsed as JSON.

        The content type is not consulted. Plenty of real services send JSON
        labelled `text/plain` or with no type at all, and refusing to parse a
        body that is obviously JSON because of a header the caller cannot
        change would only mean the caller reaches past this to `parse_json`.
        A body that is not JSON raises either way.
        """
        return parse_json(Span(self.content))

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
