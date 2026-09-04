"""The brotli decoder, over fixtures, and the bounds that go with it.

The same shape as `test_codec.mojo`, which does gzip and deflate. The fixtures
are hexadecimal with the Python call that made them written above each one,
because there is no compressor on this side and a binary file checked into the
repository is a fixture nobody can read or remake.

Every test returns early when libbrotlidec did not load. It is in the pixi
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
from httpx._ffi.brotli import is_available, library_path, version_text

from tests.support.hexdata import unhex

# brotli.compress(b"hello world, " * 20, quality=11)
comptime HELLO_BR = "1b0301f88dd44ef9c3505465680dc2c2f6a66699ac1ac8806a8e09"

# brotli.compress(b"first half. ", quality=11)
# + brotli.compress(b"second half.", quality=11)
comptime TWO_STREAMS = "1b0b00f825004a90410a0298f2401b0b00f8255c4a116162a18c07"

# brotli.compress(b"\0" * 100000, quality=11). Fourteen bytes for a hundred
# thousand, which is not an attack at this size but is exactly the shape of one.
comptime ZEROS_BR = "5b9f86817f02201e0b04b2fc0200"

comptime HELLO_TEXT = "hello world, "
comptime HELLO_TIMES = 20


def _text(bytes: List[UInt8]) raises -> String:
    return String(StringSpan(from_utf8=Span(bytes)))


def _hello() -> String:
    var out = String()
    for _ in range(HELLO_TIMES):
        out += HELLO_TEXT
    return out^


def test_a_brotli_body_comes_back_as_what_went_in() raises:
    if not is_available():
        return
    var out = decode_all(Coding.BROTLI, Span(unhex(HELLO_BR)))
    assert_equal(_text(out), _hello())


def test_a_brotli_body_pushed_one_byte_at_a_time_decodes_the_same() raises:
    """The decoder is fed by a socket, so the chunk boundaries are somebody
    else's. One byte at a time is the worst case: it lands inside the header,
    inside a backward reference and inside the last block, and none of those
    may lose a byte or produce one twice."""
    if not is_available():
        return
    var source = unhex(HELLO_BR)
    var decoder = Decoder(Coding.BROTLI)
    var out = List[UInt8]()
    for i in range(len(source)):
        var one = List[UInt8]()
        one.append(source[i])
        out.extend(Span(decoder.push(Span(one))))
    decoder.finish()
    assert_equal(_text(out), _hello())


def test_a_brotli_body_larger_than_one_pass_of_the_sink() raises:
    """A hundred thousand bytes out of fourteen takes several passes over the
    thirty two kilobyte buffer the decoder writes into, so this is the test that
    the loop around `BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT` terminates and
    keeps everything it produced."""
    if not is_available():
        return
    var out = decode_all(Coding.BROTLI, Span(unhex(ZEROS_BR)))
    assert_equal(len(out), 100000)
    for i in range(0, len(out), 1000):
        assert_equal(out[i], 0)


def test_an_empty_brotli_body_is_not_an_error() raises:
    """What a 304 or a HEAD produces. There is nothing there to be truncated,
    so refusing it would turn an ordinary response into a failure."""
    if not is_available():
        return
    var empty = List[UInt8]()
    var out = decode_all(Coding.BROTLI, Span(empty))
    assert_equal(len(out), 0)


def test_a_brotli_body_that_stops_in_the_middle_is_refused() raises:
    """brotli marks its last block in the stream itself, so a body that stops
    early is one nobody reached the end of. Handing back as much as arrived
    would make a dropped connection look like a shorter document."""
    if not is_available():
        return
    var source = unhex(HELLO_BR)
    var cut = List[UInt8]()
    for i in range(len(source) - 4):
        cut.append(source[i])
    with assert_raises(contains="ended in the middle"):
        _ = decode_all(Coding.BROTLI, Span(cut))


def test_a_brotli_body_with_a_flipped_byte_is_refused() raises:
    if not is_available():
        return
    var source = unhex(HELLO_BR)
    source[3] = source[3] ^ 0xFF
    with assert_raises(contains="not valid"):
        _ = decode_all(Coding.BROTLI, Span(source))


def test_the_brotli_error_carries_the_librarys_own_words() raises:
    """`BROTLI_DECODER_RESULT_ERROR` on its own says nothing about which part
    of the stream was wrong, and the error code does, so both are in the
    message."""
    if not is_available():
        return
    var source = unhex(HELLO_BR)
    source[0] = 0x51
    with assert_raises(contains="(ERROR_FORMAT_"):
        _ = decode_all(Coding.BROTLI, Span(source))


def test_rubbish_after_the_end_of_a_brotli_body_is_refused() raises:
    """Trailing bytes are either another stream or a mistake, and a decoder
    that ignored them would ignore a response somebody appended to."""
    if not is_available():
        return
    var source = unhex(HELLO_BR)
    for byte in String("not a stream").as_bytes():
        source.append(byte)
    with assert_raises():
        _ = decode_all(Coding.BROTLI, Span(source))


def test_two_brotli_streams_in_a_row_are_one_body() raises:
    """Not something HTTP asks for, and it falls out of treating the end of a
    stream the way gzip treats the end of a member. Worth a test because the
    alternative reading of those bytes is that everything after the first
    stream is silently dropped."""
    if not is_available():
        return
    var out = decode_all(Coding.BROTLI, Span(unhex(TWO_STREAMS)))
    assert_equal(_text(out), "first half. second half.")


def test_a_brotli_body_past_the_output_limit_is_refused() raises:
    if not is_available():
        return
    var limits = DecodeLimits(max_output=4096)
    with assert_raises(contains="expanded past"):
        _ = decode_all(Coding.BROTLI, Span(unhex(ZEROS_BR)), limits)


def test_a_brotli_body_past_the_ratio_limit_is_refused() raises:
    """The floor is lowered here because the default one is sixty four
    kilobytes and this fixture is fourteen bytes. The bound being tested is the
    same one, and it is the bound that still works for a caller who raised
    `max_output` because they really do download large things."""
    if not is_available():
        return
    var limits = DecodeLimits(max_output=0, max_ratio=10, ratio_floor=8)
    with assert_raises(contains="times, past the limit"):
        _ = decode_all(Coding.BROTLI, Span(unhex(ZEROS_BR)), limits)


def test_the_default_limits_accept_an_ordinary_brotli_body() raises:
    """Seven thousand to one is past the ratio bound as a number and is
    accepted anyway, because fourteen bytes is below the floor where the ratio
    is judged at all. That floor is what keeps the bound from firing on the
    small highly compressible bodies real servers send."""
    if not is_available():
        return
    var out = decode_all(Coding.BROTLI, Span(unhex(ZEROS_BR)))
    assert_equal(len(out), 100000)


def test_br_is_the_name_the_header_uses() raises:
    assert_equal(coding_for("br"), Coding.BROTLI)
    assert_equal(String(Coding.BROTLI), "br")


def test_a_content_encoding_of_br_makes_one_decoder() raises:
    if not is_available():
        return
    var decoders = decoders_for("br")
    assert_equal(len(decoders), 1)
    assert_equal(decoders[0].coding(), Coding.BROTLI)


def test_brotli_reports_itself_as_available_or_says_why_not() raises:
    """The two have to agree. A coding that `missing_library` calls fine and
    `is_available` calls absent would put `br` in `Accept-Encoding` and then
    fail on the answer."""
    if is_available():
        assert_equal(missing_library(Coding.BROTLI), "")
    else:
        assert_true(missing_library(Coding.BROTLI).find("brotli") >= 0)


def test_brotli_says_which_library_it_loaded() raises:
    """A diagnostic rather than a behaviour. Which copy of libbrotlidec is in
    the process is the first question when a body will not decode on one
    machine and decodes everywhere else."""
    if not is_available():
        return
    assert_true(version_text().byte_length() > 0)
    assert_true(library_path().byte_length() > 0)
