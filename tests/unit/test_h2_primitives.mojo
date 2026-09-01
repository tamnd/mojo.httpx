"""Tests for the HPACK integer and string literal coding.

The three worked examples in RFC 7541 appendix C.1 are here as literals, and so
is the boundary the specification is easiest to get wrong at: the value one below
the prefix ceiling fits in the prefix, the value at the ceiling does not, and an
encoder that mixes those up produces something that decodes to a different
number.

Everything after that is about a decoder reading bytes a peer chose. An HPACK
integer has no length in the specification and an HPACK string announces its own,
so both are places where the only thing standing between a peer and an unbounded
read is a bound written here.
"""

from std.testing import assert_equal, assert_raises

from httpx._bytes import Bytes
from httpx._proto.h2.primitives import (
    MAX_INTEGER,
    decode_integer,
    decode_string,
    encode_integer,
    encode_string,
)

comptime _DIGITS = StaticString("0123456789abcdef")


def _digit(byte: UInt8) -> Int:
    if byte >= UInt8(ord("a")):
        return Int(byte - UInt8(ord("a"))) + 10
    return Int(byte - UInt8(ord("0")))


def _from_hex(text: StringSpan) -> Bytes:
    var source = text.as_bytes()
    var out = Bytes()
    for i in range(0, len(source), 2):
        out.append(UInt8(_digit(source[i]) * 16 + _digit(source[i + 1])))
    return out^


def _as_hex(data: Bytes) -> String:
    var out = String()
    for i in range(len(data)):
        var high = Int(data[i] >> 4)
        var low = Int(data[i] & 0xF)
        out += _DIGITS[byte = high : high + 1]
        out += _DIGITS[byte = low : low + 1]
    return out^


def _integer_hex(value: Int, prefix_bits: Int, flags: UInt8) raises -> String:
    var out = Bytes()
    encode_integer(value, prefix_bits, flags, out)
    return _as_hex(out)


def _integer_from(hexed: StringSpan, prefix_bits: Int) raises -> Int:
    var data = _from_hex(hexed)
    return decode_integer(data.as_span(), 0, prefix_bits).value


def test_the_rfc_7541_integer_examples() raises:
    # C.1.1, C.1.2 and C.1.3. The first fits in the prefix, the second does not,
    # and the third uses the whole octet as the prefix.
    assert_equal(_integer_hex(10, 5, 0), "0a")
    assert_equal(_integer_hex(1337, 5, 0), "1f9a0a")
    assert_equal(_integer_hex(42, 8, 0), "2a")

    assert_equal(_integer_from("0a", 5), 10)
    assert_equal(_integer_from("1f9a0a", 5), 1337)
    assert_equal(_integer_from("2a", 8), 42)


def test_the_prefix_ceiling_is_where_the_encoding_changes() raises:
    # A five bit prefix holds 0 to 30 on its own. 31 is the ceiling and has to
    # spill into a continuation octet of zero, which is the one case an encoder
    # written from the prose rather than the pseudocode gets wrong.
    assert_equal(_integer_hex(30, 5, 0), "1e")
    assert_equal(_integer_hex(31, 5, 0), "1f00")
    assert_equal(_integer_hex(32, 5, 0), "1f01")

    assert_equal(_integer_from("1e", 5), 30)
    assert_equal(_integer_from("1f00", 5), 31)
    assert_equal(_integer_from("1f01", 5), 32)


def test_the_flag_bits_sit_above_the_prefix_and_are_ignored_on_the_way_back() raises:
    # The same octet carries both, and the decoder is told the prefix width
    # rather than the pattern, so whatever is above it has to come back out of
    # the value.
    assert_equal(_integer_hex(2, 7, 0x80), "82")
    assert_equal(_integer_hex(1337, 6, 0x40), "7ffa09")

    assert_equal(_integer_from("82", 7), 2)
    assert_equal(_integer_from("7ffa09", 6), 1337)


def test_an_integer_round_trips_at_every_prefix_width() raises:
    for prefix_bits in range(1, 9):
        for value in [0, 1, 7, 126, 127, 128, 255, 256, 16383, 16384, 1000000]:
            var out = Bytes()
            encode_integer(value, prefix_bits, 0, out)
            var read = decode_integer(out.as_span(), 0, prefix_bits)
            assert_equal(read.value, value)
            assert_equal(read.after, len(out))


def test_an_integer_reports_where_reading_stopped() raises:
    # The caller reads the next field from there, so an `after` that is off by
    # one desynchronises the whole header block rather than one field.
    var data = _from_hex("1f9a0aff")
    var read = decode_integer(data.as_span(), 0, 5)
    assert_equal(read.value, 1337)
    assert_equal(read.after, 3)


def test_a_truncated_integer_is_refused() raises:
    # The prefix says a continuation follows and there is nothing there.
    with assert_raises():
        _ = _integer_from("1f", 5)
    with assert_raises():
        _ = _integer_from("1f80", 5)

    var empty = Bytes()
    with assert_raises():
        _ = decode_integer(empty.as_span(), 0, 5)


def test_an_integer_spread_over_too_many_octets_is_refused() raises:
    # Every one of these continuation octets adds nothing to the value, so a
    # decoder that only guarded against a large result would read all of them
    # and then answer 31. The guard has to be on the number of octets.
    with assert_raises():
        _ = _integer_from("1f808080808080808000", 5)


