"""Tests for the HPACK Huffman code.

The encoding cases are the strings RFC 7541 works through in appendices C.4 and
C.6, with the bytes the RFC prints beside them. They are worth having as
literals rather than as round trips, because a round trip passes just as well
against a table that is wrong in a self consistent way.

The rest is about what a decoder does with input it was not sent by a friendly
encoder, which is the half that matters: the encoder only ever sees our own
bytes, and the decoder only ever sees somebody else's.
"""

from std.testing import assert_equal, assert_raises, assert_true

from httpx._bytes import Bytes
from httpx._proto.h2.huffman import (
    huffman_decode,
    huffman_encode,
    huffman_encoded_length,
)

comptime _DIGITS = StaticString("0123456789abcdef")


def _nibble(byte: UInt8) -> Int:
    if byte >= UInt8(ord("a")):
        return Int(byte - UInt8(ord("a"))) + 10
    return Int(byte - UInt8(ord("0")))


def _bytes_from_hex(text: StringSpan) -> Bytes:
    var source = text.as_bytes()
    var out = Bytes()
    for i in range(0, len(source), 2):
        out.append(UInt8(_nibble(source[i]) * 16 + _nibble(source[i + 1])))
    return out^


def _hex_of(data: Bytes) -> String:
    var out = String()
    for i in range(len(data)):
        var high = Int(data[i] >> 4)
        var low = Int(data[i] & 0xF)
        out += _DIGITS[byte = high : high + 1]
        out += _DIGITS[byte = low : low + 1]
    return out^


def _encoded(text: StringSpan) -> String:
    var out = Bytes()
    huffman_encode(text.as_bytes(), out)
    return _hex_of(out)


def _decoded(hexed: StringSpan) raises -> String:
    var data = _bytes_from_hex(hexed)
    var out = huffman_decode(data.as_span(), 4096)
    return out.to_string()


def test_the_rfc_7541_strings_encode_to_the_bytes_the_rfc_prints() raises:
    assert_equal(_encoded("www.example.com"), "f1e3c2e5f23a6ba0ab90f4ff")
    assert_equal(_encoded("no-cache"), "a8eb10649cbf")
    assert_equal(_encoded("custom-key"), "25a849e95ba97d7f")
    assert_equal(_encoded("custom-value"), "25a849e95bb8e8b4bf")
    assert_equal(_encoded("private"), "aec3771a4b")
    assert_equal(
        _encoded("Mon, 21 Oct 2013 20:13:21 GMT"),
        "d07abe941054d444a8200595040b8166e082a62d1bff",
    )
    assert_equal(
        _encoded("https://www.example.com"),
        "9d29ad171863c78f0b97c8e9ae82ae43d3",
    )
    assert_equal(
        _encoded("foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"),
        (
            "94e7821dd7f2e6c7b335dfdfcd5b3960d5af27087f3672c1ab270fb5291f958731"
            "6065c003ed4ee5b1063d5007"
        ),
    )


def test_the_rfc_7541_bytes_decode_back_to_the_strings() raises:
    assert_equal(_decoded("f1e3c2e5f23a6ba0ab90f4ff"), "www.example.com")
    assert_equal(_decoded("a8eb10649cbf"), "no-cache")
    assert_equal(_decoded("25a849e95ba97d7f"), "custom-key")
    assert_equal(_decoded("25a849e95bb8e8b4bf"), "custom-value")
    assert_equal(_decoded("aec3771a4b"), "private")
    assert_equal(
        _decoded("d07abe941054d444a8200595040b8166e082a62d1bff"),
        "Mon, 21 Oct 2013 20:13:21 GMT",
    )
    assert_equal(
        _decoded("9d29ad171863c78f0b97c8e9ae82ae43d3"),
        "https://www.example.com",
    )


def test_the_measured_length_is_the_length_that_comes_out() raises:
    # The encoder asks for the length before it decides whether to spend
    # anything on Huffman at all, so a measurement that disagreed with the
    # encoding would send a length prefix that does not match the body.
    for text in [
        StaticString(""),
        "a",
        "www.example.com",
        "Mon, 21 Oct 2013 20:13:21 GMT",
    ]:
        var out = Bytes()
        huffman_encode(text.as_bytes(), out)
        assert_equal(huffman_encoded_length(text.as_bytes()), len(out))

    # And over the long codes too, which no header text reaches.
    var all_bytes = Bytes()
    for i in range(256):
        all_bytes.append(UInt8(i))
    var coded = Bytes()
    huffman_encode(all_bytes.as_span(), coded)
    assert_equal(huffman_encoded_length(all_bytes.as_span()), len(coded))


def test_every_byte_survives_a_round_trip() raises:
    # The RFC vectors are all header text, so they exercise the short codes and
    # none of the thirty bit ones. Every byte value is the cheapest way to reach
    # the rest of the table.
    var all_bytes = Bytes()
    for i in range(256):
        all_bytes.append(UInt8(i))

    var coded = Bytes()
    huffman_encode(all_bytes.as_span(), coded)
    var back = huffman_decode(coded.as_span(), 4096)

    assert_equal(len(back), 256)
    for i in range(256):
        assert_equal(Int(back[i]), i)


def test_nothing_encodes_and_decodes_to_nothing() raises:
    var out = Bytes()
    huffman_encode("".as_bytes(), out)
    assert_equal(len(out), 0)

    var empty = Bytes()
    assert_equal(len(huffman_decode(empty.as_span(), 16)), 0)


def test_an_encoded_end_of_string_symbol_is_refused() raises:
    # RFC 7541 section 5.2. The EOS code is thirty ones, so four bytes of them
    # contain it whole. An encoder never emits it, which is exactly why a
    # decoder that accepted it would be accepting something only an attacker
    # sends.
    with assert_raises():
        _ = _decoded("ffffffff")


def test_padding_that_is_not_all_ones_is_refused() raises:
    # `a` is five bits, so a byte of it leaves three bits of padding. Ones are
    # the only thing those may be.
    assert_equal(_decoded("1f"), "a")
    with assert_raises():
        _ = _decoded("18")


def test_a_whole_byte_of_padding_is_refused() raises:
    # The string is complete after twelve bytes and the thirteenth is eight
    # ones. RFC 7541 section 5.2 allows fewer than eight bits of padding, so a
    # full byte of it means the sender is either broken or padding on purpose.
    assert_equal(_decoded("f1e3c2e5f23a6ba0ab90f4ff"), "www.example.com")
    with assert_raises():
        _ = _decoded("f1e3c2e5f23a6ba0ab90f4ffff")


def test_a_code_cut_off_partway_through_is_refused() raises:
    # Three of the four bytes of `www.`, which stops in the middle of the code
    # for the dot rather than at a symbol boundary.
    with assert_raises():
        _ = _decoded("f1e3c2")


def test_decoding_stops_at_the_limit_it_was_given() raises:
    # The whole point of the limit. Twelve bytes on the wire expand to fifteen,
    # and a longer input expands further, so a decoder without a ceiling is one
    # a peer can talk into any allocation it likes.
    var data = _bytes_from_hex("f1e3c2e5f23a6ba0ab90f4ff")
    assert_equal(len(huffman_decode(data.as_span(), 15)), 15)
    with assert_raises():
        _ = huffman_decode(data.as_span(), 14)


def test_the_limit_counts_output_and_not_input() raises:
    # A limit checked against the encoded length would pass this: the input is
    # shorter than the limit and the output is not.
    var data = _bytes_from_hex("f1e3c2e5f23a6ba0ab90f4ff")
    assert_true(len(data) < 15)
    with assert_raises():
        _ = huffman_decode(data.as_span(), len(data))
