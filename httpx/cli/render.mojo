"""Turning a request, a response head and a JSON body into bytes to print.

Split out from the driver because the driver is about what happens when
something fails, and this is about what the output looks like when nothing
does. The two were in one file and reading either of them meant skipping over
the other.

Everything here builds a buffer rather than writing. A partial line on stdout
followed by a failure is a mess for whatever is reading, and building the whole
thing first means the write is one call that either happened or did not.

The heads are written in HTTP/1.1 wire shape whatever the exchange actually
was, which is what curl and httpie both do. It is the form people can read, and
an HTTP/2 request rendered as its pseudo-header block would be honest and
useless.
"""

from httpx import Headers, Response, parse_json
from httpx._proto.h1.writer import (
    TargetForm,
    host_header_value,
    request_target,
)
from httpx.cli.args import Args
from httpx.cli.style import BOLD, CYAN, GREEN, MAGENTA, RESET, YELLOW, Style

comptime INDENT = "  "
"""Two spaces per level, which is what every JSON tool that is not Python
defaults to and what fits a nested body on a screen."""

comptime _TAB = UInt8(ord("\t"))
comptime _NEWLINE = UInt8(ord("\n"))
comptime _RETURN = UInt8(ord("\r"))
comptime _SPACE = UInt8(ord(" "))
comptime _QUOTE = UInt8(ord('"'))
comptime _BACKSLASH = UInt8(ord("\\"))
comptime _COLON = UInt8(ord(":"))
comptime _COMMA = UInt8(ord(","))
comptime _LBRACE = UInt8(ord("{"))
comptime _RBRACE = UInt8(ord("}"))
comptime _LBRACKET = UInt8(ord("["))
comptime _RBRACKET = UInt8(ord("]"))
comptime _MINUS = UInt8(ord("-"))
comptime _ZERO = UInt8(ord("0"))
comptime _NINE = UInt8(ord("9"))


def add[o: ImmOrigin](mut buf: List[UInt8], data: Span[UInt8, o]):
    buf.extend(data)


def add_text(mut buf: List[UInt8], text: StringSpan):
    buf.extend(text.as_bytes())


def _add_headers(mut buf: List[UInt8], headers: Headers, style: Style):
    """Field lines as they were supplied, one per line, then a blank one.

    The name is coloured and the value is not. A value can be anything and
    colouring it would mean deciding what it is, whereas a name is a token and
    the thing a reader is scanning for.
    """
    for i in range(len(headers)):
        if style.on:
            add_text(buf, "\x1b[")
            add_text(buf, CYAN)
            add_text(buf, "m")
        add(buf, headers.raw_name(i))
        if style.on:
            add_text(buf, RESET)
        add_text(buf, ": ")
        add(buf, headers.raw_value(i))
        add_text(buf, "\r\n")
    add_text(buf, "\r\n")


def add_request(
    mut buf: List[UInt8], mut response: Response, args: Args, style: Style
) raises:
    """The request that went out, in wire form.

    The version comes off the response, because it is the exchange that decides
    whether this was HTTP/1.1 or HTTP/2 and the request does not know until it
    has been sent. An HTTP/2 exchange is shown in this shape too, with its
    pseudo-headers written out as an ordinary request line, which is what every
    other tool does and is the only form most people can read. That shape shows
    the hop-by-hop headers an HTTP/2 connection does not actually carry, which
    is the one place this is a rendering of the request rather than a copy of
    the bytes.

    `Host` is not in the request's own headers, because it is written from the
    URL as the message goes out. It is put back here from the same function the
    writer uses, so that what is printed is what was sent rather than what was
    left in the struct.
    """
    if not response.has_request():
        return
    ref request = response.request()
    if args.shows_request_headers():
        var line = String(
            request.method,
            " ",
            request_target(request.url, TargetForm.ORIGIN),
            " ",
            response.http_version,
        )
        add_text(buf, style.paint(BOLD, line))
        add_text(buf, "\r\n")
        if "host" not in request.headers:
            add_text(buf, style.paint(CYAN, "Host"))
            add_text(buf, ": ")
            add_text(buf, host_header_value(request.url))
            add_text(buf, "\r\n")
        _add_headers(buf, request.headers, style)
    if args.shows_request_body():
        add(buf, Span(request.content))
        add_text(buf, "\r\n")


def add_response_head(mut buf: List[UInt8], response: Response, style: Style):
    """The status line and the response headers, in wire form."""
    var line = String(
        response.http_version,
        " ",
        response.status_code,
        " ",
        response.reason_phrase,
    )
    add_text(buf, style.paint(BOLD, line))
    add_text(buf, "\r\n")
    _add_headers(buf, response.headers, style)


def is_json(response: Response) raises -> Bool:
    """Whether the body is worth trying to lay out as JSON.

    From `Content-Type`, and loose about it, so that `application/json`,
    `application/problem+json` and a server that wrote `text/json` are all
    caught. Being wrong here costs a parse that fails and a body printed as it
    arrived, which is exactly what happens to a body that is not JSON anyway.
    """
    return response.headers.get("content-type", "").lower().find("json") >= 0


