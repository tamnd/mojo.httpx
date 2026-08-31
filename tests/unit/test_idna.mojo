"""Tests for punycode and hostname encoding.

The encode vectors are the ones from RFC 3492 section 7.1, which is the only
corpus that pins the bias adaptation. Getting `_adapt` slightly wrong still
produces plausible looking output for short labels and diverges on longer ones,
so the Arabic and Chinese samples matter more than the short ones do.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from httpx._exceptions import is_invalid_url
from httpx._util.idna import (
    MAX_LABEL,
    MAX_NAME,
    decode_host,
    encode_host,
    punycode_decode,
    punycode_encode,
)


def test_rfc3492_vectors_round_trip() raises:
    # Section 7.1. Each is a sentence in the named script, which is what makes
    # them long enough to exercise the bias adaptation.
    var cases = [
        ("ليهمابتكلموشعربي؟", "egbpdaj6bu4bxfgehfvwxn"),
        ("他们为什么不说中文", "ihqwcrb4cv8a8dqg056pqjye"),
        ("他們爲什麽不說中文", "ihqwctvzc91f659drss3x8bo0yb"),
        ("Pročprostěnemluvíčesky", "Proprostnemluvesky-uyb24dma41a"),
        ("3年B組金八先生", "3B-ww4c5e180e575a65lsy2b"),
        ("MajiでKoiする5秒前", "MajiKoi5-783gue6qz075azm5e"),
        ("そのスピードで", "d9juau41awczczp"),
        # Case (T), all ASCII with spaces and punctuation. The doubled hyphen at
        # the end is the delimiter following a label that already ends in one.
        ("-> $1.00 <-", "-> $1.00 <--"),
    ]
    for sample in cases:
        var encoded = punycode_encode(sample[0])
        assert_equal(encoded, sample[1])
        assert_equal(punycode_decode(encoded), sample[0])


def test_a_pure_ascii_label_encodes_to_itself_and_a_hyphen() raises:
    # The trailing hyphen is the delimiter with nothing after it. Dropping it
    # would make the label decode as if the whole thing were digits.
    assert_equal(punycode_encode("abc"), "abc-")
    assert_equal(punycode_decode("abc-"), "abc")


def test_an_empty_label_round_trips() raises:
    assert_equal(punycode_encode(""), "")
    assert_equal(punycode_decode(""), "")


def test_a_label_with_no_ascii_has_no_delimiter() raises:
    assert_equal(
        punycode_decode(
            punycode_encode("ドメイン"),
        ),
        "ドメイン",
    )
    assert_false("-" in punycode_encode("ドメイン"))


def test_a_hyphen_inside_a_label_survives() raises:
    # Only the last hyphen is the delimiter, which is what lets a label keep its
    # own hyphens.
    assert_equal(punycode_decode(punycode_encode("a-b-ドメイン")), "a-b-ドメイン")


def test_an_ascii_hostname_is_only_lowercased() raises:
    assert_equal(encode_host("Example.COM"), "example.com")
    assert_equal(encode_host("sub.example.com"), "sub.example.com")
    assert_equal(
        encode_host("xn--eckwd4c7c.xn--zckzah"), "xn--eckwd4c7c.xn--zckzah"
    )


def test_a_unicode_hostname_becomes_a_labels() raises:
    # This is the pair the whole module exists for. The first is what a person
    # typed and the second is what goes in the Host header and into DNS.
    assert_equal(encode_host("ドメイン.テスト"), "xn--eckwd4c7c.xn--zckzah")
    assert_equal(decode_host("xn--eckwd4c7c.xn--zckzah"), "ドメイン.テスト")


def test_encoding_and_decoding_a_host_are_inverses() raises:
    for host in [
        "example.com",
        "ドメイン.テスト",
        "münchen.de",
        "日本語.jp",
        "mixed.日本語.example.com",
    ]:
        assert_equal(decode_host(encode_host(host)), host)


def test_a_label_that_is_not_punycode_is_left_alone_when_decoding() raises:
    assert_equal(decode_host("example.com"), "example.com")
    # Too short to carry a payload, so it is a name that happens to start that
    # way rather than an encoded label.
    assert_equal(decode_host("xn--"), "xn--")


def test_characters_that_cannot_appear_in_a_hostname_are_rejected() raises:
    # Each of these either terminates the host in a URL or is a header
    # separator, so letting one through puts it somewhere it changes meaning.
    for host in [
        "exa mple.com",
        "example.com/path",
        "user@example.com",
        "example.com:80",
        "exa\rmple.com",
        "exa\nmple.com",
        "example_com",
    ]:
        with assert_raises():
            _ = encode_host(host)


def test_a_rejected_hostname_reports_an_invalid_url() raises:
    var raised = False
    try:
        _ = encode_host("exa mple.com")
    except e:
        raised = True
        assert_true(is_invalid_url(e))
    assert_true(raised)


def test_a_label_over_the_dns_limit_is_rejected() raises:
    var long = String()
    for _ in range(MAX_LABEL + 1):
        long += "a"
    with assert_raises():
        _ = encode_host(String(long, ".com"))
    # One byte shorter is the longest legal label and has to be accepted, or the
    # check is off by one in the direction that breaks working names.
    var legal = long[byte=0:MAX_LABEL]
    assert_equal(
        encode_host(String(legal, ".com")).byte_length(), MAX_LABEL + 4
    )


def test_a_name_over_the_dns_limit_is_rejected() raises:
    var label = String()
    for _ in range(63):
        label += "a"
    # Four of these plus separators is 255 bytes, which is over the limit.
    var host = String(label, ".", label, ".", label, ".", label)
    assert_true(host.byte_length() > MAX_NAME)
    with assert_raises():
        _ = encode_host(host)


def test_a_trailing_dot_does_not_count_against_the_limit() raises:
    # The root label is explicit rather than extra, so a name that fits without
    # it still fits with it.
    var label = String()
    for _ in range(63):
        label += "b"
    var host = String(label, ".", label, ".", label, ".", "example.com")
    assert_true(host.byte_length() <= MAX_NAME)
    assert_equal(encode_host(String(host, ".")), String(host, "."))


def test_a_corrupt_punycode_label_is_rejected_rather_than_guessed_at() raises:
    for encoded in ["!", "a!b", "abc-!"]:
        with assert_raises():
            _ = punycode_decode(encoded)


def test_a_label_built_to_overflow_is_rejected() raises:
    # The algorithm accumulates a value that is unbounded in principle inside a
    # fixed width integer. Without the checks this decodes to some other name
    # entirely rather than failing.
    var overflowing = String()
    for _ in range(64):
        overflowing += "9"
    with assert_raises():
        _ = punycode_decode(String("a-", overflowing))


def test_an_empty_host_stays_empty() raises:
    assert_equal(encode_host(""), "")
    assert_equal(decode_host(""), "")


def test_a_name_is_mapped_before_it_is_encoded() raises:
    # UTS-46 step one. Every one of these is a different way of writing the same
    # name, and a client that did not map them would open a different connection
    # for each and check a different certificate name against each.
    assert_equal(encode_host("EXAMPLE.COM"), "example.com")
    # Fullwidth letters and an ideographic full stop.
    assert_equal(encode_host("ＥＸＡＭＰＬＥ。ＣＯＭ"), "example.com")
    # A soft hyphen, which UTS-46 removes rather than rejects.
    assert_equal(encode_host("exam­ple.com"), "example.com")


def test_a_name_is_normalized_before_it_is_encoded() raises:
    # UTS-46 step two. The precomposed letter and the letter plus the combining
    # acute look identical and have to reach one host.
    assert_equal(encode_host("münchen.de"), encode_host("münchen.de"))
    assert_equal(encode_host("münchen.de"), "xn--mnchen-3ya.de")


def test_std3_rules_keep_a_hostname_to_letters_digits_and_hyphens() raises:
    # Unicode 17 stopped marking these disallowed in the mapping table and left
    # it to the implementation, so this is the test that the rules are still
    # being applied. A parenthesis or a space in a Host header is not something
    # to find out about at the socket.
    for host in ["a b.com", "a_b.com", "a%b.com", "a(b).com", "⑷.four"]:
        with assert_raises():
            _ = encode_host(host)


def test_a_label_that_starts_with_a_combining_mark_is_rejected() raises:
    # UTS-46 validity criterion five. A mark with nothing to attach to renders
    # unpredictably, which is exactly what a name meant to be misread wants.
    with assert_raises():
        _ = encode_host("́abc.com")


def test_a_zero_width_joiner_needs_a_virama_in_front_of_it() raises:
    # RFC 5892 appendix A.2. The joiner is invisible, so a name may only contain
    # one where it changes how the letters render, which means after a virama.
    assert_equal(encode_host("क्‍ष.com"), "xn--11b2ezcw70k.com")
    with assert_raises():
        _ = encode_host("a‍b.com")


def test_a_right_to_left_name_has_to_pass_the_bidi_rule() raises:
    # RFC 5893. A name with any right to left character in it is a bidi domain,
    # and then every label in it has to obey the rule, including the ASCII ones.
    assert_equal(encode_host("مثال.إختبار"), "xn--mgbh0fb.xn--kgbechtv")
    # A bidi label may not start with a digit, because the display order of what
    # follows then depends on the surrounding text rather than on the name.
    with assert_raises():
        _ = encode_host("1א.com")


def test_an_empty_label_is_only_allowed_as_the_trailing_root() raises:
    assert_equal(encode_host("example.com."), "example.com.")
    for host in ["example..com", ".example.com", "..", "."]:
        with assert_raises():
            _ = encode_host(host)


def test_a_punycode_label_has_to_be_the_spelling_punycode_produces() raises:
    # RFC 5891 section 4.4. Each of these decodes without error and encodes back
    # to something else, so accepting it would give one name two forms that no
    # longer compare equal.
    for host in ["xn--ASCII-", "xn--unicode-.org", "xn--"]:
        with assert_raises():
            _ = encode_host(host)


def test_a_punycode_label_may_not_decode_to_another_one() raises:
    # Which name it is would otherwise depend on how many times the reader
    # decoded it.
    with assert_raises():
        _ = encode_host("xn--xn---epa")


def test_a_punycode_label_that_decodes_to_a_bad_name_is_rejected() raises:
    # This one decodes to circled katakana, which the mapping table maps away, so
    # no conforming encoder would ever have written the label. Passing it through
    # would send DNS a name nothing produces.
    with assert_raises():
        _ = encode_host("a.b.c.xn--pokxncvks")
