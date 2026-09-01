"""Tests for walking a body a chunk at a time.

Every expected value here was measured against httpx2 2.12.0 rather than
recalled, including the whole set of characters its line decoder treats as a line
break, which is Python's `str.splitlines` set and is longer than most people
expect.

Two kinds of test live here. The ones built on a body that is already in memory
check the chunking and the splitting. The ones built on `chunked_response`, which
hands the body over in pieces the test chose, check the part that only shows up
on a real connection: a character or a line break that arrives split across two
reads has to come out the same as one that did not.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from httpx._models.headers import Headers
from httpx._models.iterators import ByteChunks, LineChunks, TextChunks
from httpx._models.response import Response
from httpx._models.stream import ByteSource, erase_source


struct ChunkSource(ByteSource, Movable):
    """A body handed over in pieces the test picked."""

    var _chunks: List[List[UInt8]]
    var _at: Int
    var _trailers: Headers

    def __init__(
        out self,
        var chunks: List[List[UInt8]],
        var trailers: Headers = Headers(),
    ):
        self._chunks = chunks^
        self._at = 0
        self._trailers = trailers^

    def read_chunk(mut self) raises -> List[UInt8]:
        if self._at >= len(self._chunks):
            return List[UInt8]()
        var out = self._chunks[self._at].copy()
        self._at += 1
        return out^

    def close(mut self):
        self._at = len(self._chunks)

    def trailers(self) -> Headers:
        return self._trailers.copy()


def bytes_of(*values: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for value in values:
        out.append(UInt8(value))
    return out^


def body_of(text: StringSpan) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(text.as_bytes())
    return out^


def read_response(var body: List[UInt8]) raises -> Response:
    """A response whose body is already in memory."""
    return Response(200, String("OK"), String("HTTP/1.1"), Headers(), body^)


def chunked_response(var pieces: List[String]) raises -> Response:
    """A response whose body arrives in exactly the pieces given."""
    var chunks = List[List[UInt8]]()
    for piece in pieces:
        chunks.append(body_of(piece))
    return Response.streaming(200, erase_source(ChunkSource(chunks^)))


def collect_bytes(mut chunks: ByteChunks) raises -> List[String]:
    var out = List[String]()
    while chunks.has_next():
        var chunk = chunks.next()
        out.append(String(StringSpan(from_utf8=Span(chunk))))
    return out^


def collect_text(mut chunks: TextChunks) raises -> List[String]:
    var out = List[String]()
    while chunks.has_next():
        out.append(chunks.next())
    return out^


def collect_lines(mut lines: LineChunks) raises -> List[String]:
    var out = List[String]()
    while lines.has_next():
        out.append(lines.next())
    return out^


def joined(values: List[String]) -> String:
    """The values with a `|` between them, so a failure prints the whole shape.

    Comparing one string rather than looping over two lists means a wrong split
    shows both what was expected and what happened in the same message.
    """
    var out = String()
    for i in range(len(values)):
        if i > 0:
            out += "|"
        out += values[i]
    return out^


def test_a_size_splits_the_body_into_chunks_of_that_size() raises:
    var response = read_response(body_of("abcdefgh"))
    var chunks = response.iter_bytes(3)
    assert_equal(joined(collect_bytes(chunks)), "abc|def|gh")


def test_only_the_last_chunk_is_allowed_to_be_short() raises:
    var response = read_response(body_of("abcdef"))
    var chunks = response.iter_bytes(3)
    assert_equal(joined(collect_bytes(chunks)), "abc|def")


def test_a_size_larger_than_the_body_gives_one_chunk() raises:
    var response = read_response(body_of("ab"))
    var chunks = response.iter_bytes(64)
    assert_equal(joined(collect_bytes(chunks)), "ab")


def test_no_size_gives_the_body_as_it_arrives() raises:
    # A size of zero is httpx2's `chunk_size=None`: hand over whatever the source
    # produced without re-chunking it.
    var pieces = List[String]()
    pieces.append(String("one"))
    pieces.append(String("two"))
    var response = chunked_response(pieces^)
    var chunks = response.iter_bytes()
    assert_equal(joined(collect_bytes(chunks)), "one|two")


def test_a_size_reassembles_across_the_pieces_that_arrived() raises:
    var pieces = List[String]()
    pieces.append(String("ab"))
    pieces.append(String("cde"))
    pieces.append(String("fgh"))
    var response = chunked_response(pieces^)
    var chunks = response.iter_bytes(4)
    assert_equal(joined(collect_bytes(chunks)), "abcd|efgh")


def test_an_empty_body_yields_nothing() raises:
    # Not one empty chunk. The end of the body is `has_next` going false, and an
    # empty chunk would be a second way of saying it that a caller would have to
    # tell apart from a chunk that happened to be empty.
    var response = read_response(List[UInt8]())
    var chunks = response.iter_bytes(4)
    assert_false(chunks.has_next())
    assert_equal(len(collect_bytes(chunks)), 0)


def test_next_past_the_end_raises() raises:
    var response = read_response(body_of("ab"))
    var chunks = response.iter_bytes()
    _ = chunks.next()
    with assert_raises(contains="check has_next()"):
        _ = chunks.next()


def test_a_body_in_memory_can_be_iterated_more_than_once() raises:
    # `iter_bytes` on a read response re-reads what is sitting in memory, which
    # costs nothing and asks nothing of the connection. httpx2 does the same.
    var response = read_response(body_of("abcd"))
    var first = response.iter_bytes(2)
    assert_equal(joined(collect_bytes(first)), "ab|cd")
    var second = response.iter_bytes(3)
    assert_equal(joined(collect_bytes(second)), "abc|d")


def test_iter_raw_on_a_body_in_memory_refuses() raises:
    # The one place `iter_raw` and `iter_bytes` differ on a read response.
    # `iter_raw` is about the stream, and the stream is gone.
    var response = read_response(body_of("abcd"))
    with assert_raises(contains="already been streamed"):
        _ = response.iter_raw()


def test_a_stream_can_only_be_read_once() raises:
    var pieces = List[String]()
    pieces.append(String("abcd"))
    var response = chunked_response(pieces^)
    var chunks = response.iter_raw()
    assert_equal(joined(collect_bytes(chunks)), "abcd")
    with assert_raises(contains="already been streamed"):
        _ = response.iter_raw()


def test_a_closed_response_has_nothing_to_read() raises:
    var pieces = List[String]()
    pieces.append(String("abcd"))
    var response = chunked_response(pieces^)
    response.close()
    with assert_raises(contains="closed"):
        _ = response.iter_raw()


def test_content_before_the_body_is_read_raises() raises:
    var pieces = List[String]()
    pieces.append(String("abcd"))
    var response = chunked_response(pieces^)
    with assert_raises(contains="has not been read"):
        _ = len(response.content())


def test_read_pulls_the_whole_body_in() raises:
    var pieces = List[String]()
    pieces.append(String("ab"))
    pieces.append(String("cd"))
    var response = chunked_response(pieces^)
    response.read()
    assert_equal(len(response.content()), 4)
    assert_true(response.is_closed)
    assert_equal(response.text(), "abcd")


def test_read_twice_is_the_same_as_read_once() raises:
    # Both a redirect and an auth flow end up reading a response that may already
    # have been read, and making the second call an error would put a check in
    # front of every one of them.
    var pieces = List[String]()
    pieces.append(String("abcd"))
    var response = chunked_response(pieces^)
    response.read()
    response.read()
    assert_equal(response.text(), "abcd")


def test_text_chunks_are_counted_in_characters() raises:
    # Characters rather than bytes, which is what httpx2 counts. Measured there:
    # `iter_text(3)` over "héllo wörld" gives these four pieces.
    var response = read_response(body_of("héllo wörld"))
    var chunks = response.iter_text(3)
    assert_equal(joined(collect_text(chunks)), "hél|lo |wör|ld")


def test_a_text_chunk_of_one_is_one_character_however_wide() raises:
    var response = read_response(body_of("日本語"))
    var chunks = response.iter_text(1)
    assert_equal(joined(collect_text(chunks)), "日|本|語")


def test_no_size_gives_the_text_as_it_arrives() raises:
    var pieces = List[String]()
    pieces.append(String("one "))
    pieces.append(String("two"))
    var response = chunked_response(pieces^)
    var chunks = response.iter_text()
    assert_equal(joined(collect_text(chunks)), "one |two")


def test_a_character_split_across_two_reads_survives() raises:
    # The reason `iter_text` is not `decode(chunk)` in a loop. Without holding
    # the tail back, this would come out as two replacement characters, and
    # which characters broke would depend on how the server sized its writes.
    var first = List[UInt8]()
    first.append(0x68)
    first.append(0xC3)
    var second = List[UInt8]()
    second.append(0xA9)
    second.append(0x69)
    var chunks = List[List[UInt8]]()
    chunks.append(first^)
    chunks.append(second^)
    var response = Response.streaming(200, erase_source(ChunkSource(chunks^)))
    var text = response.iter_text()
    assert_equal(joined(collect_text(text)), "h|éi")


def test_a_character_cut_off_by_the_end_of_the_body_is_replaced() raises:
    # The other side of holding a tail back: if the rest never comes, the broken
    # bytes have to become a replacement character rather than disappearing.
    var response = read_response(bytes_of(0x68, 0xC3))
    var chunks = response.iter_text()
    assert_equal(joined(collect_text(chunks)), "h|\uFFFD")


def test_an_empty_body_yields_no_text() raises:
    var response = read_response(List[UInt8]())
    var chunks = response.iter_text(4)
    assert_false(chunks.has_next())


def test_text_uses_the_declared_charset() raises:
    var headers = Headers()
    headers.append("content-type", "text/plain; charset=iso-8859-1")
    var response = Response(
        200,
        String("OK"),
        String("HTTP/1.1"),
        headers^,
        bytes_of(0x63, 0x61, 0x66, 0xE9),
    )
    var chunks = response.iter_text(2)
    assert_equal(joined(collect_text(chunks)), "ca|fé")


def test_utf16_takes_its_byte_order_from_the_first_read() raises:
    # The mark is only in the first chunk, so the order has to be settled once at
    # the front and remembered. A later chunk decoded on its own would guess.
    var first = bytes_of(0xFE, 0xFF, 0x00, 0x68)
    var second = bytes_of(0x00, 0x69)
    var chunks = List[List[UInt8]]()
    chunks.append(first^)
    chunks.append(second^)
    var headers = Headers()
    headers.append("content-type", "text/plain; charset=utf-16")
    var response = Response.streaming(
        200,
        erase_source(ChunkSource(chunks^)),
        String("OK"),
        String("HTTP/1.1"),
        headers^,
    )
    var text = response.iter_text()
    assert_equal(joined(collect_text(text)), "h|i")


def test_a_utf16_unit_split_across_two_reads_survives() raises:
    var first = bytes_of(0x68, 0x00, 0x69)
    var second = bytes_of(0x00)
    var chunks = List[List[UInt8]]()
    chunks.append(first^)
    chunks.append(second^)
    var headers = Headers()
    headers.append("content-type", "text/plain; charset=utf-16le")
    var response = Response.streaming(
        200,
        erase_source(ChunkSource(chunks^)),
        String("OK"),
        String("HTTP/1.1"),
        headers^,
    )
    var text = response.iter_text()
    assert_equal(joined(collect_text(text)), "h|i")


def test_a_utf16_surrogate_pair_split_across_two_reads_survives() raises:
    # U+1F600, which is two units in UTF-16. Cutting between them and decoding
    # the first on its own would give a replacement character and then a second
    # one for the orphan half.
    var first = bytes_of(0x3D, 0xD8)
    var second = bytes_of(0x00, 0xDE)
    var chunks = List[List[UInt8]]()
    chunks.append(first^)
    chunks.append(second^)
    var headers = Headers()
    headers.append("content-type", "text/plain; charset=utf-16le")
    var response = Response.streaming(
        200,
        erase_source(ChunkSource(chunks^)),
        String("OK"),
        String("HTTP/1.1"),
        headers^,
    )
    var text = response.iter_text()
    assert_equal(joined(collect_text(text)), "😀")


def test_lines_are_split_on_every_terminator_and_keep_none() raises:
    # Measured: httpx2 gives ['a','b','c','d','e'] for this body.
    var response = read_response(body_of("a\nb\r\nc\rd\ne"))
    var lines = response.iter_lines()
    assert_equal(joined(collect_lines(lines)), "a|b|c|d|e")


def test_a_trailing_terminator_does_not_make_an_empty_last_line() raises:
    var response = read_response(body_of("a\nb\n"))
    var lines = response.iter_lines()
    assert_equal(joined(collect_lines(lines)), "a|b")


def test_a_line_with_no_terminator_is_still_a_line() raises:
    var response = read_response(body_of("no terminator"))
    var lines = response.iter_lines()
    assert_equal(joined(collect_lines(lines)), "no terminator")


def test_an_empty_body_has_no_lines() raises:
    var response = read_response(List[UInt8]())
    var lines = response.iter_lines()
    assert_false(lines.has_next())


def test_consecutive_terminators_give_empty_lines() raises:
    var response = read_response(body_of("\n\n"))
    var lines = response.iter_lines()
    assert_equal(len(collect_lines(lines)), 2)
    var again = response.iter_lines()
    assert_equal(joined(collect_lines(again)), "|")


def test_a_body_ending_in_a_carriage_return_gives_one_line() raises:
    var response = read_response(body_of("a\r"))
    var lines = response.iter_lines()
    assert_equal(joined(collect_lines(lines)), "a")


def test_a_carriage_return_and_newline_are_one_break() raises:
    var response = read_response(body_of("a\r\nb"))
    var lines = response.iter_lines()
    assert_equal(joined(collect_lines(lines)), "a|b")


def test_a_carriage_return_split_from_its_newline_is_still_one_break() raises:
    # The reason a trailing carriage return is held back rather than treated as a
    # break straight away. A server that flushed between the two bytes would
    # otherwise turn one line ending into two lines.
    var pieces = List[String]()
    pieces.append(String("a\r"))
    pieces.append(String("\nb"))
    var response = chunked_response(pieces^)
    var lines = response.iter_lines()
    assert_equal(joined(collect_lines(lines)), "a|b")


def test_a_carriage_return_at_the_very_end_is_a_break() raises:
    var pieces = List[String]()
    pieces.append(String("a\r"))
    var response = chunked_response(pieces^)
    var lines = response.iter_lines()
    assert_equal(joined(collect_lines(lines)), "a")


def test_the_vertical_tab_and_form_feed_end_a_line() raises:
    # Nobody expects these, but Python's `splitlines` breaks on them and httpx2
    # reproduces `splitlines`, so parity means breaking on them too.
    var response = read_response(body_of("a\x0bb\x0cc"))
    var lines = response.iter_lines()
    assert_equal(joined(collect_lines(lines)), "a|b|c")


def test_the_information_separators_end_a_line() raises:
    var response = read_response(body_of("a\x1cb\x1dc\x1ed"))
    var lines = response.iter_lines()
    assert_equal(joined(collect_lines(lines)), "a|b|c|d")


def test_the_next_line_character_ends_a_line() raises:
    # U+0085, which is two bytes in UTF-8 and so cannot be found by looking at
    # one byte at a time.
    var response = read_response(body_of("a\u0085b"))
    var lines = response.iter_lines()
    assert_equal(joined(collect_lines(lines)), "a|b")


def test_the_line_and_paragraph_separators_end_a_line() raises:
    var response = read_response(body_of("a\u2028b\u2029c"))
    var lines = response.iter_lines()
    assert_equal(joined(collect_lines(lines)), "a|b|c")


def test_a_multibyte_separator_split_across_two_reads_survives() raises:
    # U+2028 is three bytes, and this cuts it after the first one. Built from
    # bytes rather than from a string because half of a separator is not a
    # string.
    var chunks = List[List[UInt8]]()
    chunks.append(bytes_of(0x61, 0xE2))
    chunks.append(bytes_of(0x80, 0xA8, 0x62))
    var response = Response.streaming(200, erase_source(ChunkSource(chunks^)))
    var lines = response.iter_lines()
    assert_equal(joined(collect_lines(lines)), "a|b")


def test_lines_come_out_as_they_arrive_rather_than_at_the_end() raises:
    # The point of streaming lines at all. A body that has not finished should
    # still hand over the lines that have, which is what makes a long lived
    # event stream usable.
    var pieces = List[String]()
    pieces.append(String("first\nsec"))
    pieces.append(String("ond\nthird"))
    var response = chunked_response(pieces^)
    var lines = response.iter_lines()
    assert_true(lines.has_next())
    assert_equal(lines.next(), "first")
    assert_equal(lines.next(), "second")
    assert_equal(lines.next(), "third")
    assert_false(lines.has_next())


def test_lines_use_the_declared_charset() raises:
    var headers = Headers()
    headers.append("content-type", "text/plain; charset=iso-8859-1")
    var response = Response(
        200,
        String("OK"),
        String("HTTP/1.1"),
        headers^,
        bytes_of(0xE9, 0x0A, 0xE8),
    )
    var lines = response.iter_lines()
    assert_equal(joined(collect_lines(lines)), "é|è")


def test_streaming_lines_can_only_be_read_once() raises:
    var pieces = List[String]()
    pieces.append(String("a\nb"))
    var response = chunked_response(pieces^)
    var lines = response.iter_lines()
    assert_equal(joined(collect_lines(lines)), "a|b")
    with assert_raises(contains="already been streamed"):
        _ = response.iter_lines()


def test_a_streaming_response_starts_open_and_unconsumed() raises:
    var pieces = List[String]()
    pieces.append(String("a"))
    var response = chunked_response(pieces^)
    assert_false(response.is_closed)
    assert_false(response.is_stream_consumed)
    _ = response.iter_raw()
    assert_true(response.is_stream_consumed)


def test_a_response_built_with_a_body_starts_read_and_closed() raises:
    var response = read_response(body_of("abcd"))
    assert_true(response.is_closed)
    assert_true(response.is_stream_consumed)
    assert_equal(len(response.content()), 4)
