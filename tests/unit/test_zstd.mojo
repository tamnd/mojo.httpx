"""The zstd decoder, over fixtures, and the bounds that go with it.

The same shape as `test_codec.mojo`, which does gzip and deflate. The fixtures
are hexadecimal with the Python call that made them written above each one,
because there is no compressor on this side and a binary file checked into the
repository is a fixture nobody can read or remake. They came from
`compression.zstd`, which is the standard library module from Python 3.14 on
and is a binding to the same libzstd this decoder loads.

Every test returns early when libzstd did not load. It is in the pixi
environment, so it is there on every machine the suite runs on, but a build
that could not find it should report the one failure that says so rather than a
dozen that look like decoding bugs.
"""

from std.testing import assert_equal, assert_raises, assert_true

from httpx._codec.decode import (
    Coding,
    DecodeLimits,
    Decoder,
    coding_for,
    decode_all,
    decoders_for,
    missing_library,
)
from httpx._ffi.zstd import is_available, library_path, version_text

from tests.support.hexdata import unhex

# zstd.compress(b"hello world, " * 20)
comptime HELLO_ZSTD = (
    "28b52ffd600400a500006868656c6c6f20776f726c642c20010074a0e617"
)

# zstd.compress(b"first half. ") + zstd.compress(b"second half.")
comptime TWO_FRAMES = (
    "28b52ffd200c61000066697273742068616c662e20"
    "28b52ffd200c6100007365636f6e642068616c662e"
)

# zstd.compress(b"\0" * 100000). Twenty two bytes for a hundred thousand, which
# is not an attack at this size but is exactly the shape of one.
comptime ZEROS_ZSTD = "28b52ffda0a086010055000010000001009b8639c002"

comptime HELLO_TEXT = "hello world, "
comptime HELLO_TIMES = 20


def _text(bytes: List[UInt8]) raises -> String:
    return String(StringSpan(from_utf8=Span(bytes)))


def _hello() -> String:
    var out = String()
    for _ in range(HELLO_TIMES):
        out += HELLO_TEXT
    return out^


def test_a_zstd_body_comes_back_as_what_went_in() raises:
    if not is_available():
        return
    var out = decode_all(Coding.ZSTD, Span(unhex(HELLO_ZSTD)))
    assert_equal(_text(out), _hello())


def test_a_zstd_body_pushed_one_byte_at_a_time_decodes_the_same() raises:
    """The decoder is fed by a socket, so the chunk boundaries are somebody
    else's. One byte at a time is the worst case: it lands inside the frame
    header, inside a block and inside the checksum, and none of those may lose
    a byte or produce one twice."""
    if not is_available():
        return
    var source = unhex(HELLO_ZSTD)
    var decoder = Decoder(Coding.ZSTD)
    var out = List[UInt8]()
    for i in range(len(source)):
        var one = List[UInt8]()
        one.append(source[i])
        out.extend(Span(decoder.push(Span(one))))
    decoder.finish()
    assert_equal(_text(out), _hello())


def test_a_zstd_body_larger_than_one_pass_of_the_sink() raises:
    """A hundred thousand bytes out of twenty two takes several passes over the
    thirty two kilobyte buffer the decoder writes into, so this is the test that
    the loop terminates and keeps everything it produced."""
    if not is_available():
        return
    var out = decode_all(Coding.ZSTD, Span(unhex(ZEROS_ZSTD)))
    assert_equal(len(out), 100000)
    for i in range(0, len(out), 1000):
        assert_equal(out[i], 0)


def test_an_empty_zstd_body_is_not_an_error() raises:
    """What a 304 or a HEAD produces. There is nothing there to be truncated,
    so refusing it would turn an ordinary response into a failure."""
    if not is_available():
        return
    var empty = List[UInt8]()
    var out = decode_all(Coding.ZSTD, Span(empty))
    assert_equal(len(out), 0)


def test_a_zstd_body_that_stops_in_the_middle_is_refused() raises:
    """The last four bytes of this frame are an XXH64 of the content, so a
    truncated body is one nobody checked. Handing back as much as arrived would
    make a dropped connection look like a shorter document."""
    if not is_available():
        return
    var source = unhex(HELLO_ZSTD)
    var cut = List[UInt8]()
    for i in range(len(source) - 6):
        cut.append(source[i])
    with assert_raises(contains="ended in the middle"):
        _ = decode_all(Coding.ZSTD, Span(cut))


