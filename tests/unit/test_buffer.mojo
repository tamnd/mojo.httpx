"""Tests for the connection read buffer.

Most of these are about what happens across several reads, because a buffer that
only ever sees a whole message at once is trivially correct and is not the case
that breaks. The compaction test is the one worth reading: it is the difference
between a client that streams a large body in linear time and one that does not.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._io.buffer import ByteBuffer


def _text(bytes: List[UInt8]) raises -> String:
    return String(StringSpan(from_utf8=Span(bytes)))


def _span_text[o: ImmOrigin](bytes: Span[UInt8, o]) raises -> String:
    return String(StringSpan(from_utf8=bytes))


def test_an_empty_buffer_has_nothing_unread() raises:
    var buffer = ByteBuffer()
    assert_equal(len(buffer), 0)
    assert_true(buffer.is_empty())
    assert_equal(buffer.find("x".as_bytes()), -1)


def test_bytes_arrive_and_can_be_read_without_being_consumed() raises:
    # Looking is not taking. The parser has to be able to decide it does not yet
    # have a whole message and leave everything where it was.
    var buffer = ByteBuffer()
    buffer.extend("HTTP/1.1 200".as_bytes())
    assert_equal(len(buffer), 12)
    assert_equal(_span_text(buffer.unread()), "HTTP/1.1 200")
    assert_equal(len(buffer), 12)


def test_a_message_that_arrives_in_pieces_reads_as_one() raises:
    # The case the whole type exists for. The network decides where the breaks
    # fall and the parser must not be able to tell.
    var buffer = ByteBuffer()
    buffer.extend("HTTP/1.1 ".as_bytes())
    assert_equal(buffer.find("\r\n".as_bytes()), -1)
    buffer.extend("200 OK\r\n".as_bytes())
    assert_equal(buffer.find("\r\n".as_bytes()), 15)
    assert_equal(_span_text(buffer.unread()), "HTTP/1.1 200 OK\r\n")


def test_consuming_moves_the_cursor_rather_than_the_bytes() raises:
    var buffer = ByteBuffer()
    buffer.extend("one\r\ntwo\r\n".as_bytes())
    buffer.consume(5)
    assert_equal(len(buffer), 5)
    assert_equal(_span_text(buffer.unread()), "two\r\n")


def test_an_offset_is_relative_to_what_is_unread() raises:
    # So a caller can pass what `find` returned straight to `take` without
    # knowing or caring where the cursor happens to be.
    var buffer = ByteBuffer()
    buffer.extend("skip me\r\nkeep me\r\n".as_bytes())
    buffer.consume(9)
    assert_equal(buffer.find("\r\n".as_bytes()), 7)
    assert_equal(_text(buffer.take(7)), "keep me")


def test_taking_more_than_is_there_takes_what_there_is() raises:
    # A parser that has been told the body is a thousand bytes still has to cope
    # with the two hundred that have arrived so far.
    var buffer = ByteBuffer()
    buffer.extend("short".as_bytes())
    assert_equal(_text(buffer.take(1000)), "short")
    assert_true(buffer.is_empty())


def test_taking_copies_so_the_next_read_cannot_move_it() raises:
    # A span into the buffer would be a use after move the first time a response
    # arrives in two pieces, because the compaction below shifts the tail.
    var buffer = ByteBuffer()
    buffer.extend("body".as_bytes())
    var taken = buffer.take(4)
    buffer.extend("something else entirely".as_bytes())
    assert_equal(_text(taken), "body")


def test_peeking_past_the_end_gives_zero_rather_than_trapping() raises:
    # Every caller is a parser that has already checked the length. A trap here
    # would turn a parser bug into a crash instead of a failing assertion.
    var buffer = ByteBuffer()
    buffer.extend("ab".as_bytes())
    assert_equal(buffer.peek(0), UInt8(ord("a")))
    assert_equal(buffer.peek(1), UInt8(ord("b")))
    assert_equal(buffer.peek(2), UInt8(0))
    assert_equal(buffer.peek(1000), UInt8(0))


def test_consuming_everything_empties_the_buffer() raises:
    var buffer = ByteBuffer()
    buffer.extend("all of it".as_bytes())
    buffer.consume(9)
    assert_true(buffer.is_empty())
    assert_equal(len(buffer), 0)


def test_the_buffer_compacts_once_the_consumed_half_earns_it() raises:
    # The threshold is what keeps this amortised. Compacting on every consume
    # copies the remaining bytes once per parsed line, which is quadratic in the
    # size of a response head.
    var buffer = ByteBuffer()
    buffer.extend("0123456789".as_bytes())
    # Four of ten consumed, under half, so the tail stays where it is.
    buffer.consume(4)
    assert_equal(_span_text(buffer.unread()), "456789")
    # Six of ten, over half, so the tail moves to the front. The visible answer
    # is the same either way, which is the point: compaction is invisible.
    buffer.consume(2)
    assert_equal(_span_text(buffer.unread()), "6789")
    buffer.extend("ab".as_bytes())
    assert_equal(_span_text(buffer.unread()), "6789ab")


def test_a_long_stream_read_in_small_pieces_stays_correct() raises:
    # Drives the compaction path many times over. What is being checked is that
    # no byte is lost or duplicated when the tail keeps moving under the cursor.
    var buffer = ByteBuffer()
    var expected = String()
    for i in range(500):
        var piece = String("chunk", i, ";")
        buffer.extend(piece.as_bytes())
        expected += piece
    var seen = String()
    while not buffer.is_empty():
        var at = buffer.find(";".as_bytes())
        seen += _text(buffer.take(at + 1))
    assert_equal(seen, expected)


def test_clearing_keeps_the_buffer_usable() raises:
    # Called between requests on a pooled connection, which is what makes the
    # steady state free of allocation.
    var buffer = ByteBuffer()
    buffer.extend("leftovers".as_bytes())
    buffer.consume(4)
    buffer.clear()
    assert_true(buffer.is_empty())
    buffer.extend("next request".as_bytes())
    assert_equal(_span_text(buffer.unread()), "next request")


def test_an_empty_needle_matches_at_the_cursor() raises:
    # Matching the convention in _bytes.index_of_span, which is what makes a
    # loop over successive matches terminate rather than spin.
    var buffer = ByteBuffer()
    buffer.extend("abc".as_bytes())
    assert_equal(buffer.find("".as_bytes()), 0)


def test_a_needle_that_straddles_two_reads_is_still_found() raises:
    # The header terminator arriving split across two packets is a real thing
    # that happens, and a parser that misses it hangs waiting for a delimiter
    # that already went past.
    var buffer = ByteBuffer()
    buffer.extend("headers\r".as_bytes())
    assert_equal(buffer.find("\r\n\r\n".as_bytes()), -1)
    buffer.extend("\n\r\n".as_bytes())
    assert_equal(buffer.find("\r\n\r\n".as_bytes()), 7)


def test_a_buffer_can_be_copied_with_its_cursor() raises:
    var buffer = ByteBuffer()
    buffer.extend("abcdef".as_bytes())
    buffer.consume(2)
    var copy = buffer.copy()
    assert_equal(_span_text(copy.unread()), "cdef")
    assert_false(copy.is_empty())
