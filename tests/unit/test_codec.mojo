"""The gzip and deflate decoders, and the bounds that keep a body from winning.

The fixtures are hexadecimal because there is no compressor here to make them
with. Every one of them came out of Python's `gzip` and `zlib` modules, which
is the same libz this decoder loads, so what is being tested is the binding and
the framing around it rather than the compression itself. The generating calls
are written above each fixture so that any of them can be made again.

Two of these tests are about size rather than about correctness. A compressed
body decides how large it becomes, so a decoder with no limit is a way to hand
a stranger the machine's memory. `DecodeLimits` is on by default and the two
tests that push past it are the reason it is.
"""

from std.testing import assert_equal, assert_raises, assert_true

from httpx._codec.decode import (
    Coding,
    DecodeLimits,
    Decoder,
    accept_encoding,
    coding_for,
    decode_all,
)
from httpx._ffi.brotli import is_available as brotli_available
from httpx._ffi.zlib import is_available, library_path, version_text
from httpx._ffi.zstd import is_available as zstd_available

from tests.support.hexdata import unhex

# gzip.compress(b"hello world, " * 20, mtime=0)
comptime HELLO_GZIP = (
    "1f8b08000000000002ffcb48cdc9c95728cf2fca49d151c818991c00b0252c6e04010000"
)

# zlib.compress(b"hello world, " * 20)
comptime HELLO_ZLIB = "789ccb48cdc9c95728cf2fca49d151c818991c00b0755d21"

# A compressobj with wbits=-15, which is the same data with no wrapper at all.
comptime HELLO_RAW = "cb48cdc9c95728cf2fca49d151c818991c00"

# gzip.compress(b"first half. ", mtime=0) + gzip.compress(b"second half.", mtime=0)
comptime TWO_MEMBERS = "1f8b08000000000002ff4bcb2c2a2e51c848cc49d35300007eae20060c0000001f8b08000000000002ff2b4e4dcecf4b51c848cc49d303001eded8890c000000"

comptime HELLO_TEXT = "hello world, "
comptime HELLO_TIMES = 20


def _zeros_gzip() raises -> List[UInt8]:
    """gzip.compress(b"\\0" * 100000, mtime=0).

    A hundred thousand bytes out of a hundred and thirty two. Not a real
    attack, which would be measured in gigabytes, but the same shape, and small
    enough to read.
    """
    return unhex(
        String(
            "1f8b08000000000002ffedc13101000000c2a0f54f6d0d0fa0000000",
            "00000000000000000000000000000000000000000000000000000000",
            "00000000000000000000000000000000000000000000000000000000",
            "00000000000000000000000000000000000000000000000000000000",
            "0000000000000000008057037d9511d4a0860100",
        )
    )


def _text(bytes: List[UInt8]) raises -> String:
    return String(StringSpan(from_utf8=Span(bytes)))


def _hello() -> String:
    var out = String()
    for _ in range(HELLO_TIMES):
        out += HELLO_TEXT
    return out^


def test_a_gzip_body_comes_back_as_what_went_in() raises:
    var out = decode_all(Coding.GZIP, Span(unhex(HELLO_GZIP)))
    assert_equal(_text(out), _hello())


def test_a_zlib_wrapped_body_is_what_deflate_is_supposed_to_mean() raises:
    var out = decode_all(Coding.DEFLATE, Span(unhex(HELLO_ZLIB)))
    assert_equal(_text(out), _hello())


def test_a_raw_deflate_body_is_read_too_because_servers_send_them() raises:
    """RFC 7230 says `deflate` is the zlib wrapper. Plenty of servers send the
    bare compressed data instead, and every other client copes, so this one
    sniffs the first two bytes and copes as well."""
    var out = decode_all(Coding.DEFLATE, Span(unhex(HELLO_RAW)))
    assert_equal(_text(out), _hello())


def test_a_body_pushed_one_byte_at_a_time_decodes_the_same() raises:
    """The decoder is fed by a socket, so the chunk boundaries are somebody
    else's. One byte at a time is the worst case: it lands inside the header,
    inside a match and inside the trailer, and none of those may lose a byte or
    produce one twice."""
    var source = unhex(HELLO_GZIP)
    var decoder = Decoder(Coding.GZIP)
    var out = List[UInt8]()
    for i in range(len(source)):
        var one = List[UInt8]()
        one.append(source[i])
        out.extend(Span(decoder.push(Span(one))))
    decoder.finish()
    assert_equal(_text(out), _hello())


def test_two_gzip_members_in_a_row_are_one_body() raises:
    """Concatenated members are a valid gzip stream and things in the wild do
    produce them, usually a pipeline that compressed each piece on its own."""
    var out = decode_all(Coding.GZIP, Span(unhex(TWO_MEMBERS)))
    assert_equal(_text(out), "first half. second half.")


def test_an_identity_decoder_hands_back_exactly_what_it_was_given() raises:
    var source = unhex(HELLO_GZIP)
    var out = decode_all(Coding.IDENTITY, Span(source))
    assert_equal(len(out), len(source))
    for i in range(len(source)):
        assert_equal(out[i], source[i])


def test_an_empty_body_with_a_coding_on_it_is_not_an_error() raises:
    """What a 304 or a HEAD produces. There is nothing there to be truncated,
    so refusing it would turn an ordinary response into a failure."""
    var empty = List[UInt8]()
    var out = decode_all(Coding.GZIP, Span(empty))
    assert_equal(len(out), 0)


