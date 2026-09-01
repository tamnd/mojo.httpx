"""Tests for base64, which exists here only to build a Basic auth header.

The cases are RFC 4648's own test vectors, which are chosen to cover the thing
that goes wrong: the tail. A group of three bytes is mechanical, and every
mistake in a base64 encoder is in what happens when the input does not divide
by three.
"""

from std.testing import assert_equal

from httpx._util.base64 import base64_encode


def _encode(text: StringSpan) -> String:
    return base64_encode(text.as_bytes())


def test_the_rfc_4648_vectors() raises:
    assert_equal(_encode(""), "")
    assert_equal(_encode("f"), "Zg==")
    assert_equal(_encode("fo"), "Zm8=")
    assert_equal(_encode("foo"), "Zm9v")
    assert_equal(_encode("foob"), "Zm9vYg==")
    assert_equal(_encode("fooba"), "Zm9vYmE=")
    assert_equal(_encode("foobar"), "Zm9vYmFy")


def test_a_credential_pair_encodes_the_way_a_server_expects() raises:
    assert_equal(_encode("user:hunter2"), "dXNlcjpodW50ZXIy")
    assert_equal(_encode("Aladdin:open sesame"), "QWxhZGRpbjpvcGVuIHNlc2FtZQ==")


def test_bytes_outside_ascii_survive() raises:
    # The input is bytes and not text, so a password that is not ASCII has to
    # come out as the encoding of its bytes rather than of anything else.
    var data = List[UInt8]()
    data.append(0xFF)
    data.append(0xFE)
    data.append(0xFD)
    assert_equal(base64_encode(Span(data)), "//79")

    var one = List[UInt8]()
    one.append(0xFF)
    assert_equal(base64_encode(Span(one)), "/w==")


def test_the_output_is_never_wrapped() raises:
    # MIME breaks base64 into 76 character lines. An HTTP header cannot contain
    # a newline, so this must not.
    var long = List[UInt8]()
    for _ in range(200):
        long.append(UInt8(ord("a")))
    var encoded = base64_encode(Span(long))
    assert_equal(encoded.byte_length(), 268)
    assert_equal(encoded.find("\n"), -1)
    assert_equal(encoded.find("\r"), -1)
