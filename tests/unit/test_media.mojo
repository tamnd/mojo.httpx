"""Tests for the `Content-Type` parser.

Most of these are about the two things that make this more than a split on
semicolons: a quoted value can hold a separator, and a backslash inside quotes
escapes what follows. A parser that gets either wrong truncates a filename or a
multipart boundary at the first punctuation mark somebody puts in it, and that is
a bug an attacker chooses the inputs for.

The rest check that nothing raises. A `Content-Type` arrives from the network,
and a malformed one has to come back as an empty media type or a missing
parameter rather than as a failure to read the body.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._util.media import MediaType, parse_media_type


def parsed(value: StringSpan) -> MediaType:
    return parse_media_type(value.as_bytes())


def param(value: StringSpan, name: StringSpan) raises -> String:
    var found = parsed(value).param(name)
    if not found:
        return String("<missing>")
    return found.value()


def test_a_bare_media_type_has_no_parameters() raises:
    var media = parsed("text/html")
    assert_equal(media.mime, "text/html")
    assert_equal(len(media.names), 0)


def test_the_media_type_is_lowercased() raises:
    # Media types are case insensitive, and a caller comparing against a literal
    # should not have to know that the server wrote it in title case.
    assert_equal(parsed("Text/HTML").mime, "text/html")
    assert_equal(parsed("APPLICATION/JSON").mime, "application/json")


def test_surrounding_space_is_dropped() raises:
    assert_equal(parsed("  text/html  ").mime, "text/html")
    assert_equal(parsed("  text/html ; charset=utf-8 ").mime, "text/html")


def test_a_parameter_is_read() raises:
    assert_equal(param("text/html; charset=utf-8", "charset"), "utf-8")


def test_space_around_a_parameter_is_dropped() raises:
    assert_equal(param("text/html ;  charset = utf-8 ", "charset"), "utf-8")


def test_a_parameter_name_is_lowercased() raises:
    assert_equal(param("text/html; CharSet=utf-8", "charset"), "utf-8")


def test_a_parameter_value_keeps_its_case() raises:
    # The opposite of the name. A multipart boundary and a filename are both case
    # sensitive, and lowercasing either one corrupts it.
    assert_equal(param("multipart/form-data; boundary=AbC", "boundary"), "AbC")


def test_a_quoted_value_loses_its_quotes() raises:
    assert_equal(param('text/html; charset="utf-8"', "charset"), "utf-8")


def test_a_quoted_value_may_hold_a_semicolon() raises:
    # The whole reason this is not a split. A filename with a semicolon in it is
    # one parameter, and a parser that split first would take everything after
    # the semicolon as a second parameter nobody wrote.
    var media = parsed('form-data; name="f"; filename="a;b.txt"')
    assert_equal(media.param("filename").value(), "a;b.txt")
    assert_equal(media.param("name").value(), "f")


def test_a_backslash_in_a_quoted_value_escapes_the_next_character() raises:
    assert_equal(
        param('form-data; filename="a\\"b.txt"', "filename"), 'a"b.txt'
    )
    assert_equal(
        param('form-data; filename="a\\\\b.txt"', "filename"), "a\\b.txt"
    )


def test_a_quoted_value_may_hold_an_equals() raises:
    assert_equal(param('form-data; filename="a=b.txt"', "filename"), "a=b.txt")


def test_an_unterminated_quote_takes_the_rest() raises:
    # Malformed, and it still has to come back as something. Taking the rest of
    # the header is the reading that loses the least, and the alternative of
    # dropping the parameter would hide a filename the server did send.
    assert_equal(param('form-data; filename="a.txt', "filename"), "a.txt")


def test_junk_after_a_closing_quote_is_skipped() raises:
    # A malformed header should not be read as holding a parameter nobody wrote,
    # so everything between the closing quote and the next semicolon goes.
    var media = parsed('text/html; charset="utf-8" nonsense; boundary=X')
    assert_equal(media.param("charset").value(), "utf-8")
    assert_equal(media.param("boundary").value(), "X")
    assert_equal(len(media.names), 2)


def test_several_parameters_are_all_kept() raises:
    var media = parsed("multipart/form-data; boundary=X; charset=utf-8")
    assert_equal(len(media.names), 2)
    assert_equal(media.param("boundary").value(), "X")
    assert_equal(media.param("charset").value(), "utf-8")


def test_the_first_of_a_repeated_parameter_wins() raises:
    # A header carrying `charset` twice is either a mistake or an attempt to make
    # two readers disagree. The first is what `email.message` gives back, which
    # is what httpx2 reads its charset through.
    assert_equal(
        param("text/html; charset=utf-8; charset=latin-1", "charset"), "utf-8"
    )


def test_a_missing_parameter_is_nothing_rather_than_empty() raises:
    assert_false(Bool(parsed("text/html").param("charset")))
    assert_false(parsed("text/html").has_param("charset"))


def test_a_parameter_with_no_value_is_not_stored() raises:
    # Nothing HTTP defines uses one, and storing it as an empty string would let
    # `param` report a charset that was never given.
    assert_false(parsed("text/html; charset").has_param("charset"))
    assert_false(parsed("text/html; charset; boundary=X").has_param("charset"))
    assert_true(parsed("text/html; charset; boundary=X").has_param("boundary"))


def test_an_empty_header_parses_to_nothing() raises:
    var media = parsed("")
    assert_equal(media.mime, "")
    assert_equal(len(media.names), 0)


def test_a_header_that_is_only_parameters_has_an_empty_mime() raises:
    var media = parsed("; charset=utf-8")
    assert_equal(media.mime, "")
    assert_equal(media.param("charset").value(), "utf-8")


def test_trailing_semicolons_are_harmless() raises:
    var media = parsed("text/html;;; charset=utf-8;;")
    assert_equal(media.mime, "text/html")
    assert_equal(len(media.names), 1)
    assert_equal(media.param("charset").value(), "utf-8")


def test_a_high_byte_in_a_value_is_read_as_latin1() raises:
    # RFC 9110 says a header field with no stated encoding is Latin-1, and a
    # server sending a Latin-1 filename is a real thing rather than a
    # hypothetical. Byte 0xE9 is e acute, which is two bytes once encoded.
    var raw = List[UInt8]()
    raw.extend('form-data; filename="caf'.as_bytes())
    raw.append(0xE9)
    raw.extend('.txt"'.as_bytes())
    var media = parse_media_type(Span(raw))
    assert_equal(media.param("filename").value(), "café.txt")


def test_matches_ignores_case() raises:
    assert_true(parsed("Text/HTML; charset=utf-8").matches("text/html"))
    assert_false(parsed("text/html").matches("text/plain"))


def test_a_content_disposition_parses_the_same_way() raises:
    # Same grammar, different header. Reusing the parser is the point: a filename
    # is quoted for exactly the reasons a boundary is.
    var media = parsed('form-data; name="upload"; filename="report q1.pdf"')
    assert_equal(media.mime, "form-data")
    assert_equal(media.param("name").value(), "upload")
    assert_equal(media.param("filename").value(), "report q1.pdf")
