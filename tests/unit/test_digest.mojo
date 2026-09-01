"""Tests for the four hash functions digest authentication needs.

Every expected value here comes from an independent implementation, either the
vectors published with the algorithm or Python's `hashlib`, because a hash
tested against itself is not tested at all.

Most of the cases are lengths rather than interesting content. A hash function
of this shape is almost always correct on the body of the message and wrong at
the padding, so the lengths chosen are the ones that surround a block boundary:
one byte short of the length field fitting, exactly at it, one over, and the
same three around the block size itself. That is where a message grows an extra
block, and it is the case a wrong implementation gets wrong.
"""

from std.testing import assert_equal, assert_true

from httpx._util.digest import (
    Algorithm,
    hex,
    hex_digest,
    md5,
    sha1,
    sha256,
    sha512,
)


def _bytes(text: StringSpan) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(text.as_bytes())
    return out^


def _repeat(byte: StringSpan, count: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for _ in range(count):
        out.extend(byte.as_bytes())
    return out^


def _md5(text: StringSpan) -> String:
    var data = _bytes(text)
    return hex(Span(md5(Span(data))))


def _sha1(text: StringSpan) -> String:
    var data = _bytes(text)
    return hex(Span(sha1(Span(data))))


def _md5_of(var data: List[UInt8]) -> String:
    return hex(Span(md5(Span(data))))


def _sha256_of(var data: List[UInt8]) -> String:
    return hex(Span(sha256(Span(data))))


def _sha512_of(var data: List[UInt8]) -> String:
    return hex(Span(sha512(Span(data))))


def test_md5_matches_the_rfc_1321_vectors() raises:
    assert_equal(_md5(""), "d41d8cd98f00b204e9800998ecf8427e")
    assert_equal(_md5("abc"), "900150983cd24fb0d6963f7d28e17f72")
    assert_equal(_md5("message digest"), "f96b697d7cb7938d525a2f31aaf161d0")
    assert_equal(
        _md5("abcdefghijklmnopqrstuvwxyz"),
        "c3fcd3d76192e4007dfb496cca67e13b",
    )


def test_sha1_matches_the_published_vectors() raises:
    assert_equal(_sha1(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    assert_equal(_sha1("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
    assert_equal(
        _sha1("abcdefghijklmnopqrstuvwxyz"),
        "32d10c7b8cf96570ca04ce37f2a19d84240d3a89",
    )


def test_sha256_matches_the_published_vector() raises:
    assert_equal(
        _sha256_of(_bytes("abc")),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    )


def test_sha512_matches_the_published_vector() raises:
    assert_equal(
        _sha512_of(_bytes("abc")),
        (
            "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
            "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
        ),
    )


def test_md5_around_a_block_boundary() raises:
    # 55 is the last length whose padding and length field still fit in one
    # block. 56 is the first that does not. Both matter more than any content.
    assert_equal(_md5_of(_repeat("a", 55)), "ef1772b6dff9a122358552954ad0df65")
    assert_equal(_md5_of(_repeat("a", 56)), "3b0c8ac703f828b04c6c197006d17218")
    assert_equal(_md5_of(_repeat("a", 57)), "652b906d60af96844ebd21b674f35e93")
    assert_equal(_md5_of(_repeat("a", 63)), "b06521f39153d618550606be297466d5")
    assert_equal(_md5_of(_repeat("a", 64)), "014842d480b571495a4a0363793f7367")
    assert_equal(_md5_of(_repeat("a", 65)), "c743a45e0d2e6a95cb859adae0248435")


def test_sha256_around_a_block_boundary() raises:
    assert_equal(
        _sha256_of(_repeat("a", 55)),
        "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
    )
    assert_equal(
        _sha256_of(_repeat("a", 56)),
        "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
    )
    assert_equal(
        _sha256_of(_repeat("a", 64)),
        "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
    )
    assert_equal(
        _sha256_of(_repeat("a", 65)),
        "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0",
    )


def test_sha512_around_its_larger_block_boundary() raises:
    # SHA-512 works in 128 byte blocks with a 128 bit length field, so its
    # awkward lengths are 111 and 112 rather than 55 and 56.
    assert_equal(
        _sha512_of(_repeat("a", 111)),
        (
            "fa9121c7b32b9e01733d034cfc78cbf67f926c7ed83e82200ef8681819692176"
            "0b4beff48404df811b953828274461673c68d04e297b0eb7b2b4d60fc6b566a2"
        ),
    )
    assert_equal(
        _sha512_of(_repeat("a", 112)),
        (
            "c01d080efd492776a1c43bd23dd99d0a2e626d481e16782e75d54c2503b5dc32"
            "bd05f0f1ba33e568b88fd2d970929b719ecbb152f58f130a407c8830604b70ca"
        ),
    )
    assert_equal(
        _sha512_of(_repeat("a", 128)),
        (
            "b73d1929aa615934e61a871596b3f3b33359f42b8175602e89f7e06e5f658a24"
            "3667807ed300314b95cacdd579f3e33abdfbe351909519a846d465c59582f321"
        ),
    )
    assert_equal(
        _sha512_of(_repeat("a", 129)),
        (
            "4f681e0bd53cda4b5a2041cc8a06f2eabde44fb16c951fbd5b87702f07aeab61"
            "1565b19c47fde30587177ebb852e3971bbd8d3fd30da18d71037dfbd98420429"
        ),
    )


def test_a_long_message_spans_many_blocks() raises:
    # A megabyte of one letter, which is the published vector for both and the
    # only case here that runs the compression function thousands of times.
    assert_equal(
        _md5_of(_repeat("a", 1000000)), "7707d6ae4e027c70eea2a935c2296f21"
    )
    assert_equal(
        hex(Span(sha1(Span(_repeat("a", 1000000))))),
        "34aa973cd4c4daa4f61eeb2bdbad27316534016f",
    )


def test_the_algorithm_is_chosen_at_run_time() raises:
    var data = _bytes("abc")
    assert_equal(
        hex_digest(Algorithm.MD5, Span(data)),
        "900150983cd24fb0d6963f7d28e17f72",
    )
    assert_equal(
        hex_digest(Algorithm.SHA1, Span(data)),
        "a9993e364706816aba3e25717850c26c9cd0d89d",
    )
    assert_equal(
        hex_digest(Algorithm.SHA256, Span(data)),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    )


def test_hex_is_lowercase_and_two_characters_a_byte() raises:
    var data = List[UInt8]()
    data.append(0x00)
    data.append(0x0F)
    data.append(0xF0)
    data.append(0xFF)
    assert_equal(hex(Span(data)), "000ff0ff")
    var empty = List[UInt8]()
    assert_equal(hex(Span(empty)), "")


def test_an_unknown_algorithm_is_refused_rather_than_guessed() raises:
    var data = _bytes("abc")
    var raised = False
    try:
        _ = hex_digest(Algorithm(200), Span(data))
    except:
        raised = True
    assert_true(raised)
