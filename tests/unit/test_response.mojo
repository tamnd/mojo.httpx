"""Tests for how a response decides what encoding its body is in.

The decoder itself is covered in test_charset.mojo. What is checked here is the
decision: which of the content type, the caller's `default_encoding` and the
fallback wins, and in what order. Getting the order wrong is the kind of bug that
shows up as mojibake on one service and nowhere else.

Every expected value was measured against httpx2 2.12.0. The two places worth
knowing about are that `encoding` gives back the label the server wrote rather
than a canonical name, and that an unknown label falls back instead of failing.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._models.headers import Headers
from httpx._models.response import Response
from httpx._util.charset import DefaultEncoding


def response_with(
    content_type: StringSpan, body: List[UInt8]
) raises -> Response:
    var headers = Headers()
    if content_type.byte_length() > 0:
        headers.append("content-type", content_type)
    var r = Response(200, String("OK"), String("HTTP/1.1"), headers^)
    r.content = body.copy()
    return r^


def bytes_of(*values: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for value in values:
        out.append(UInt8(value))
    return out^


def test_the_charset_parameter_is_found() raises:
    var r = response_with("text/plain; charset=utf-8", List[UInt8]())
    assert_equal(r.charset_encoding().value(), "utf-8")
    assert_equal(r.encoding(), "utf-8")


def test_the_charset_parameter_is_lowercased() raises:
    # Charset labels are case insensitive, and a caller comparing the result
    # against a literal should not have to know how the server spelled it.
    var r = response_with("text/plain; charset=UTF-8", List[UInt8]())
    assert_equal(r.charset_encoding().value(), "utf-8")


def test_the_label_is_reported_as_written_and_not_canonicalised() raises:
    # `charset=UTF8` gives back `utf8` rather than `utf-8`. httpx2 does the same,
    # because it lowercases the parameter and hands it to Python's codec lookup
    # without normalising it first, so parity means doing that too.
    var r = response_with("text/plain; charset=UTF8", List[UInt8]())
    assert_equal(r.encoding(), "utf8")


def test_a_quoted_charset_is_read() raises:
    var r = response_with('text/plain; charset="iso-8859-1"', List[UInt8]())
    assert_equal(r.encoding(), "iso-8859-1")


def test_space_around_the_parameter_does_not_matter() raises:
    var r = response_with("text/plain ;  charset = utf-8 ", List[UInt8]())
    assert_equal(r.encoding(), "utf-8")


def test_the_first_of_two_charsets_wins() raises:
    var r = response_with(
        "text/plain; charset=utf-8; charset=iso-8859-1", List[UInt8]()
    )
    assert_equal(r.encoding(), "utf-8")


def test_no_content_type_means_no_declared_charset() raises:
    var r = response_with("", List[UInt8]())
    assert_false(Bool(r.charset_encoding()))
    assert_equal(r.encoding(), "utf-8")


def test_a_content_type_with_no_charset_declares_nothing() raises:
    var r = response_with("text/html", List[UInt8]())
    assert_false(Bool(r.charset_encoding()))
    assert_equal(r.encoding(), "utf-8")


def test_an_empty_charset_declares_nothing() raises:
    # `charset=` with nothing after it is a header a couple of real servers send,
    # and treating it as a declaration would mean trying to decode as the empty
    # encoding rather than falling back the way a missing parameter does.
    var r = response_with("text/plain; charset=", List[UInt8]())
    assert_false(Bool(r.charset_encoding()))
    assert_equal(r.encoding(), "utf-8")


def test_a_charset_this_cannot_decode_falls_back() raises:
    # `charset_encoding` still reports what the server said, because that is the
    # header and the caller may want to see it. `encoding` is where the decision
    # happens, and it falls back rather than failing.
    var r = response_with("text/plain; charset=shift_jis", List[UInt8]())
    assert_equal(r.charset_encoding().value(), "shift_jis")
    assert_equal(r.encoding(), "utf-8")


def test_default_encoding_is_used_when_nothing_is_declared() raises:
    var r = response_with("text/plain", bytes_of(0x63, 0x61, 0x66, 0xE9))
    r.default_encoding = DefaultEncoding("iso-8859-1")
    assert_equal(r.encoding(), "iso-8859-1")
    assert_equal(r.text(), "café")


def test_a_declared_charset_beats_default_encoding() raises:
    # The order that matters. `default_encoding` is what the caller knows about a
    # service that says nothing, not an override of a service that does say.
    var r = response_with("text/plain; charset=utf-8", bytes_of(0xC3, 0xA9))
    r.default_encoding = DefaultEncoding("iso-8859-1")
    assert_equal(r.encoding(), "utf-8")
    assert_equal(r.text(), "é")


def test_default_encoding_catches_an_unknown_declared_charset() raises:
    var r = response_with("text/plain; charset=shift_jis", bytes_of(0xE9))
    r.default_encoding = DefaultEncoding("latin-1")
    assert_equal(r.encoding(), "latin-1")
    assert_equal(r.text(), "é")


def always_windows(content: List[UInt8]) raises -> String:
    return String("windows-1252")


def test_a_detector_is_consulted_when_nothing_is_declared() raises:
    var r = response_with("text/plain", bytes_of(0x80))
    r.default_encoding = DefaultEncoding(always_windows)
    assert_equal(r.encoding(), "windows-1252")
    assert_equal(r.text(), "€")


def test_text_decodes_the_body_as_the_chosen_encoding() raises:
    var body = List[UInt8]()
    body.extend("héllo".as_bytes())
    var r = response_with("text/plain; charset=utf-8", body)
    assert_equal(r.text(), "héllo")


def test_text_replaces_rather_than_failing_on_bad_bytes() raises:
    # A body that lies about its encoding still has to come back as something.
    # The strict reading is available through `json`, which refuses invalid
    # UTF-8, and through `content` for anybody who wants to do it themselves.
    var r = response_with(
        "text/plain; charset=utf-8", bytes_of(0x61, 0xFF, 0x62)
    )
    assert_equal(r.text(), "a\uFFFDb")


def test_an_empty_body_is_empty_text() raises:
    var r = response_with("text/plain; charset=utf-8", List[UInt8]())
    assert_equal(r.text(), "")


def test_default_encoding_survives_a_copy() raises:
    # A response gets copied when it is stored in a redirect history, and a copy
    # that lost the encoding would read the same bytes differently from the
    # response it came from.
    var r = response_with("text/plain", bytes_of(0xE9))
    r.default_encoding = DefaultEncoding("latin-1")
    var again = r.copy()
    assert_equal(again.encoding(), "latin-1")
    assert_equal(again.text(), "é")


def test_json_ignores_the_declared_charset() raises:
    # JSON is UTF-8 by definition and the parser is strict about it. A server
    # labelling a JSON body `charset=iso-8859-1` is wrong rather than expressing
    # a preference, and reading it as Latin-1 first would corrupt every non ASCII
    # string in the document.
    var body = List[UInt8]()
    body.extend('{"s":"héllo"}'.as_bytes())
    var r = response_with("application/json; charset=iso-8859-1", body)
    assert_equal(r.json()["s"].as_string(), "héllo")


def test_the_response_still_reports_its_status() raises:
    # Cheap, and it is the one thing every other test here takes for granted.
    var r = response_with("text/plain", List[UInt8]())
    assert_equal(r.status_code, 200)
    assert_true(r.is_success())
    assert_equal(String(r), "<Response [200 OK]>")