def test_an_integer_larger_than_the_ceiling_is_refused() raises:
    # The largest value HPACK can be asked to carry still goes through, so the
    # limit is not sitting on anything a working peer sends.
    var out = Bytes()
    encode_integer(MAX_INTEGER, 5, 0, out)
    assert_equal(_as_hex(out), "1fe0ffffff07")
    assert_equal(decode_integer(out.as_span(), 0, 5).value, MAX_INTEGER)

    # Five continuation octets, which is inside the octet bound, all carrying
    # magnitude. Nothing here is malformed and the result is still refused.
    with assert_raises():
        _ = _integer_from("1fffffffff7f", 5)


def test_a_bad_prefix_width_is_our_own_mistake() raises:
    var out = Bytes()
    with assert_raises():
        encode_integer(1, 0, 0, out)
    with assert_raises():
        encode_integer(1, 9, 0, out)

    var data = _from_hex("0a")
    with assert_raises():
        _ = decode_integer(data.as_span(), 0, 0)
    with assert_raises():
        _ = decode_integer(data.as_span(), 0, 9)


def _string_hex(text: StringSpan) raises -> String:
    var out = Bytes()
    encode_string(text.as_bytes(), out)
    return _as_hex(out)


def test_the_rfc_7541_string_examples() raises:
    # C.2.1 sends `custom-key` as a plain literal, C.4.1 sends the same value
    # Huffman coded. We always pick the shorter, so `custom-key` comes out
    # coded, which is why the expected bytes are the ones from C.4.
    assert_equal(_string_hex("custom-key"), "8825a849e95ba97d7f")
    assert_equal(_string_hex("www.example.com"), "8cf1e3c2e5f23a6ba0ab90f4ff")
    assert_equal(_string_hex("no-cache"), "86a8eb10649cbf")


def test_a_string_is_sent_plain_when_huffman_would_not_help() raises:
    # Bytes outside the header alphabet all have long codes, so coding them
    # makes them bigger. The high bit of the length octet is the flag, and it
    # has to be clear here.
    var out = Bytes()
    var source = Bytes()
    source.append(0x00)
    source.append(0x01)
    source.append(0x02)
    encode_string(source.as_span(), out)
    assert_equal(_as_hex(out), "03000102")


def test_an_empty_string_is_a_length_of_zero() raises:
    var out = Bytes()
    encode_string("".as_bytes(), out)
    assert_equal(_as_hex(out), "00")

    var read = decode_string(out.as_span(), 0, 16)
    assert_equal(len(read.value), 0)
    assert_equal(read.after, 1)


def test_a_string_round_trips_in_both_forms() raises:
    for text in [
        StaticString("custom-key"),
        "www.example.com",
        "no-cache",
        "Mon, 21 Oct 2013 20:13:21 GMT",
        "x",
        "",
    ]:
        var out = Bytes()
        encode_string(text.as_bytes(), out)
        var read = decode_string(out.as_span(), 0, 4096)
        assert_equal(read.value.to_string(), String(text))
        assert_equal(read.after, len(out))


def test_a_string_reports_where_reading_stopped() raises:
    var data = _from_hex("86a8eb10649cbfff")
    var read = decode_string(data.as_span(), 0, 4096)
    assert_equal(read.value.to_string(), "no-cache")
    assert_equal(read.after, 7)


def test_a_string_longer_than_what_is_left_is_refused() raises:
    # The length is announced by the peer and believed by nobody. `0x08` says
    # eight bytes follow and three do.
    var data = _from_hex("08616263")
    with assert_raises():
        _ = decode_string(data.as_span(), 0, 4096)


def test_a_truncated_string_header_is_refused() raises:
    var empty = Bytes()
    with assert_raises():
        _ = decode_string(empty.as_span(), 0, 16)


def test_a_plain_string_over_the_limit_is_refused() raises:
    var data = _from_hex("03616263")
    assert_equal(decode_string(data.as_span(), 0, 3).value.to_string(), "abc")
    with assert_raises():
        _ = decode_string(data.as_span(), 0, 2)


def test_a_huffman_string_over_the_limit_is_refused() raises:
    # Twelve octets of body that expand to fifteen bytes. A limit compared
    # against the announced length would let this through, which is the whole
    # reason the limit is on the result.
    var data = _from_hex("8cf1e3c2e5f23a6ba0ab90f4ff")
    assert_equal(
        decode_string(data.as_span(), 0, 15).value.to_string(),
        "www.example.com",
    )
    with assert_raises():
        _ = decode_string(data.as_span(), 0, 14)


def test_two_strings_in_a_row_read_from_where_the_last_one_stopped() raises:
    # A header field is a name and then a value, so this is the smallest thing
    # that shows the two pieces fit together.
    var out = Bytes()
    encode_string("custom-key".as_bytes(), out)
    encode_string("custom-value".as_bytes(), out)

    var name = decode_string(out.as_span(), 0, 4096)
    assert_equal(name.value.to_string(), "custom-key")

    var value = decode_string(out.as_span(), name.after, 4096)
    assert_equal(value.value.to_string(), "custom-value")
    assert_equal(value.after, len(out))
