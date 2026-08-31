"""Tests for the body reader.

Two things are being pinned down. First that each framing mode reads the right
bytes and stops in the right place, which for a length framed body means not
taking one byte of the next response and for a chunked one means not stopping a
line early. Second that a body fed in arbitrary pieces reads the same as one fed
whole, because that is the difference between a decoder that works on a string
and one that works on a socket.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._exceptions import is_remote_protocol_error
from httpx._io.buffer import ByteBuffer
from httpx._proto.h1.body import BodyReader
from httpx._proto.h1.framing import BodyMode, Framing


def _reader(mode: BodyMode, length: Int = 0) -> BodyReader:
    return BodyReader(Framing(mode, length))


def _feed(mut reader: BodyReader, text: StringSpan) raises -> String:
    """Hand the reader all of `text` at once and return what it decoded."""
    var buf = ByteBuffer()
    buf.extend(text.as_bytes())
    var out = List[UInt8]()
    _ = reader.read_from(buf, out)
    return String(StringSpan(from_utf8=Span(out)))


def _drip(mut reader: BodyReader, text: StringSpan) raises -> String:
    """Hand the reader `text` one byte at a time and return what it decoded.

    The interesting version. Every boundary in the framing lands in the middle
    of a call at some point, so a decoder that kept state on the stack instead
    of in the struct fails here and nowhere else.
    """
    var bytes = text.as_bytes()
    var buf = ByteBuffer()
    var out = List[UInt8]()
    for i in range(bytes.__len__()):
        buf.extend(bytes[i : i + 1])
        _ = reader.read_from(buf, out)
    return String(StringSpan(from_utf8=Span(out)))


def _chunked_rejected(text: StringSpan) raises:
    var reader = _reader(BodyMode.CHUNKED)
    var raised = False
    try:
        _ = _feed(reader, text)
    except e:
        raised = True
        assert_true(is_remote_protocol_error(e))
    assert_true(raised)


def test_a_body_with_no_content_is_complete_before_anything_is_read() raises:
    # A 204 has nothing to wait for, and a reader that did not know that would
    # sit on the socket until the server gave up.
    var reader = _reader(BodyMode.NONE)
    assert_true(reader.is_complete())


def test_a_zero_length_body_is_complete_before_anything_is_read() raises:
    var reader = _reader(BodyMode.LENGTH, 0)
    assert_true(reader.is_complete())


def test_a_length_framed_body_reads_exactly_that_many_bytes() raises:
    var reader = _reader(BodyMode.LENGTH, 5)
    assert_equal(_feed(reader, "hello"), "hello")
    assert_true(reader.is_complete())


def test_a_length_framed_body_leaves_the_next_response_alone() raises:
    # The one that matters for connection reuse. Taking one extra byte here
    # means every request after this one on the same connection is misparsed.
    var reader = _reader(BodyMode.LENGTH, 5)
    var buf = ByteBuffer()
    buf.extend("helloHTTP/1.1 200 OK\r\n\r\n".as_bytes())
    var out = List[UInt8]()
    assert_false(reader.read_from(buf, out))
    assert_equal(String(StringSpan(from_utf8=Span(out))), "hello")
    assert_equal(
        String(StringSpan(from_utf8=buf.unread())), "HTTP/1.1 200 OK\r\n\r\n"
    )


def test_a_length_framed_body_arriving_in_pieces_reads_the_same() raises:
    var reader = _reader(BodyMode.LENGTH, 11)
    assert_equal(_drip(reader, "hello world"), "hello world")
    assert_true(reader.is_complete())


def test_a_length_framed_body_wants_more_until_it_has_it_all() raises:
    var reader = _reader(BodyMode.LENGTH, 10)
    var buf = ByteBuffer()
    buf.extend("hello".as_bytes())
    var out = List[UInt8]()
    assert_true(reader.read_from(buf, out))
    assert_false(reader.is_complete())


def test_a_truncated_length_framed_body_is_an_error() raises:
    # Half a response that reports success is worse than no response, because
    # the caller acts on it.
    var reader = _reader(BodyMode.LENGTH, 10)
    _ = _feed(reader, "hello")
    var raised = False
    try:
        reader.at_eof()
    except e:
        raised = True
        assert_true(is_remote_protocol_error(e))
    assert_true(raised)


def test_a_body_read_until_close_takes_everything() raises:
    var reader = _reader(BodyMode.UNTIL_CLOSE)
    assert_equal(_feed(reader, "some bytes"), "some bytes")
    assert_false(reader.is_complete())
    reader.at_eof()
    assert_true(reader.is_complete())


def test_a_body_read_until_close_accumulates_across_calls() raises:
    var reader = _reader(BodyMode.UNTIL_CLOSE)
    assert_equal(_drip(reader, "one two three"), "one two three")


def test_a_simple_chunked_body_decodes() raises:
    var reader = _reader(BodyMode.CHUNKED)
    assert_equal(_feed(reader, "5\r\nhello\r\n0\r\n\r\n"), "hello")
    assert_true(reader.is_complete())


def test_several_chunks_are_joined() raises:
    var reader = _reader(BodyMode.CHUNKED)
    assert_equal(
        _feed(reader, "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"), "hello world"
    )
    assert_true(reader.is_complete())


def test_a_chunked_body_arriving_one_byte_at_a_time_decodes() raises:
    var reader = _reader(BodyMode.CHUNKED)
    assert_equal(
        _drip(reader, "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"), "hello world"
    )
    assert_true(reader.is_complete())


def test_a_chunk_size_is_read_as_hex() raises:
    # A decoder that read it as decimal works for every chunk under ten bytes,
    # which is every chunk in a naive test.
    var reader = _reader(BodyMode.CHUNKED)
    var body = String()
    for _ in range(26):
        body += "x"
    assert_equal(_feed(reader, String("1a\r\n", body, "\r\n0\r\n\r\n")), body)


def test_an_uppercase_chunk_size_is_read_as_hex() raises:
    var reader = _reader(BodyMode.CHUNKED)
    var body = String()
    for _ in range(26):
        body += "x"
    assert_equal(_feed(reader, String("1A\r\n", body, "\r\n0\r\n\r\n")), body)


def test_a_chunked_body_with_no_chunks_decodes_to_nothing() raises:
    var reader = _reader(BodyMode.CHUNKED)
    assert_equal(_feed(reader, "0\r\n\r\n"), "")
    assert_true(reader.is_complete())


def test_chunk_extensions_are_discarded() raises:
    # Nobody sends these, so the only thing that matters is that a server which
    # does is still readable rather than being rejected for being unusual.
    var reader = _reader(BodyMode.CHUNKED)
    assert_equal(_feed(reader, "5;name=value\r\nhello\r\n0\r\n\r\n"), "hello")


def test_trailers_are_collected() raises:
    var reader = _reader(BodyMode.CHUNKED)
    assert_equal(
        _feed(reader, "5\r\nhello\r\n0\r\nX-Sum: abc\r\n\r\n"), "hello"
    )
    assert_true(reader.is_complete())
    assert_equal(reader.trailers["x-sum"], "abc")


def test_trailers_arriving_in_pieces_are_collected() raises:
    var reader = _reader(BodyMode.CHUNKED)
    assert_equal(
        _drip(reader, "5\r\nhello\r\n0\r\nX-A: 1\r\nX-B: 2\r\n\r\n"), "hello"
    )
    assert_equal(reader.trailers["x-a"], "1")
    assert_equal(reader.trailers["x-b"], "2")


def test_a_chunked_body_leaves_the_next_response_alone() raises:
    var reader = _reader(BodyMode.CHUNKED)
    var buf = ByteBuffer()
    buf.extend("5\r\nhello\r\n0\r\n\r\nHTTP/1.1 200 OK\r\n\r\n".as_bytes())
    var out = List[UInt8]()
    assert_false(reader.read_from(buf, out))
    assert_equal(String(StringSpan(from_utf8=Span(out))), "hello")
    assert_equal(
        String(StringSpan(from_utf8=buf.unread())), "HTTP/1.1 200 OK\r\n\r\n"
    )


def test_a_chunked_body_that_stops_before_the_terminal_chunk_is_an_error() raises:
    var reader = _reader(BodyMode.CHUNKED)
    _ = _feed(reader, "5\r\nhello\r\n")
    var raised = False
    try:
        reader.at_eof()
    except e:
        raised = True
        assert_true(is_remote_protocol_error(e))
    assert_true(raised)


def test_a_chunked_body_that_stops_mid_chunk_is_an_error() raises:
    var reader = _reader(BodyMode.CHUNKED)
    _ = _feed(reader, "5\r\nhel")
    var raised = False
    try:
        reader.at_eof()
    except e:
        raised = True
        assert_true(is_remote_protocol_error(e))
    assert_true(raised)


def test_a_chunk_size_that_is_not_hex_is_rejected() raises:
    _chunked_rejected("zz\r\nhello\r\n0\r\n\r\n")


def test_an_empty_chunk_size_is_rejected() raises:
    _chunked_rejected("\r\nhello\r\n0\r\n\r\n")


def test_a_chunk_longer_than_its_size_is_rejected() raises:
    # What a size line and the data disagreeing looks like on the wire, and the
    # smuggling shape a decoder that resynchronised on the next `\r\n` would let
    # through.
    _chunked_rejected("5\r\nhello world\r\n0\r\n\r\n")


def test_an_over_long_chunk_size_line_is_rejected() raises:
    # The bound has to fire on the bytes as they arrive. A server that sends a
    # size line and no newline is otherwise free to use all our memory.
    var text = String()
    for _ in range(2048):
        text += "0"
    _chunked_rejected(text)


def test_the_reader_reports_nothing_more_is_needed_when_the_body_ends() raises:
    var reader = _reader(BodyMode.CHUNKED)
    var buf = ByteBuffer()
    buf.extend("0\r\n\r\n".as_bytes())
    var out = List[UInt8]()
    assert_false(reader.read_from(buf, out))


def test_calling_at_eof_on_a_complete_body_is_harmless() raises:
    # The transport does not always know whether it already finished, and a
    # reader that raised here would turn a clean close into an error.
    var reader = _reader(BodyMode.LENGTH, 5)
    _ = _feed(reader, "hello")
    reader.at_eof()
    assert_true(reader.is_complete())
