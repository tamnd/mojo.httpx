"""Tests for `Headers`.

Two groups matter more than the rest. The injection cases are a security
control, not a formatting nicety, so every byte that can end a header early has
its own case. And the `Set-Cookie` cases exist because joining that field is a
bug that looks like it works: the joined string is well formed and only falls
apart when someone tries to split it again, by which point the cookie is gone.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from httpx._bytes import Bytes
from httpx._exceptions import is_invalid_header
from httpx._models.headers import (
    Headers,
    check_name,
    check_value,
    is_token_byte,
)


def _bytes(values: List[Int]) -> Bytes:
    var out = Bytes()
    for i in range(len(values)):
        out.append(UInt8(values[i]))
    return out^


def test_lookup_ignores_case() raises:
    var headers = Headers()
    headers.append("Content-Type", "application/json")
    assert_equal(headers["content-type"], "application/json")
    assert_equal(headers["CONTENT-TYPE"], "application/json")
    assert_true("Content-Type" in headers)
    assert_true("content-type" in headers)


def test_the_supplied_casing_is_what_goes_back_out() raises:
    # Lookup is case insensitive but the wire form is not rewritten. There are
    # still servers that read the casing, and rewriting it changes the request.
    var headers = Headers()
    headers.append("X-Custom-Header", "1")
    assert_equal(
        String(StringSpan(from_utf8=headers.raw_name(0))), "X-Custom-Header"
    )


def test_duplicates_are_kept_in_order() raises:
    var headers = Headers()
    headers.append("Accept", "text/html")
    headers.append("Accept", "application/json")
    assert_equal(len(headers), 2)
    var values = headers.get_list("accept")
    assert_equal(len(values), 2)
    assert_equal(values[0], "text/html")
    assert_equal(values[1], "application/json")


def test_a_repeated_field_reads_back_comma_joined() raises:
    # RFC 9110 section 5.3. Several lines and one line with commas mean the same
    # thing, so reading a repeated field as one value has to produce the latter.
    var headers = Headers()
    headers.append("Accept-Encoding", "gzip")
    headers.append("Accept-Encoding", "br")
    assert_equal(headers["accept-encoding"], "gzip, br")


def test_set_cookie_is_never_joined() raises:
    # An Expires attribute contains a comma, so a joined pair cannot be split
    # back apart and the reader loses both cookies rather than one.
    var headers = Headers()
    headers.append("Set-Cookie", "a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT")
    headers.append("Set-Cookie", "b=2; Path=/")
    with assert_raises():
        _ = headers["set-cookie"]
    var values = headers.get_list("set-cookie")
    assert_equal(len(values), 2)
    assert_equal(values[1], "b=2; Path=/")


def test_one_set_cookie_still_reads_normally() raises:
    # The refusal is about joining, not about the field, so the unambiguous case
    # has to keep working or every caller ends up on get_list anyway.
    var headers = Headers()
    headers.append("Set-Cookie", "a=1")
    assert_equal(headers["set-cookie"], "a=1")


def test_get_list_can_split_a_list_valued_field() raises:
    var headers = Headers()
    headers.append("Connection", "keep-alive, upgrade")
    headers.append("Connection", "te")
    var values = headers.get_list("connection", split_commas=True)
    assert_equal(len(values), 3)
    assert_equal(values[0], "keep-alive")
    assert_equal(values[1], "upgrade")
    assert_equal(values[2], "te")


def test_a_value_carrying_a_newline_is_rejected() raises:
    # This is request splitting. Everything after the newline would be read as a
    # new header, or as a new request entirely.
    for value in [
        "text/plain\r\nX-Injected: yes",
        "text/plain\rX-Injected: yes",
        "text/plain\nX-Injected: yes",
    ]:
        var headers = Headers()
        with assert_raises():
            headers.append("Content-Type", value)


def test_a_value_carrying_a_nul_is_rejected() raises:
    # A NUL truncates the value inside anything that later treats it as a C
    # string, so the part after it goes somewhere without being seen.
    var value = _bytes([ord("a"), 0, ord("b")])
    var headers = Headers()
    with assert_raises():
        headers.append_raw("X-Test".as_bytes(), value.as_span())


def test_a_rejected_header_reports_an_invalid_header() raises:
    var raised = False
    try:
        var headers = Headers()
        headers.append("X-Test", "a\r\nb")
    except e:
        raised = True
        assert_true(is_invalid_header(e))
    assert_true(raised)


def test_a_name_that_is_not_a_token_is_rejected() raises:
    # The name is the other half of injection defence. A colon or a space in a
    # name splits one header into two just as effectively as a newline does.
    for name in ["X Test", "X:Test", "X\r\nTest", "", "X\tTest", "héader"]:
        var headers = Headers()
        with assert_raises():
            headers.append(name, "1")


def test_every_token_punctuation_byte_is_accepted() raises:
    # RFC 9110 section 5.6.2. These read like they should be illegal and are not,
    # and a name using one is a name a real server sends.
    for name in ["X-A_B", "X.A", "X~A", "X|A", "X^A", "X`A", "X!A", "X#A"]:
        var headers = Headers()
        headers.append(name, "1")
        assert_true(name in headers)


def test_a_high_byte_in_a_value_is_allowed() raises:
    # obs-text. Deprecated but legal, and a header carrying one still has to be
    # readable rather than fatal.
    var value = _bytes([0xF1])
    var headers = Headers()
    headers.append_raw("X-Test".as_bytes(), value.as_span())
    assert_equal(len(headers), 1)


def test_a_delete_byte_in_a_value_is_rejected() raises:
    var value = _bytes([ord("a"), 0x7F])
    var headers = Headers()
    with assert_raises():
        headers.append_raw("X-Test".as_bytes(), value.as_span())


def test_surrounding_whitespace_is_not_part_of_the_value() raises:
    # Field values carry optional whitespace that is not data. Keeping it would
    # make Content-Length fail to parse on messages that are perfectly legal.
    var headers = Headers()
    headers.append("Content-Length", "  5 \t")
    assert_equal(headers["content-length"], "5")


def test_a_tab_inside_a_value_survives() raises:
    var headers = Headers()
    headers.append("X-Test", "a\tb")
    assert_equal(headers["x-test"], "a\tb")


def test_setting_replaces_every_occurrence_and_keeps_the_position() raises:
    var headers = Headers()
    headers.append("A", "1")
    headers.append("Accept", "x")
    headers.append("B", "2")
    headers.append("Accept", "y")
    headers["accept"] = "z"
    assert_equal(len(headers), 3)
    assert_equal(headers["accept"], "z")
    # The replacement went where the first occurrence was, not on the end.
    assert_equal(String(StringSpan(from_utf8=headers.raw_name(1))), "accept")


def test_setting_a_field_that_was_not_there_appends_it() raises:
    var headers = Headers()
    headers.append("A", "1")
    headers["B"] = "2"
    assert_equal(len(headers), 2)
    assert_equal(headers["b"], "2")


def test_deleting_a_missing_field_raises_but_discarding_does_not() raises:
    var headers = Headers()
    headers.append("A", "1")
    with assert_raises():
        headers.__delitem__("nope")
    assert_false(headers.discard("nope"))
    assert_true(headers.discard("a"))
    assert_equal(len(headers), 0)


def test_lookups_still_work_after_a_delete_shifts_positions() raises:
    # The index holds positions, so anything that removes an entry invalidates
    # every position after it. This is the case that catches a stale index.
    var headers = Headers()
    headers.append("A", "1")
    headers.append("B", "2")
    headers.append("C", "3")
    _ = headers.discard("a")
    assert_equal(headers["b"], "2")
    assert_equal(headers["c"], "3")
    assert_false("a" in headers)


def test_setdefault_leaves_an_existing_value_alone() raises:
    var headers = Headers()
    headers.append("User-Agent", "mine")
    headers.setdefault("User-Agent", "default")
    headers.setdefault("Accept", "*/*")
    assert_equal(headers["user-agent"], "mine")
    assert_equal(headers["accept"], "*/*")


def test_update_replaces_rather_than_appends() raises:
    # Applying the same overrides twice has to give what applying them once gave,
    # or a retried request grows a duplicate header on every attempt.
    var headers = Headers()
    headers.append("Accept", "text/html")
    headers.append("Host", "example.com")
    var overrides = Headers()
    overrides.append("Accept", "application/json")
    headers.update(overrides)
    headers.update(overrides)
    assert_equal(len(headers), 2)
    assert_equal(headers["accept"], "application/json")
    assert_equal(headers["host"], "example.com")


def test_update_keeps_the_casing_it_was_given() raises:
    # This used to go through `keys()`, which returns the lowered names, so
    # every header a caller set on a request went out lowercased. Legal, and
    # nothing else on the internet does it, which made a request from this
    # library identifiable by its shape alone.
    var headers = Headers()
    var overrides = Headers()
    overrides.append("X-Request-Id", "abc")
    overrides.append("Content-Length", "6")
    headers.update(overrides)
    assert_equal(
        String(StringSpan(from_utf8=headers.raw_name(0))), "X-Request-Id"
    )
    assert_equal(
        String(StringSpan(from_utf8=headers.raw_name(1))), "Content-Length"
    )


def test_update_keeps_a_field_that_repeats_in_the_source() raises:
    var headers = Headers()
    headers.append("Accept", "text/html")
    var overrides = Headers()
    overrides.append("Accept", "a")
    overrides.append("Accept", "b")
    headers.update(overrides)
    assert_equal(len(headers.get_list("accept")), 2)


def test_equality_ignores_order_but_counts_repetition() raises:
    var one = Headers()
    one.append("A", "1")
    one.append("B", "2")
    var two = Headers()
    two.append("B", "2")
    two.append("A", "1")
    assert_true(one == two)
    var three = Headers()
    three.append("A", "1")
    three.append("A", "1")
    three.append("B", "2")
    assert_true(one != three)


def test_equality_ignores_the_casing_of_names() raises:
    var one = Headers()
    one.append("Content-Type", "text/plain")
    var two = Headers()
    two.append("CONTENT-TYPE", "text/plain")
    assert_true(one == two)


def test_values_differing_in_case_are_different_headers() raises:
    # Names are case insensitive, values are not. `Accept: TEXT/HTML` is a
    # different request from `Accept: text/html` as far as this library is
    # concerned, because deciding otherwise means guessing which fields are
    # tokens and which are data.
    var one = Headers()
    one.append("Accept", "text/html")
    var two = Headers()
    two.append("Accept", "TEXT/HTML")
    assert_true(one != two)


def test_keys_and_items_collapse_duplicates() raises:
    var headers = Headers()
    headers.append("Accept", "a")
    headers.append("Accept", "b")
    headers.append("Host", "example.com")
    assert_equal(len(headers.keys()), 2)
    var items = headers.items()
    assert_equal(len(items), 2)
    assert_equal(items[0][0], "accept")
    assert_equal(items[0][1], "a, b")
    assert_equal(len(headers.multi_items()), 3)


def test_an_all_ascii_message_reports_ascii() raises:
    var headers = Headers()
    headers.append("Accept", "text/html")
    assert_equal(headers.encoding(), "ascii")


def test_a_valid_utf8_value_reports_utf8_and_decodes() raises:
    var value = _bytes([0xC3, 0xB1])
    var headers = Headers()
    headers.append_raw("X-Name".as_bytes(), value.as_span())
    assert_equal(headers.encoding(), "utf-8")
    assert_equal(headers["x-name"], "ñ")


def test_a_value_that_is_not_utf8_falls_back_to_latin1() raises:
    # This is the branch that must never raise. A server can send any byte it
    # likes here and reading the header still has to work.
    var value = _bytes([0xF1])
    var headers = Headers()
    headers.append_raw("X-Name".as_bytes(), value.as_span())
    assert_equal(headers.encoding(), "iso-8859-1")
    assert_equal(headers["x-name"], "ñ")


def test_a_pinned_encoding_wins_over_detection() raises:
    var value = _bytes([0xC3, 0xB1])
    var headers = Headers()
    headers.append_raw("X-Name".as_bytes(), value.as_span())
    headers.set_encoding("iso-8859-1")
    assert_equal(headers.encoding(), "iso-8859-1")
    assert_equal(headers["x-name"], "Ã±")


def test_an_encoding_nobody_supports_is_rejected() raises:
    var headers = Headers()
    with assert_raises():
        headers.set_encoding("shift_jis")


def test_the_borrowing_accessor_finds_the_first_value() raises:
    var headers = Headers()
    headers.append("Content-Length", "42")
    headers.append("Content-Length", "43")
    var found = headers.get_span("content-length")
    assert_true(Bool(found))
    assert_equal(String(StringSpan(from_utf8=found.value())), "42")
    assert_false(Bool(headers.get_span("content-type")))


def test_get_returns_the_default_only_when_the_field_is_absent() raises:
    var headers = Headers()
    headers.append("Accept", "a")
    assert_equal(headers.get("accept", "fallback"), "a")
    assert_equal(headers.get("nope", "fallback"), "fallback")
    # A repeated set-cookie is present, so it raises rather than quietly
    # reporting the default and hiding two real cookies.
    headers.append("Set-Cookie", "a=1")
    headers.append("Set-Cookie", "b=2")
    with assert_raises():
        _ = headers.get("set-cookie", "fallback")


def test_printing_headers_withholds_credentials() raises:
    # Debug output ends up in logs that outlive the session it came from.
    var headers = Headers()
    headers.append("Authorization", "Bearer supersecret")
    headers.append("Accept", "text/html")
    var text = String(headers)
    assert_false("supersecret" in text)
    assert_true("[secret" in text)
    assert_true("text/html" in text)


def test_a_copy_does_not_share_state() raises:
    var headers = Headers()
    headers.append("A", "1")
    var other = headers.copy()
    other.append("B", "2")
    assert_equal(len(headers), 1)
    assert_equal(len(other), 2)
    assert_equal(other["a"], "1")


def test_building_from_pairs_keeps_order_and_duplicates() raises:
    var headers = Headers(
        [
            ("Accept", String("a")),
            ("Host", String("example.com")),
            ("Accept", String("b")),
        ]
    )
    assert_equal(len(headers), 3)
    assert_equal(headers["accept"], "a, b")


def test_building_from_pairs_validates_the_same_way() raises:
    # A header assembled in code cannot carry something a header read from a
    # socket would have been rejected for.
    with assert_raises():
        _ = Headers([("X-Test", String("a\r\nb"))])


def test_an_empty_headers_is_falsey_and_reads_as_missing() raises:
    var headers = Headers()
    assert_false(Bool(headers))
    assert_equal(len(headers), 0)
    with assert_raises():
        _ = headers["accept"]


def test_the_token_predicate_agrees_with_the_name_check() raises:
    # The two are used from different places, so they are checked against each
    # other rather than each against my memory of the grammar.
    for code in range(0, 256):
        var byte = UInt8(code)
        var one = Bytes()
        one.append(byte)
        var accepted = True
        try:
            check_name(one.as_span())
        except:
            accepted = False
        assert_equal(accepted, is_token_byte(byte))


def test_the_value_check_accepts_exactly_what_it_should() raises:
    for code in range(0, 256):
        var byte = UInt8(code)
        var one = Bytes()
        one.append(byte)
        var accepted = True
        try:
            check_value(one.as_span())
        except:
            accepted = False
        var legal = (code >= 0x20 and code != 0x7F) or code == 0x09
        assert_equal(accepted, legal)
