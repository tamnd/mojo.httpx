"""Parsing the head of an HTTP/1.1 response.

This is the most security sensitive code in the library. Every request smuggling
vulnerability is a disagreement between two parsers about where one message ends
and the next begins, and the way to not have one is to reject anything ambiguous
rather than to guess well. Everything here that looks pedantic is there because
somebody built an exploit out of the lenient version.

The parse is incremental. It is handed whatever bytes have arrived and either
reports that the head is not complete yet, changing nothing, or consumes exactly
the head and returns it. That is what lets one implementation serve a client
reading in whatever sizes the network happens to deliver, including one byte at
a time.

Nothing here allocates per line. The whole head is looked at as spans into the
read buffer and materialised once, when it is known to be complete and valid.
"""

from httpx._bytes import _CR, _HTAB, _LF, _SPACE, is_digit, starts_with
from httpx._exceptions import ErrorKind, new_error
from httpx._io.buffer import ByteBuffer
from httpx._models.headers import Headers, is_token_byte

comptime MAX_HEADERS = 100
"""How many field lines a response may have.

Not configurable, because it is not a preference. It is a bound on how much
memory a hostile server can make a client allocate before the client has decided
whether it trusts anything. A hundred is more than any real response and small
enough that a thousand connections holding the maximum is still nothing.
"""

comptime MAX_LINE = 16384
"""How long one field line may be, in bytes. Cookies are why this is not 8192.
"""

comptime MAX_HEAD = 65536
"""How long the whole head may be, in bytes, terminator included."""


struct ResponseHead(Movable):
    """A status line and a set of field lines, nothing more.

    Separate from `Response` because a head is what the parser produces and a
    response is what the caller receives. Between the two sits the framing
    decision, which needs the head and the request method and produces neither.
    """

    var status_code: Int
    var reason_phrase: String
    var http_version: String
    var headers: Headers

    def __init__(
        out self,
        status_code: Int,
        var reason_phrase: String,
        var http_version: String,
        var headers: Headers,
    ):
        self.status_code = status_code
        self.reason_phrase = reason_phrase^
        self.http_version = http_version^
        self.headers = headers^

    def is_http_1_1(self) -> Bool:
        return self.http_version == "HTTP/1.1"

    def take_headers(mut self) -> Headers:
        """The fields, leaving the head with none.

        A swap rather than a move. Mojo will not let a field whose type has a
        destructor be moved out of a value that still has to be destroyed, and
        copying every header on every response to work around that is a cost
        nobody should pay on the hot path.
        """
        var out = Headers()
        swap(out, self.headers)
        return out^


def _remote(message: String) -> Error:
    """The server did this, not us. Users need to know which end to look at."""
    return new_error(ErrorKind.REMOTE_PROTOCOL_ERROR, message)


def parse_head(mut buf: ByteBuffer) raises -> Optional[ResponseHead]:
    """Take the head out of `buf`, or leave `buf` untouched and report nothing.

    Nothing is consumed until the whole head is known to be there and valid,
    which is what makes calling this again after more bytes arrive correct
    rather than merely usual.
    """
    var end = _end_of_head(buf.unread())
    if end < 0:
        return None
    var head = _parse(buf.unread()[:end])
    buf.consume(end)
    return head^


def _end_of_head[o: ImmOrigin](span: Span[UInt8, o]) raises -> Int:
    """How many bytes the head occupies, terminator included, or -1 for later.

    Finding the end is a separate pass from parsing it because the two answer
    different questions. This one asks whether enough has arrived, and it is
    also where the size limits live, so that a server which never sends a blank
    line is cut off rather than buffered forever.
    """
    var at = 0
    while True:
        var line_end = index_of_lf(span, at)
        if line_end < 0:
            # No complete line yet. The limits still apply, otherwise a server
            # that sends 64 KiB without a newline costs us 64 KiB.
            if span.__len__() - at > MAX_LINE:
                raise _remote(
                    String(
                        "the server sent a header line longer than ",
                        MAX_LINE,
                        " bytes",
                    )
                )
            if span.__len__() > MAX_HEAD:
                raise _remote(
                    String(
                        "the server sent a response head longer than ",
                        MAX_HEAD,
                        " bytes",
                    )
                )
            return -1
        if line_end - at > MAX_LINE:
            raise _remote(
                String(
                    "the server sent a header line longer than ",
                    MAX_LINE,
                    " bytes",
                )
            )
        if line_end + 1 > MAX_HEAD:
            raise _remote(
                String(
                    "the server sent a response head longer than ",
                    MAX_HEAD,
                    " bytes",
                )
            )
        if _line_is_blank(span, at, line_end):
            return line_end + 1
        at = line_end + 1


def index_of_lf[o: ImmOrigin](span: Span[UInt8, o], start: Int) -> Int:
    """Where the next line ends, or -1 when it has not ended yet.

    Scanning for the newline rather than for the pair is what makes accepting a
    bare newline fall out for free, and it is also what lets the carriage return
    rule be one check in one place.
    """
    for i in range(start, span.__len__()):
        if span[i] == _LF:
            return i
    return -1


