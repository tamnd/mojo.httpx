"""Tests for `Bytes` and the span parsing helpers.

Most of these are about strictness. The parsing functions exist because HTTP is
a byte protocol and because the places where a client is allowed to be generous
are much narrower than they look. A `Content-Length` that we accept and the next
hop rejects, or the other way round, is the disagreement request smuggling is
built on, so the tests that assert a rejection matter more than the ones that
assert a parse.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from httpx._bytes import (
    Bytes,
    ends_with,
    equal_ascii_ci,
    index_of,
    index_of_span,
    is_ows,
    parse_decimal,
    parse_hex,
    starts_with,
    to_lower,
    trim_ows,
)


def _b(text: StringSpan) -> Bytes:
    return Bytes(text)


def test_bytes_round_trips_text() raises:
    var b = _b("Hello, world")
    assert_equal(len(b), 12)
    assert_equal(b.to_string(), "Hello, world")
    assert_true(Bool(b))
    assert_equal(Int(b[0]), ord("H"))


def test_an_empty_buffer_is_falsy() raises:
    var b = Bytes()
    assert_equal(len(b), 0)
    assert_false(Bool(b))
    assert_equal(b.to_string(), "")


def test_copy_is_independent_of_the_original() raises:
    var original = _b("abc")
    var duplicate = original.copy()
    duplicate.append(UInt8(ord("d")))
    # If `copy` shared the allocation, appending to one would lengthen both,
    # and a retried request would send a body the caller never wrote.
    assert_equal(len(original), 3)
    assert_equal(len(duplicate), 4)
    assert_equal(duplicate.to_string(), "abcd")


def test_clear_keeps_the_buffer_usable() raises:
    var b = _b("first response")
    b.clear()
    assert_equal(len(b), 0)
    b.extend(_b("second response").as_span())
    assert_equal(b.to_string(), "second response")


def test_extend_appends_rather_than_replacing() raises:
    var b = _b("GET /")
    b.extend(_b(" HTTP/1.1").as_span())
    assert_equal(b.to_string(), "GET / HTTP/1.1")


def test_invalid_utf8_refuses_to_decode() raises:
    # A Latin-1 header value is a real thing a server sends. Decoding it as
    # UTF-8 has to fail loudly so the caller can reach for the bytes, rather
    # than quietly substituting replacement characters nobody notices.
    var b = Bytes([UInt8(0x48), UInt8(0xFF), UInt8(0x69)])
    assert_equal(len(b), 3)
    with assert_raises():
        _ = b.to_string()


def test_debug_output_does_not_print_the_contents() raises:
    # Bodies are large and often not text. Printing one because it appeared in
    # a log statement is never what the caller wanted.
    assert_equal(String(_b("a very long body indeed")), "Bytes(23)")


def test_to_lower_touches_only_ascii_letters() raises:
    assert_equal(Int(to_lower(UInt8(ord("A")))), ord("a"))
    assert_equal(Int(to_lower(UInt8(ord("z")))), ord("z"))
    assert_equal(Int(to_lower(UInt8(ord("-")))), ord("-"))
    assert_equal(Int(to_lower(UInt8(ord("5")))), ord("5"))
    # The high half is left alone. Flipping bit five there would corrupt a
    # UTF-8 continuation byte.
    assert_equal(Int(to_lower(UInt8(0xC3))), 0xC3)


def test_header_names_compare_without_regard_to_case() raises:
    assert_true(
        equal_ascii_ci(
            _b("Content-Type").as_span(), _b("content-type").as_span()
        )
    )
    assert_true(equal_ascii_ci(_b("ETAG").as_span(), _b("etag").as_span()))
    assert_false(
        equal_ascii_ci(
            _b("Content-Type").as_span(), _b("Content-Length").as_span()
        )
    )
    # A prefix is not a match, however tempting the length check makes it.
    assert_false(
        equal_ascii_ci(_b("Accept").as_span(), _b("Accept-Encoding").as_span())
    )


def test_index_of_reports_absence_as_minus_one() raises:
    var line = _b("Host: example.com")
    assert_equal(index_of(line.as_span(), UInt8(ord(":"))), 4)
    assert_equal(index_of(line.as_span(), UInt8(ord("?"))), -1)
    # The start offset skips the first match, which is how a parser walks a
    # comma separated header value.
    assert_equal(index_of(line.as_span(), UInt8(ord("e")), 5), 6)


def test_index_of_span_finds_the_header_terminator() raises:
    var head = _b("HTTP/1.1 200 OK\r\nServer: x\r\n\r\nbody")
    var terminator = _b("\r\n\r\n")
    assert_equal(index_of_span(head.as_span(), terminator.as_span()), 26)
    assert_equal(index_of_span(head.as_span(), _b("nowhere").as_span()), -1)


def test_an_empty_needle_matches_where_the_search_started() raises:
    # A loop over successive matches has to terminate rather than spin, and
    # this is the case that decides which it does.
    var haystack = _b("anything")
    assert_equal(index_of_span(haystack.as_span(), Bytes().as_span()), 0)
    assert_equal(index_of_span(haystack.as_span(), Bytes().as_span(), 3), 3)


def test_a_needle_longer_than_the_haystack_is_not_found() raises:
    assert_equal(index_of_span(_b("ab").as_span(), _b("abcd").as_span()), -1)
    assert_false(starts_with(_b("ab").as_span(), _b("abcd").as_span()))
    assert_false(ends_with(_b("ab").as_span(), _b("abcd").as_span()))


def test_prefix_and_suffix_checks() raises:
    var line = _b("HTTP/1.1 404 Not Found")
    assert_true(starts_with(line.as_span(), _b("HTTP/1.").as_span()))
    assert_false(starts_with(line.as_span(), _b("http/1.").as_span()))
    assert_true(ends_with(line.as_span(), _b("Not Found").as_span()))
    assert_true(ends_with(line.as_span(), Bytes().as_span()))


def test_trim_ows_removes_spaces_and_tabs() raises:
    assert_equal(
        Bytes(trim_ows(_b("  \tvalue \t ").as_span())).to_string(), "value"
    )
    assert_equal(Bytes(trim_ows(_b("value").as_span())).to_string(), "value")
    assert_equal(len(Bytes(trim_ows(_b(" \t ").as_span()))), 0)


def test_trim_ows_leaves_carriage_returns_alone() raises:
    # A bare CR or LF inside a header value is a smuggling vector, not padding.
    # Trimming it here would hide it from the validation that rejects it.
    assert_true(is_ows(UInt8(0x20)))
    assert_true(is_ows(UInt8(0x09)))
    assert_false(is_ows(UInt8(0x0D)))
    assert_false(is_ows(UInt8(0x0A)))
    assert_equal(
        Bytes(trim_ows(_b("\rvalue\n").as_span())).to_string(), "\rvalue\n"
    )


def test_content_length_parses_an_ordinary_number() raises:
    assert_equal(parse_decimal(_b("0").as_span()), 0)
    assert_equal(parse_decimal(_b("42").as_span()), 42)
    assert_equal(parse_decimal(_b("00042").as_span()), 42)
    assert_equal(
        parse_decimal(_b("9007199254740993").as_span()), 9007199254740993
    )


def test_content_length_rejects_everything_that_is_not_digits() raises:
    # Each of these is accepted by some HTTP implementation somewhere, which is
    # exactly why this one rejects them.
    for text in ["", " 42", "42 ", "+42", "-42", "0x2a", "4 2", "42\r", "4a"]:
        with assert_raises():
            _ = parse_decimal(_b(text).as_span())


def test_content_length_rejects_a_number_too_large_to_hold() raises:
    # Wrapping would produce a buffer size, and a wrapped buffer size is a
    # memory safety problem rather than a parsing one.
    with assert_raises():
        _ = parse_decimal(_b("99999999999999999999999999").as_span())


def test_chunk_size_accepts_either_case() raises:
    assert_equal(parse_hex(_b("0").as_span()), 0)
    assert_equal(parse_hex(_b("ff").as_span()), 255)
    assert_equal(parse_hex(_b("FF").as_span()), 255)
    assert_equal(parse_hex(_b("1A2b").as_span()), 0x1A2B)


def test_chunk_size_rejects_garbage() raises:
    for text in ["", "0x10", "10 ", "g", "-1", "1.0"]:
        with assert_raises():
            _ = parse_hex(_b(text).as_span())


def test_chunk_size_rejects_a_number_too_large_to_hold() raises:
    with assert_raises():
        _ = parse_hex(_b("ffffffffffffffffff").as_span())


def test_error_messages_escape_the_bytes_they_quote() raises:
    # The rejected value is attacker controlled and ends up in a log line, so
    # it must not be able to carry a newline or a terminal escape into it.
    var raised = False
    try:
        _ = parse_decimal(
            Bytes([UInt8(0x0A), UInt8(0x1B), UInt8(0xFF)]).as_span()
        )
    except e:
        raised = True
        var text = String(e)
        assert_true("\\x0a" in text)
        assert_true("\\x1b" in text)
        assert_true("\\xff" in text)
        assert_false("\n" in text)
    assert_true(raised)


def test_error_messages_are_length_limited() raises:
    # A megabyte body that fails to parse must not put a megabyte in the log.
    var long = Bytes()
    for _ in range(500):
        long.append(UInt8(ord("x")))
    var raised = False
    try:
        _ = parse_decimal(long.as_span())
    except e:
        raised = True
        assert_true(String(e).byte_length() < 200)
        assert_true("500 bytes" in String(e))
    assert_true(raised)
