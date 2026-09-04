"""Tests for decoding a body given a charset label.

Every expected value in here was measured against httpx2 2.12.0 rather than
worked out from the specification, because the specification leaves room and
Python's codecs pick one answer. Parity is what these check, so where the two
could differ the number that goes in the assertion is the one Python produced.

The exception is `utf-16` with no byte order mark, which is a deliberate
difference and has its own test saying so. It is written up in
docs/deviations.md.

The replacement tests are the ones worth reading. One U+FFFD per maximal subpart
means a broken sequence swallows the longest prefix that was still on its way to
being valid, so the count of replacement characters is a real assertion about
where the decoder stopped rather than a formality.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._util.charset import (
    ASCII,
    LATIN_1,
    UNKNOWN,
    UTF_8,
    UTF_16,
    WINDOWS_1252,
    DefaultEncoding,
    charset_id,
    decode_charset,
    is_known_charset,
    normalize_label,
)


def bytes_of(*values: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for value in values:
        out.append(UInt8(value))
    return out^


def decoded(raw: List[UInt8], label: StringSpan) -> String:
    return decode_charset(Span(raw), label)


def as_utf8(text: StringSpan, label: StringSpan) -> String:
    return decode_charset(text.as_bytes(), label)


def test_ascii_decodes_as_itself() raises:
    assert_equal(as_utf8("hello", "utf-8"), "hello")


def test_utf8_decodes_multibyte_characters() raises:
    assert_equal(as_utf8("héllo wörld", "utf-8"), "héllo wörld")
    assert_equal(as_utf8("日本語", "utf-8"), "日本語")


def test_an_empty_body_decodes_to_an_empty_string() raises:
    assert_equal(decoded(List[UInt8](), "utf-8"), "")
    assert_equal(decoded(List[UInt8](), "utf-16"), "")
    assert_equal(decoded(List[UInt8](), "latin-1"), "")


def test_a_byte_order_mark_on_utf8_is_kept() raises:
    # Not stripped, which is what httpx2 gives back, because Python's `utf-8`
    # codec is not `utf-8-sig`. A caller who does not want it can strip it, and a
    # caller who needs to know it was there could not get that back if we had.
    var raw = bytes_of(0xEF, 0xBB, 0xBF, 0x68, 0x69)
    assert_equal(decoded(raw, "utf-8"), "\uFEFFhi")


def test_one_bad_byte_becomes_one_replacement() raises:
    var raw = bytes_of(0x61, 0xFF, 0x62)
    assert_equal(decoded(raw, "utf-8"), "a\uFFFDb")


def test_a_truncated_sequence_is_one_replacement() raises:
    # `F0 9F 98` is the first three bytes of a four byte character. All three
    # were still on their way to being valid, so they are one maximal subpart and
    # therefore one replacement rather than three.
    var raw = bytes_of(0xF0, 0x9F, 0x98)
    assert_equal(decoded(raw, "utf-8"), "\uFFFD")


def test_a_sequence_broken_partway_is_two_replacements() raises:
    # `E1 80` was on its way to a three byte character until `E2` arrived, so the
    # first subpart is two bytes long. Then `E2` fails on `41`, which is one byte,
    # and `41 62` decode normally. This is the case that separates a decoder
    # following the maximal subpart rule from one that replaces byte by byte.
    var raw = bytes_of(0xE1, 0x80, 0xE2, 0x41, 0x62)
    assert_equal(decoded(raw, "utf-8"), "\uFFFD\uFFFDAb")


def test_a_surrogate_encoded_as_utf8_is_three_replacements() raises:
    # `ED A0 80` is U+D800 written in the UTF-8 pattern, which is not valid UTF-8
    # because surrogates are not characters. `ED` only accepts a second byte up
    # to 0x9F, so nothing here forms a subpart longer than one byte.
    var raw = bytes_of(0xED, 0xA0, 0x80)
    assert_equal(decoded(raw, "utf-8"), "\uFFFD\uFFFD\uFFFD")


def test_an_overlong_encoding_is_two_replacements() raises:
    # `C0 AF` is a slash written in two bytes instead of one. Accepting it is the
    # classic path traversal bug, so it has to be rejected rather than decoded,
    # and `C0` is not a legal lead byte at all so each byte fails on its own.
    var raw = bytes_of(0xC0, 0xAF)
    assert_equal(decoded(raw, "utf-8"), "\uFFFD\uFFFD")


def test_a_lone_continuation_byte_is_one_replacement() raises:
    assert_equal(decoded(bytes_of(0x80), "utf-8"), "\uFFFD")


def test_decoding_never_raises_on_bad_bytes() raises:
    # The property behind all of the above. A body that does not decode still
    # deserves to be shown, and a client that threw here would turn a mislabelled
    # response into a request the caller cannot inspect at all.
    var raw = bytes_of(0xFF, 0xFE, 0xC0, 0x80, 0xED, 0xA0, 0x80, 0x41)
    assert_true(decoded(raw, "utf-8").byte_length() > 0)


def test_latin1_reads_every_byte_as_a_character() raises:
    # No byte is invalid in Latin-1, which is why it is the encoding of last
    # resort for anything that has to be read at all costs.
    var raw = bytes_of(0x63, 0x61, 0x66, 0xE9)
    assert_equal(decoded(raw, "latin-1"), "café")
    assert_equal(decoded(raw, "iso-8859-1"), "café")


def test_windows1252_differs_from_latin1_in_one_range() raises:
    # Byte 0x80 is a euro sign in Windows-1252 and a C1 control character in
    # Latin-1. A page labelled one and encoded as the other shows the wrong
    # punctuation rather than failing, which is why the two are easy to confuse.
    assert_equal(decoded(bytes_of(0x80), "windows-1252"), "€")
    assert_equal(decoded(bytes_of(0x93, 0x94), "cp1252"), "“”")


def test_the_undefined_windows1252_bytes_are_replaced() raises:
    # 0x81, 0x8D, 0x8F, 0x90 and 0x9D have no character. Python's codec replaces
    # them under `errors="replace"` and so does this.
    assert_equal(decoded(bytes_of(0x80, 0x81), "windows-1252"), "€\uFFFD")
    assert_equal(
        decoded(bytes_of(0x8D, 0x8F, 0x90, 0x9D), "cp1252"),
        "\uFFFD\uFFFD\uFFFD\uFFFD",
    )


def test_a_high_byte_is_not_ascii() raises:
    var raw = bytes_of(0x61, 0xE9)
    assert_equal(decoded(raw, "us-ascii"), "a\uFFFD")
    assert_equal(decoded(raw, "ascii"), "a\uFFFD")


def test_utf16_little_endian() raises:
    var raw = bytes_of(0x68, 0x00, 0x69, 0x00)
    assert_equal(decoded(raw, "utf-16le"), "hi")


def test_utf16_big_endian() raises:
    var raw = bytes_of(0x00, 0x68, 0x00, 0x69)
    assert_equal(decoded(raw, "utf-16be"), "hi")


def test_utf16_takes_its_byte_order_from_the_mark() raises:
    # The mark is consumed rather than decoded, so four bytes are one character.
    var le = bytes_of(0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00)
    assert_equal(decoded(le, "utf-16"), "hi")

    var be = bytes_of(0xFE, 0xFF, 0x00, 0x68, 0x00, 0x69)
    assert_equal(decoded(be, "utf-16"), "hi")


def test_utf16_without_a_mark_is_read_little_endian() raises:
    # The one deliberate difference from httpx2, which raises here because
    # Python's `utf-16` codec refuses an unmarked stream and `errors="replace"`
    # does not cover that check. Little endian is what browsers assume and what
    # nearly all unmarked UTF-16 on the web is. See docs/deviations.md.
    assert_equal(decoded(bytes_of(0x68, 0x00, 0x69, 0x00), "utf-16"), "hi")


def test_a_utf16_surrogate_pair_becomes_one_character() raises:
    # U+1F600 is outside the basic plane, so UTF-16 spells it as two units that
    # have to be recombined. Decoding them separately would give two replacement
    # characters for a character that was perfectly well encoded.
    var raw = bytes_of(0x3D, 0xD8, 0x00, 0xDE)
    assert_equal(decoded(raw, "utf-16le"), "😀")


def test_an_unpaired_surrogate_is_one_replacement() raises:
    var raw = bytes_of(0x3D, 0xD8, 0x68, 0x00)
    assert_equal(decoded(raw, "utf-16le"), "\uFFFDh")


def test_an_odd_trailing_byte_in_utf16_is_replaced() raises:
    # A stream that was cut mid character, which is a real thing on a connection
    # that dropped. Replacing it says so, and discarding it would not.
    var raw = bytes_of(0x68, 0x00, 0x69)
    assert_equal(decoded(raw, "utf-16le"), "h\uFFFD")


def test_utf32_little_endian() raises:
    var raw = bytes_of(0x68, 0x00, 0x00, 0x00, 0x69, 0x00, 0x00, 0x00)
    assert_equal(decoded(raw, "utf-32le"), "hi")


def test_utf32_big_endian() raises:
    var raw = bytes_of(0x00, 0x00, 0x00, 0x68, 0x00, 0x00, 0x00, 0x69)
    assert_equal(decoded(raw, "utf-32be"), "hi")


def test_utf32_takes_its_byte_order_from_the_mark() raises:
    # The little endian mark has to be checked before the UTF-16 one, because
    # `FF FE 00 00` starts with the UTF-16 little endian mark. A decoder that
    # looked at two bytes would read this as UTF-16 and put a nul between every
    # character.
    var le = bytes_of(0xFF, 0xFE, 0x00, 0x00, 0x68, 0x00, 0x00, 0x00)
    assert_equal(decoded(le, "utf-32"), "h")

    var be = bytes_of(0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0x00, 0x68)
    assert_equal(decoded(be, "utf-32"), "h")


def test_a_utf32_value_past_the_last_code_point_is_replaced() raises:
    var raw = bytes_of(0x00, 0x00, 0x11, 0x00)
    assert_equal(decoded(raw, "utf-32le"), "\uFFFD")


def test_labels_are_matched_on_letters_and_digits_only() raises:
    # Python's codec lookup is this loose, so a server sending any of these gets
    # the encoding it meant out of httpx2. Matching the same way gets all of the
    # spellings without keeping a list of them.
    assert_equal(normalize_label("UTF-8"), "utf8")
    assert_equal(normalize_label("utf_8"), "utf8")
    assert_equal(normalize_label("'utf-8'"), "utf8")
    assert_equal(normalize_label("  UTF 8  "), "utf8")


def test_every_spelling_of_utf8_is_utf8() raises:
    assert_equal(charset_id("utf-8"), UTF_8)
    assert_equal(charset_id("UTF-8"), UTF_8)
    assert_equal(charset_id("Utf-8"), UTF_8)
    assert_equal(charset_id("utf8"), UTF_8)
    assert_equal(charset_id("'utf-8'"), UTF_8)
    assert_equal(charset_id("U8"), UTF_8)
    assert_equal(charset_id("cp65001"), UTF_8)


def test_the_other_labels_map_to_their_decoders() raises:
    assert_equal(charset_id("iso-8859-1"), LATIN_1)
    assert_equal(charset_id("latin1"), LATIN_1)
    assert_equal(charset_id("cp819"), LATIN_1)
    assert_equal(charset_id("windows-1252"), WINDOWS_1252)
    assert_equal(charset_id("us-ascii"), ASCII)
    assert_equal(charset_id("utf-16"), UTF_16)


def test_an_encoding_this_does_not_implement_is_unknown() raises:
    # Not an error. An unknown label falls back to `default_encoding` the same
    # way a missing one does, so a `Shift_JIS` body is read as UTF-8 here and as
    # Shift-JIS by httpx2. That is written up in docs/deviations.md.
    assert_equal(charset_id("shift_jis"), UNKNOWN)
    assert_equal(charset_id("euc-jp"), UNKNOWN)
    assert_equal(charset_id("gb2312"), UNKNOWN)
    assert_equal(charset_id("nonsense"), UNKNOWN)
    assert_equal(charset_id(""), UNKNOWN)
    assert_false(is_known_charset("shift_jis"))
    assert_true(is_known_charset("utf-8"))


def test_an_unknown_label_still_decodes_rather_than_failing() raises:
    # `decode_charset` is past the point where anybody decides what an unknown
    # label means. By the time bytes reach it, something has already chosen this
    # encoding, so reading them as UTF-8 is better than handing back nothing.
    assert_equal(as_utf8("hello", "shift_jis"), "hello")


def test_default_encoding_is_utf8() raises:
    var default = DefaultEncoding()
    assert_equal(default.name, "utf-8")
    assert_equal(default.resolve(List[UInt8]()), "utf-8")


def test_default_encoding_can_be_a_fixed_name() raises:
    var default = DefaultEncoding("iso-8859-1")
    assert_equal(default.resolve(List[UInt8]()), "iso-8859-1")


def always_windows(content: List[UInt8]) raises -> String:
    return String("windows-1252")


def test_default_encoding_can_be_a_detector() raises:
    # The shape httpx2 takes when `default_encoding` is given a callable, which
    # is how `charset_normalizer` gets plugged in there. Nothing here implements
    # one, because statistical detection is a corpus rather than a function, but
    # a caller who has one can use it.
    var default = DefaultEncoding(always_windows)
    assert_equal(default.resolve(bytes_of(0x80)), "windows-1252")


def test_a_detector_survives_a_copy() raises:
    # The client holds one of these and hands a copy to every response it makes,
    # so a copy that dropped the hook would leave the caller's detector working
    # on the first response and silently not on the rest.
    var default = DefaultEncoding(always_windows)
    var again = default.copy()
    assert_equal(again.resolve(List[UInt8]()), "windows-1252")


def test_a_default_encoding_holds_a_name_or_a_detector_and_not_both() raises:
    # The pair stands in for a union type Mojo does not have, so the invariant
    # worth pinning is that no constructor leaves both set.
    var named = DefaultEncoding("iso-8859-1")
    assert_false(Bool(named.detect))
    assert_equal(named.name, "iso-8859-1")
    var detecting = DefaultEncoding(always_windows)
    assert_true(Bool(detecting.detect))
    assert_equal(detecting.name, "utf-8")