def _line_is_blank[
    o: ImmOrigin
](span: Span[UInt8, o], start: Int, line_end: Int) -> Bool:
    """Whether the line at `start` is the blank one that ends the head.

    A bare newline counts, because real servers send them and a client that
    refused would be unusable. A bare carriage return does not, and that is
    checked where the line is parsed rather than here.
    """
    if line_end == start:
        return True
    return line_end == start + 1 and span[start] == _CR


def line_without_terminator[
    o: ImmOrigin
](span: Span[UInt8, o], start: Int, line_end: Int) raises -> Span[UInt8, o]:
    """One line without its terminator, with a bare carriage return rejected.

    RFC 9112 section 2.2 allows a receiver to accept a bare newline as a line
    terminator, which is the leniency real servers need. It does not allow a
    bare carriage return anywhere, and accepting one is how two parsers end up
    disagreeing about where a line ended.
    """
    var end = line_end
    if end > start and span[end - 1] == _CR:
        end -= 1
    for i in range(start, end):
        if span[i] == _CR:
            raise _remote(
                "the server sent a carriage return inside a header line"
            )
    return span[start:end]


def _parse[o: ImmOrigin](span: Span[UInt8, o]) raises -> ResponseHead:
    """Parse a head that is known to be complete."""
    var line_end = index_of_lf(span, 0)
    var status = line_without_terminator(span, 0, line_end)
    var version = _parse_version(status)
    var code = _parse_status_code(status)
    var reason = _parse_reason(status)

    var headers = Headers()
    var at = line_end + 1
    var count = 0
    while at < span.__len__():
        var end = index_of_lf(span, at)
        if _line_is_blank(span, at, end):
            break
        var field = line_without_terminator(span, at, end)
        count += 1
        if count > MAX_HEADERS:
            raise _remote(
                String("the server sent more than ", MAX_HEADERS, " headers")
            )
        append_field_line(headers, field)
        at = end + 1

    return ResponseHead(code, reason^, version^, headers^)


def _parse_version[o: ImmOrigin](status: Span[UInt8, o]) raises -> String:
    """`HTTP/1.0` or `HTTP/1.1`, and nothing else.

    HTTP/0.9 had no status line at all, so a response claiming to be it is
    either a server that is confused or something that is not a server. HTTP/2
    and later do not use this framing, so a status line claiming them is the
    same. In every case the safe answer is to stop rather than to guess how the
    body is delimited.
    """
    if status.__len__() < 8 or not starts_with(status, "HTTP/".as_bytes()):
        raise _remote("the server did not send an HTTP status line")
    var major = status[5]
    var dot = status[6]
    var minor = status[7]
    if dot != UInt8(ord(".")) or major != UInt8(ord("1")):
        raise _remote("the server answered with a version we do not speak")
    if minor != UInt8(ord("0")) and minor != UInt8(ord("1")):
        raise _remote("the server answered with a version we do not speak")
    return String("HTTP/1.", chr(Int(minor)))


def _parse_status_code[o: ImmOrigin](status: Span[UInt8, o]) raises -> Int:
    """Exactly three digits after exactly one space.

    Two digits or four is not a status code that got mangled, it is a message
    whose shape we do not recognise, and a client that guessed would be
    guessing about how to frame the body.
    """
    if status.__len__() < 12 or status[8] != _SPACE:
        raise _remote("the server did not send a status code")
    for i in range(9, 12):
        if not is_digit(status[i]):
            raise _remote("the server sent a status code that is not a number")
    if status.__len__() > 12 and status[12] != _SPACE:
        raise _remote("the server sent a status code that is not three digits")
    return (
        Int(status[9] - UInt8(ord("0"))) * 100
        + Int(status[10] - UInt8(ord("0"))) * 10
        + Int(status[11] - UInt8(ord("0")))
    )


def _parse_reason[o: ImmOrigin](status: Span[UInt8, o]) raises -> String:
    """Whatever the server put after the code, verbatim.

    May be empty, may contain spaces, and is never used for anything but being
    shown to a person. Kept as sent because a server that answered
    `200 Totally Fine` said that, and reporting `200 OK` instead would make the
    logs disagree with the wire for no benefit.
    """
    if status.__len__() <= 13:
        return String()
    return String(StringSpan(from_utf8=status[13:]))


def append_field_line[
    o: ImmOrigin
](mut headers: Headers, field: Span[UInt8, o]) raises:
    """One field line, with every ambiguous spelling rejected."""
    if field.__len__() == 0:
        raise _remote("the server sent an empty header line")

    # Obsolete line folding. RFC 9112 section 5.2 deprecated it and says a
    # client may reject it. Accepting it means a header value can contain what
    # looks like another header, which is a header injection primitive.
    if field[0] == _SPACE or field[0] == _HTAB:
        raise _remote("the server sent a folded header line")

    var colon = -1
    for i in range(field.__len__()):
        if field[i] == UInt8(ord(":")):
            colon = i
            break
    if colon < 0:
        raise _remote("the server sent a header line with no colon in it")
    if colon == 0:
        raise _remote("the server sent a header line with no name")

    var name = field[:colon]
    for i in range(name.__len__()):
        if not is_token_byte(name[i]):
            # This is what rejects whitespace before the colon. A proxy that
            # trims the space and a client that does not are two parsers that
            # disagree about the name of a field, which for `Content-Length` is
            # the whole of a desync.
            raise _remote("the server sent a header name that is not a token")

    headers.append_raw(name, field[colon + 1 :])