def test_a_zstd_body_with_a_flipped_byte_is_refused() raises:
    if not is_available():
        return
    var source = unhex(HELLO_ZSTD)
    source[8] = source[8] ^ 0xFF
    with assert_raises(contains="not valid"):
        _ = decode_all(Coding.ZSTD, Span(source))


def test_a_zstd_body_that_is_not_zstd_at_all_is_refused() raises:
    """Every frame starts with the same four byte magic number, so this fails
    on the first pass rather than somewhere in the middle, and the message is
    the library's own name for that."""
    if not is_available():
        return
    var source = unhex(HELLO_ZSTD)
    source[0] = source[0] ^ 0xFF
    with assert_raises(contains="not valid"):
        _ = decode_all(Coding.ZSTD, Span(source))


def test_rubbish_after_the_last_zstd_frame_is_refused() raises:
    """Trailing bytes are either another frame or a mistake, and a decoder that
    ignored them would ignore a response somebody appended to."""
    if not is_available():
        return
    var source = unhex(HELLO_ZSTD)
    for byte in String("not a frame").as_bytes():
        source.append(byte)
    with assert_raises():
        _ = decode_all(Coding.ZSTD, Span(source))


def test_two_zstd_frames_in_a_row_are_one_body() raises:
    """Concatenated frames are a valid zstd stream and the command line tool
    produces them, so a decoder that stopped at the first would silently drop
    the rest of a body."""
    if not is_available():
        return
    var out = decode_all(Coding.ZSTD, Span(unhex(TWO_FRAMES)))
    assert_equal(_text(out), "first half. second half.")


def test_a_zstd_body_past_the_output_limit_is_refused() raises:
    if not is_available():
        return
    var limits = DecodeLimits(max_output=4096)
    with assert_raises(contains="expanded past"):
        _ = decode_all(Coding.ZSTD, Span(unhex(ZEROS_ZSTD)), limits)


def test_a_zstd_body_past_the_ratio_limit_is_refused() raises:
    """The floor is lowered here because the default one is sixty four
    kilobytes and this fixture is twenty two bytes. The bound being tested is
    the same one, and it is the bound that still works for a caller who raised
    `max_output` because they really do download large things."""
    if not is_available():
        return
    var limits = DecodeLimits(max_output=0, max_ratio=10, ratio_floor=8)
    with assert_raises(contains="times, past the limit"):
        _ = decode_all(Coding.ZSTD, Span(unhex(ZEROS_ZSTD)), limits)


def test_the_default_limits_accept_an_ordinary_zstd_body() raises:
    """Four thousand to one is past the ratio bound as a number and is accepted
    anyway, because twenty two bytes is below the floor where the ratio is
    judged at all. That floor is what keeps the bound from firing on the small
    highly compressible bodies real servers send."""
    if not is_available():
        return
    var out = decode_all(Coding.ZSTD, Span(unhex(ZEROS_ZSTD)))
    assert_equal(len(out), 100000)


def test_zstd_is_the_name_the_header_uses() raises:
    assert_equal(coding_for("zstd"), Coding.ZSTD)
    assert_equal(String(Coding.ZSTD), "zstd")


def test_a_content_encoding_of_zstd_makes_one_decoder() raises:
    if not is_available():
        return
    var decoders = decoders_for("zstd")
    assert_equal(len(decoders), 1)
    assert_equal(decoders[0].coding(), Coding.ZSTD)


def test_zstd_reports_itself_as_available_or_says_why_not() raises:
    """The two have to agree. A coding that `missing_library` calls fine and
    `is_available` calls absent would put `zstd` in `Accept-Encoding` and then
    fail on the answer."""
    if is_available():
        assert_equal(missing_library(Coding.ZSTD), "")
    else:
        assert_true(missing_library(Coding.ZSTD).find("zstd") >= 0)


def test_zstd_says_which_library_it_loaded() raises:
    """A diagnostic rather than a behaviour. Which copy of libzstd is in the
    process is the first question when a body will not decode on one machine
    and decodes everywhere else."""
    if not is_available():
        return
    assert_true(version_text().byte_length() > 0)
    assert_true(library_path().byte_length() > 0)