def test_a_body_that_stops_in_the_middle_is_refused() raises:
    """The last six bytes of a gzip member are its CRC-32 and its length, so a
    truncated body is one nobody checked. Handing back as much as arrived would
    make a dropped connection look like a shorter document."""
    var source = unhex(HELLO_GZIP)
    var cut = List[UInt8]()
    for i in range(len(source) - 6):
        cut.append(source[i])
    with assert_raises(contains="ended in the middle"):
        _ = decode_all(Coding.GZIP, Span(cut))


def test_a_body_with_a_flipped_byte_is_refused() raises:
    var source = unhex(HELLO_GZIP)
    source[20] = source[20] ^ 0xFF
    with assert_raises(contains="not valid"):
        _ = decode_all(Coding.GZIP, Span(source))


def test_rubbish_after_the_last_member_is_refused() raises:
    """Trailing bytes are either another member or a mistake, and a decoder
    that ignored them would ignore a response somebody appended to."""
    var source = unhex(HELLO_GZIP)
    for byte in String("not a member").as_bytes():
        source.append(byte)
    with assert_raises():
        _ = decode_all(Coding.GZIP, Span(source))


def test_a_body_that_expands_past_the_output_limit_is_refused() raises:
    var limits = DecodeLimits(max_output=4096)
    with assert_raises(contains="expanded past"):
        _ = decode_all(Coding.GZIP, Span(_zeros_gzip()), limits)


def test_a_body_that_expands_faster_than_the_ratio_allows_is_refused() raises:
    """The floor is lowered here because the default one is sixty four
    kilobytes, and a fixture that large would be a fixture nobody reads. The
    bound being tested is the same one."""
    var limits = DecodeLimits(max_output=0, max_ratio=10, ratio_floor=16)
    with assert_raises(contains="times, past the limit"):
        _ = decode_all(Coding.GZIP, Span(_zeros_gzip()), limits)


def test_the_default_limits_accept_a_body_that_is_merely_compressible() raises:
    """A hundred thousand zeros is a seven hundred to one expansion and is a
    perfectly ordinary thing for a server to send. A bound that rejected it
    would be a bound somebody turns off."""
    var out = decode_all(Coding.GZIP, Span(_zeros_gzip()))
    assert_equal(len(out), 100000)
    for i in range(0, len(out), 1000):
        assert_equal(out[i], 0)


def test_a_decoder_says_how_much_it_has_produced() raises:
    var decoder = Decoder(Coding.GZIP)
    assert_equal(decoder.num_bytes_produced(), 0)
    var out = decoder.push(Span(unhex(HELLO_GZIP)))
    decoder.finish()
    assert_equal(decoder.num_bytes_produced(), len(out))
    assert_equal(decoder.coding(), Coding.GZIP)


def test_content_encoding_names_are_read_without_regard_to_case() raises:
    assert_equal(coding_for("gzip"), Coding.GZIP)
    assert_equal(coding_for("GZIP"), Coding.GZIP)
    assert_equal(coding_for("x-gzip"), Coding.GZIP)
    assert_equal(coding_for("Deflate"), Coding.DEFLATE)
    assert_equal(coding_for("BR"), Coding.BROTLI)
    assert_equal(coding_for("Zstd"), Coding.ZSTD)
    assert_equal(coding_for("identity"), Coding.IDENTITY)
    assert_equal(coding_for(""), Coding.IDENTITY)


def test_a_coding_we_do_not_implement_has_no_decoder() raises:
    """`compress` is the one in the registry nobody sends, and `exi` is a real
    coding for a format no HTTP client has any business with. Both stand for
    the same thing here: a token we know is a coding and cannot undo."""
    assert_equal(coding_for("compress"), Coding.UNKNOWN)
    assert_equal(coding_for("exi"), Coding.UNKNOWN)
    with assert_raises(contains="no decoder"):
        _ = Decoder(Coding.UNKNOWN)


def test_a_coding_writes_itself_under_the_name_a_header_uses() raises:
    assert_equal(String(Coding.GZIP), "gzip")
    assert_equal(String(Coding.DEFLATE), "deflate")
    assert_equal(String(Coding.BROTLI), "br")
    assert_equal(String(Coding.ZSTD), "zstd")
    assert_equal(String(Coding.IDENTITY), "identity")


def test_accept_encoding_names_only_what_this_process_can_undo() raises:
    """Asking for a coding we cannot decode gets back a body we cannot hand
    over, so the header is built from what loaded rather than from what was
    compiled in. Which libraries are on the machine is not something a test can
    assume, so the expectation is assembled the same way the header is."""
    var expected = String()
    if is_available():
        expected += "gzip, deflate"
    if brotli_available():
        if expected != "":
            expected += ", "
        expected += "br"
    if zstd_available():
        if expected != "":
            expected += ", "
        expected += "zstd"
    if expected == "":
        expected = String("identity")
    assert_equal(accept_encoding(), expected)


def test_zlib_says_which_library_it_loaded() raises:
    """A diagnostic rather than a behaviour. Which copy of libz is in the
    process is the first question when a body will not decode on one machine
    and decodes everywhere else."""
    if not is_available():
        return
    assert_true(len(version_text().as_bytes()) > 0)
    assert_true(len(library_path().as_bytes()) > 0)
