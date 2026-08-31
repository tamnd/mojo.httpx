"""Tests for the response head parser.

Two kinds of test here. The first kind feeds a well formed head and checks what
came out. The second kind feeds something malformed and checks that it was
rejected, and those are the ones that matter, because every one of them is a
shape that some server or proxy somewhere will send and that a lenient parser
would turn into a security bug.

The byte at a time test is worth more than it looks. Feeding a head one byte at
a time and expecting nothing until the last byte is what proves the parser never
half consumes, which is the property that lets it be driven by a socket rather
than by a string.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._exceptions import is_remote_protocol_error
from httpx._io.buffer import ByteBuffer
from httpx._proto.h1.head import (
    MAX_HEADERS,
    MAX_HEAD,
    MAX_LINE,
    ResponseHead,
    parse_head,
)


def _buffer(text: StringSpan) -> ByteBuffer:
    var buf = ByteBuffer()
    buf.extend(text.as_bytes())
    return buf^


def _must(var found: Optional[ResponseHead]) raises -> ResponseHead:
    """The head, or a failure that says the parser wanted more bytes.

    A head is not copyable, so it has to be taken out of the optional rather
    than read from it, and taking needs somewhere to take from.
    """
    if not found:
        raise Error("expected a complete head")
    return found.take()


def _rejected(text: StringSpan) raises -> String:
    """Parse `text`, require it to be rejected, and hand back the message."""
    var buf = _buffer(text)
    try:
        _ = parse_head(buf)
    except e:
        assert_true(is_remote_protocol_error(e))
        return String(e)
    raise Error("expected the parser to reject this head")


def test_a_plain_response_head_parses() raises:
    var buf = _buffer("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n")
    var head = _must(parse_head(buf))
    assert_equal(head.status_code, 200)
    assert_equal(head.reason_phrase, "OK")
    assert_equal(head.http_version, "HTTP/1.1")
    assert_equal(head.headers["content-length"], "3")


def test_the_head_is_consumed_and_the_body_is_left_behind() raises:
    # The parser owns the head and nothing else. A parser that consumed the
    # first byte of the body would work on every test that only checks headers.
    var buf = _buffer("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")
    _ = _must(parse_head(buf))
    assert_equal(len(buf), 5)
    assert_equal(String(StringSpan(from_utf8=buf.unread())), "hello")


def test_an_incomplete_head_parses_to_nothing_and_consumes_nothing() raises:
    var text = String("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n")
    var buf = _buffer(text)
    assert_false(Bool(parse_head(buf)))
    assert_equal(len(buf), text.byte_length())


def test_a_head_fed_one_byte_at_a_time_parses_on_the_last_byte() raises:
    var text = String("HTTP/1.1 404 Not Found\r\nX-A: 1\r\nX-B: 2\r\n\r\n")
    var bytes = text.as_bytes()
    var buf = ByteBuffer()
    for i in range(bytes.__len__() - 1):
        buf.extend(bytes[i : i + 1])
        assert_false(Bool(parse_head(buf)))
    buf.extend(bytes[bytes.__len__() - 1 :])
    var head = _must(parse_head(buf))
    assert_equal(head.status_code, 404)
    assert_equal(head.reason_phrase, "Not Found")
    assert_equal(head.headers["x-b"], "2")
    assert_equal(len(buf), 0)


def test_a_head_with_no_headers_parses() raises:
    var buf = _buffer("HTTP/1.1 204 No Content\r\n\r\n")
    var head = _must(parse_head(buf))
    assert_equal(head.status_code, 204)
    assert_equal(len(head.headers), 0)


def test_an_empty_reason_phrase_is_allowed() raises:
    # RFC 9112 section 4 makes the phrase optional, and the space before it is
    # still required. Nginx sends this shape for some proxied errors.
    var buf = _buffer("HTTP/1.1 200 \r\n\r\n")
    var head = _must(parse_head(buf))
    assert_equal(head.status_code, 200)
    assert_equal(head.reason_phrase, "")


def test_a_reason_phrase_with_spaces_is_kept_verbatim() raises:
    var buf = _buffer("HTTP/1.1 418 I am a teapot\r\n\r\n")
    var head = _must(parse_head(buf))
    assert_equal(head.reason_phrase, "I am a teapot")


def test_http_1_0_is_accepted_and_recorded() raises:
    # It decides whether the connection can be reused, so it has to survive the
    # parse rather than being normalised to 1.1.
    var buf = _buffer("HTTP/1.0 200 OK\r\n\r\n")
    var head = _must(parse_head(buf))
    assert_equal(head.http_version, "HTTP/1.0")
    assert_false(head.is_http_1_1())


def test_bare_newlines_are_accepted_as_line_terminators() raises:
    # Not because the RFC likes it, but because servers do it and a client that
    # refused would be the one that looked broken.
    var buf = _buffer("HTTP/1.1 200 OK\nContent-Length: 0\n\n")
    var head = _must(parse_head(buf))
    assert_equal(head.status_code, 200)
    assert_equal(head.headers["content-length"], "0")


def test_header_values_are_trimmed_but_their_insides_are_not() raises:
    var buf = _buffer("HTTP/1.1 200 OK\r\nX-A:   one two   \r\n\r\n")
    var head = _must(parse_head(buf))
    assert_equal(head.headers["x-a"], "one two")


def test_a_header_with_an_empty_value_is_allowed() raises:
    var buf = _buffer("HTTP/1.1 200 OK\r\nX-Empty:\r\n\r\n")
    var head = _must(parse_head(buf))
    assert_equal(head.headers["x-empty"], "")


def test_a_value_containing_a_colon_keeps_it() raises:
    # Only the first colon separates. Dates and URLs both rely on this.
    var buf = _buffer("HTTP/1.1 200 OK\r\nX-When: 10:30:00\r\n\r\n")
    var head = _must(parse_head(buf))
    assert_equal(head.headers["x-when"], "10:30:00")


def test_duplicate_headers_are_all_kept() raises:
    var buf = _buffer(
        "HTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\n"
    )
    var head = _must(parse_head(buf))
    assert_equal(len(head.headers.get_list("set-cookie")), 2)


def test_header_name_casing_is_preserved() raises:
    # Lookups are case insensitive, but what goes back out and into a log is
    # what the server wrote.
    var buf = _buffer("HTTP/1.1 200 OK\r\nX-CamelCase: v\r\n\r\n")
    var head = _must(parse_head(buf))
    assert_equal(
        String(StringSpan(from_utf8=head.headers.raw_name(0))), "X-CamelCase"
    )


def test_a_status_line_that_is_not_http_is_rejected() raises:
    # What a client gets when it speaks HTTP to something that is not a web
    # server, which is common enough that the message should say so.
    _ = _rejected("hello there\r\n\r\n")


def test_http_0_9_is_rejected() raises:
    _ = _rejected("HTTP/0.9 200 OK\r\n\r\n")


def test_http_2_in_a_status_line_is_rejected() raises:
    _ = _rejected("HTTP/2.0 200 OK\r\n\r\n")


def test_a_two_digit_status_code_is_rejected() raises:
    _ = _rejected("HTTP/1.1 20 OK\r\n\r\n")


def test_a_four_digit_status_code_is_rejected() raises:
    _ = _rejected("HTTP/1.1 2000 OK\r\n\r\n")


def test_a_status_code_with_no_class_is_rejected() raises:
    # Three digits that do not name any of the five classes RFC 9110 defines.
    # Worth its own rule because the framing decision asks whether the code is
    # under 200, so a `000` that got through would be treated as informational
    # and its body would be left on the connection for the next response to
    # find.
    _ = _rejected("HTTP/1.1 000 OK\r\n\r\n")
    _ = _rejected("HTTP/1.1 099 OK\r\n\r\n")
    _ = _rejected("HTTP/1.1 600 OK\r\n\r\n")
    _ = _rejected("HTTP/1.1 999 OK\r\n\r\n")


def test_an_unregistered_code_inside_a_real_class_is_accepted() raises:
    # Only the class has to exist. A client that refused codes it did not know
    # would break every time a server or a CDN invented one, and RFC 9110 says
    # to treat an unrecognised code as the generic member of its class.
    var buf = _buffer("HTTP/1.1 599 Something New\r\n\r\n")
    var head = _must(parse_head(buf))
    assert_equal(head.status_code, 599)


def test_a_status_code_that_is_not_a_number_is_rejected() raises:
    _ = _rejected("HTTP/1.1 2x0 OK\r\n\r\n")


def test_a_missing_status_code_is_rejected() raises:
    _ = _rejected("HTTP/1.1\r\n\r\n")


def test_a_folded_header_line_is_rejected() raises:
    # RFC 9112 section 5.2. A continuation line lets a value contain what looks
    # to another parser like a separate header.
    _ = _rejected("HTTP/1.1 200 OK\r\nX-A: one\r\n  two\r\n\r\n")


def test_a_tab_folded_header_line_is_rejected() raises:
    _ = _rejected("HTTP/1.1 200 OK\r\nX-A: one\r\n\ttwo\r\n\r\n")


def test_whitespace_before_the_colon_is_rejected() raises:
    # The desync primitive. A proxy that trims and a client that does not are
    # two parsers that disagree about whether a `Content-Length` was sent.
    _ = _rejected("HTTP/1.1 200 OK\r\nContent-Length : 3\r\n\r\n")


def test_a_header_line_with_no_colon_is_rejected() raises:
    _ = _rejected("HTTP/1.1 200 OK\r\nNonsense\r\n\r\n")


def test_a_header_line_with_no_name_is_rejected() raises:
    _ = _rejected("HTTP/1.1 200 OK\r\n: value\r\n\r\n")


def test_a_header_name_that_is_not_a_token_is_rejected() raises:
    _ = _rejected("HTTP/1.1 200 OK\r\nX A: value\r\n\r\n")


def test_a_bare_carriage_return_inside_a_header_is_rejected() raises:
    # Accepting it means two parsers can disagree about where the line ended,
    # which is the same class of bug as accepting a fold.
    _ = _rejected("HTTP/1.1 200 OK\r\nX-A: one\rtwo\r\n\r\n")


def test_a_bare_carriage_return_inside_the_status_line_is_rejected() raises:
    _ = _rejected("HTTP/1.1 200 O\rK\r\n\r\n")


def test_too_many_headers_are_rejected() raises:
    var text = String("HTTP/1.1 200 OK\r\n")
    for i in range(MAX_HEADERS + 1):
        text += String("X-", i, ": v\r\n")
    text += "\r\n"
    _ = _rejected(text)


def test_exactly_the_header_limit_is_allowed() raises:
    # The limit is a limit, not a fencepost. Rejecting at ninety nine would be a
    # bug that only shows up on one unlucky server.
    var text = String("HTTP/1.1 200 OK\r\n")
    for i in range(MAX_HEADERS):
        text += String("X-", i, ": v\r\n")
    text += "\r\n"
    var buf = _buffer(text)
    var head = _must(parse_head(buf))
    assert_equal(len(head.headers), MAX_HEADERS)


def test_an_over_long_header_line_is_rejected() raises:
    var text = String("HTTP/1.1 200 OK\r\nX-Big: ")
    for _ in range(MAX_LINE):
        text += "a"
    text += "\r\n\r\n"
    _ = _rejected(text)


def test_an_over_long_line_is_rejected_before_it_is_terminated() raises:
    # The point of the limit is to bound memory, so it has to fire on the bytes
    # as they arrive rather than once a complete line is in hand. A server that
    # never sends a newline is exactly the case that matters.
    var text = String("HTTP/1.1 200 OK\r\nX-Big: ")
    for _ in range(MAX_LINE + 1):
        text += "a"
    var buf = _buffer(text)
    var raised = False
    try:
        _ = parse_head(buf)
    except e:
        raised = True
        assert_true(is_remote_protocol_error(e))
    assert_true(raised)


def test_an_over_long_head_is_rejected() raises:
    var text = String("HTTP/1.1 200 OK\r\n")
    var line = String("X-Padding: ")
    for _ in range(200):
        line += "a"
    line += "\r\n"
    while text.byte_length() <= MAX_HEAD:
        text += line
    text += "\r\n"
    _ = _rejected(text)


def test_a_rejected_head_says_the_server_did_it() raises:
    # The kind is what a caller reacts to, and the two protocol errors need
    # different reactions, so this checks the kind rather than the words.
    var message = _rejected("HTTP/1.1 200 OK\r\nX-A: one\r\n  two\r\n\r\n")
    assert_true(message.byte_length() > 0)