def _is_space(c: UInt8) -> Bool:
    return c == _SPACE or c == _TAB or c == _NEWLINE or c == _RETURN


def _skip_space[o: ImmOrigin](source: Span[UInt8, o], start: Int) -> Int:
    var i = start
    while i < len(source) and _is_space(source[i]):
        i += 1
    return i


def _string_end[o: ImmOrigin](source: Span[UInt8, o], start: Int) -> Int:
    """One past the closing quote of the string that starts at `start`.

    A backslash escapes the next byte whatever it is, which is all this needs
    to know: the parser has already agreed the escape is one of the ten JSON
    allows, and the bytes are being copied out rather than decoded.
    """
    var i = start + 1
    while i < len(source):
        if source[i] == _BACKSLASH:
            i += 2
            continue
        if source[i] == _QUOTE:
            return i + 1
        i += 1
    return len(source)


def _atom_end[o: ImmOrigin](source: Span[UInt8, o], start: Int) -> Int:
    """One past a number, `true`, `false` or `null`.

    Ended by whatever cannot be inside one rather than by knowing which of them
    it is, since the parser has already said the whole document is valid.
    """
    var i = start
    while i < len(source):
        var c = source[i]
        if (
            _is_space(c)
            or c == _COMMA
            or c == _COLON
            or c == _RBRACE
            or c == _RBRACKET
        ):
            return i
        i += 1
    return len(source)


def _paint_bytes[
    o: ImmOrigin
](
    mut out: List[UInt8],
    style: Style,
    code: StringSpan,
    source: Span[UInt8, o],
    start: Int,
    end: Int,
):
    """Copy `source[start:end]` out, wrapped in a colour.

    The bytes are copied rather than turned into a `String` on the way, because
    a JSON string is allowed to hold anything the escape rules permit and a
    round trip through text would be a chance to change it.
    """
    if style.on:
        out.extend(String("\x1b[", code, "m").as_bytes())
    for i in range(start, end):
        out.append(source[i])
    if style.on:
        out.extend(RESET.as_bytes())


def _newline(mut out: List[UInt8], depth: Int):
    out.append(_NEWLINE)
    for _ in range(depth):
        out.extend(INDENT.as_bytes())


def format_json[
    o: ImmOrigin
](source: Span[UInt8, o], style: Style) raises -> List[UInt8]:
    """Lay a JSON body out over several lines, coloured by what each token is.

    Raises when the body is not JSON, which is the caller's signal to print
    what arrived instead. A body that says it is JSON and is not is usually an
    error page from something in the middle, and that page is the most useful
    thing this program can put on the screen at that moment. Refusing to print
    it, or printing a parse error in its place, would be hiding the answer.

    The layout is regenerated rather than adjusted, so whatever whitespace the
    server used is gone. The values are the ones that arrived: numbers keep
    their own spelling, strings keep their own escapes, and the order of an
    object is the order it was written in.
    """
    # The parser is the arbiter of whether this is JSON. The walk below then
    # trusts the structure completely, which is what lets it be this short.
    _ = parse_json(source)

    var out = List[UInt8]()
    var depth = 0
    var i = 0
    while i < len(source):
        var c = source[i]
        if _is_space(c):
            i += 1
            continue
        if c == _LBRACE or c == _LBRACKET:
            out.append(c)
            var after = _skip_space(source, i + 1)
            # An empty container stays on one line. `{}` broken over three
            # lines is the sort of thing that makes people turn a formatter off.
            if after < len(source) and (
                source[after] == _RBRACE or source[after] == _RBRACKET
            ):
                out.append(source[after])
                i = after + 1
                continue
            depth += 1
            _newline(out, depth)
            i += 1
            continue
        if c == _RBRACE or c == _RBRACKET:
            depth -= 1
            _newline(out, depth)
            out.append(c)
            i += 1
            continue
        if c == _COMMA:
            out.append(c)
            _newline(out, depth)
            i += 1
            continue
        if c == _COLON:
            add_text(out, ": ")
            i += 1
            continue
        if c == _QUOTE:
            var end = _string_end(source, i)
            var after = _skip_space(source, end)
            var is_key = after < len(source) and source[after] == _COLON
            _paint_bytes(out, style, CYAN if is_key else GREEN, source, i, end)
            i = end
            continue
        var end = _atom_end(source, i)
        var numeric = c == _MINUS or (c >= _ZERO and c <= _NINE)
        _paint_bytes(out, style, YELLOW if numeric else MAGENTA, source, i, end)
        i = end

    # One trailing newline, because this is the last thing on the screen and a
    # shell prompt that starts halfway along a line is the usual complaint
    # about tools that forget it. The raw path does not add one, since there
    # the bytes are the server's and nothing may be added to them.
    out.append(_NEWLINE)
    return out^
