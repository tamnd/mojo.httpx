"""Tests for per component percent encoding.

The interesting cases are all about the sets differing. A test that only checks
that a space becomes `%20` would pass with one table for the whole URL, which is
the implementation this module exists to avoid, so most of what follows pins a
byte that is safe in one component and not in another.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from httpx._bytes import Bytes
from httpx._exceptions import is_invalid_url, kind_of
from httpx._util.percent import (
    FORM,
    FRAGMENT,
    PATH,
    QUERY,
    UNRESERVED,
    USERINFO,
    CharSet,
    form_decode,
    form_encode,
    percent_decode,
    percent_encode,
    percent_normalize,
)


def _enc(text: StringSpan, safe: CharSet) raises -> String:
    return percent_encode(Bytes(text).as_span(), safe).to_string()


def _dec(text: StringSpan) raises -> String:
    return percent_decode(Bytes(text).as_span()).to_string()


def _norm(text: StringSpan, safe: CharSet) raises -> String:
    return percent_normalize(Bytes(text).as_span(), safe).to_string()


def test_unreserved_characters_are_never_touched() raises:
    var plain = "AZaz09-._~"
    assert_equal(_enc(plain, PATH), plain)
    assert_equal(_enc(plain, QUERY), plain)
    assert_equal(_enc(plain, USERINFO), plain)
    assert_equal(_enc(plain, FORM), plain)


def test_the_sets_actually_differ() raises:
    # If any two of these agreed, one component would be encoding by the other's
    # rules, which is the whole failure mode this module is built to prevent.
    assert_true(UInt8(ord("/")) in PATH)
    assert_false(UInt8(ord("/")) in FORM)
    assert_true(UInt8(ord("?")) in QUERY)
    assert_false(UInt8(ord("?")) in PATH)
    assert_true(UInt8(ord("=")) in QUERY)
    assert_false(UInt8(ord("=")) in FORM)
    # A colon or an at sign terminates the userinfo, so neither can be left bare
    # inside one, even though both are ordinary in a path.
    assert_true(UInt8(ord(":")) in PATH)
    assert_false(UInt8(ord(":")) in USERINFO)
    assert_false(UInt8(ord("@")) in USERINFO)


def test_a_password_containing_a_colon_cannot_move_the_host() raises:
    # `user:pa:ss@host` parsed naively splits at the wrong colon. Encoding is
    # what stops the password from being able to say where the host starts.
    assert_equal(_enc("pa:ss@word", USERINFO), "pa%3Ass%40word")


def test_a_slash_in_a_form_value_does_not_become_a_segment() raises:
    assert_equal(_enc("a/b", FORM), "a%2Fb")
    assert_equal(_enc("a/b", PATH), "a/b")


def test_query_structure_survives_but_form_data_does_not_gain_any() raises:
    # An assembled query keeps its separators. A single value must not be able
    # to introduce one, or a value can inject a parameter.
    assert_equal(_enc("a=1&b=2", QUERY), "a=1&b=2")
    assert_equal(_enc("a=1&b=2", FORM), "a%3D1%26b%3D2")


def test_fragment_allows_what_query_allows() raises:
    assert_equal(_enc("sec?tion/2", FRAGMENT), "sec?tion/2")


def test_space_is_a_plus_in_a_form_and_an_escape_everywhere_else() raises:
    assert_equal(form_encode(Bytes("a b").as_span()).to_string(), "a+b")
    assert_equal(_enc("a b", PATH), "a%20b")
    assert_equal(_enc("a b", QUERY), "a%20b")


def test_a_literal_plus_stays_distinct_from_a_space() raises:
    # If both encoded the same way, `1+1` and `1 1` would arrive identical, and
    # a search for a C++ topic would silently become a search for something else.
    assert_equal(form_encode(Bytes("1+1").as_span()).to_string(), "1%2B1")
    assert_equal(form_decode(Bytes("1%2B1").as_span()).to_string(), "1+1")
    assert_equal(form_decode(Bytes("1+1").as_span()).to_string(), "1 1")


def test_form_round_trips_every_byte() raises:
    var original = Bytes()
    for value in range(256):
        original.append(UInt8(value))
    var encoded = form_encode(original.as_span())
    var decoded = form_decode(encoded.as_span())
    assert_equal(len(decoded), 256)
    for value in range(256):
        assert_equal(Int(decoded[value]), value)


def test_encoding_uses_upper_case_hex() raises:
    # RFC 3986 section 6.2.2.1 makes the digits case insensitive, so producing
    # one spelling consistently is what lets two URLs be compared as strings.
    assert_equal(_enc("\xff", PATH), "%C3%BF")
    assert_equal(_enc(" ", PATH), "%20")


def test_decoding_accepts_either_case() raises:
    assert_equal(_dec("%2f"), "/")
    assert_equal(_dec("%2F"), "/")
    assert_equal(_dec("%c3%bf"), "\xff")


def test_encoding_does_not_try_to_guess_about_an_existing_escape() raises:
    # `percent_encode` takes a value that is not yet encoded. There is no way to
    # tell a literal percent from the start of an escape, so a filename with a
    # percent in it has to survive rather than be reinterpreted.
    assert_equal(_enc("100%", PATH), "100%25")
    assert_equal(_enc("%41", PATH), "%2541")


def test_normalizing_does_read_an_existing_escape() raises:
    # This is the difference between the two. Normalization is for a URL that is
    # already encoded, so `%41` there really is an `A`.
    assert_equal(_norm("%41", PATH), "A")
    assert_equal(_norm("100%25", PATH), "100%25")


def test_normalizing_decodes_only_the_unreserved() raises:
    # `%2F` in a path segment is a slash inside a name. Decoding it would invent
    # a segment boundary and turn one path into a different, longer one.
    assert_equal(_norm("a%2Fb", PATH), "a%2Fb")
    assert_equal(_norm("a%2Eb", PATH), "a.b")
    assert_equal(_norm("%7Euser", PATH), "~user")


def test_normalizing_upper_cases_the_digits_it_keeps() raises:
    assert_equal(_norm("a%2fb", PATH), "a%2Fb")
    assert_equal(_norm("%c3%bf", PATH), "%C3%BF")


def test_normalizing_is_idempotent() raises:
    # Everything about URL comparison rests on this. If running it twice differed
    # from running it once, `URL(String(u)) == u` would be false and every cache
    # keyed on a URL would hold two entries for one resource.
    for text in [
        "a%2Fb",
        "%41%42",
        "a b",
        "100%25",
        "%c3%bf",
        "~user/.config",
        "",
        "%7e%2F%2e",
    ]:
        var once = _norm(text, PATH)
        var twice = _norm(once, PATH)
        assert_equal(once, twice)


def test_a_truncated_escape_is_rejected() raises:
    for text in ["%", "%4", "abc%", "abc%A"]:
        with assert_raises():
            _ = _dec(text)
        with assert_raises():
            _ = _norm(text, PATH)


def test_a_non_hex_escape_is_rejected() raises:
    # Passing these through is what most implementations do, and it is how two
    # of them come to disagree about where a path segment ends.
    for text in ["%zz", "%2g", "%g2", "% 0", "%%41"]:
        with assert_raises():
            _ = _dec(text)


def test_a_malformed_escape_reports_an_invalid_url() raises:
    var raised = False
    try:
        _ = _dec("%zz")
    except e:
        raised = True
        var text = String(e)
        assert_true(is_invalid_url(e))
        # The rejected text is attacker controlled, so it has to arrive escaped.
        assert_true("%zz" in text)
    assert_true(raised)


def test_decoding_produces_bytes_rather_than_text() raises:
    # A percent escape can encode any byte, including one that is not valid
    # UTF-8. Decoding has to hand back bytes so the caller decides what to do,
    # rather than substituting a replacement character nobody notices.
    var decoded = percent_decode(Bytes("%FF").as_span())
    assert_equal(len(decoded), 1)
    assert_equal(Int(decoded[0]), 0xFF)
    with assert_raises():
        _ = decoded.to_string()


def test_an_empty_input_encodes_and_decodes_to_empty() raises:
    assert_equal(_enc("", PATH), "")
    assert_equal(_dec(""), "")
    assert_equal(_norm("", PATH), "")
