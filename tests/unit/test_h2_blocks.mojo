"""Tests for header block reassembly across `CONTINUATION`.

Two of these matter more than the rest. One sends a block larger than the buffer
bound, which is the obvious attack. The other sends a long run of empty
`CONTINUATION` frames, which is the one that gets past an implementation that
only bounds the size, because empty frames never make the buffer grow.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from httpx._bytes import Bytes
from httpx._proto.h2.blocks import (
    DEFAULT_MAX_BLOCK_SIZE,
    DEFAULT_MAX_CONTINUATIONS,
    HeaderBlock,
)
from httpx._proto.h2.frames import (
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FrameHeader,
    FrameType,
)


def _frame(type: FrameType, flags: UInt8, stream_id: UInt32) -> FrameHeader:
    return FrameHeader(0, type, flags, stream_id)


def _fragment(size: Int, fill: UInt8) -> Bytes:
    var out = Bytes()
    for _ in range(size):
        out.append(fill)
    return out^


def test_a_block_that_fits_in_one_frame_is_done_when_that_frame_is() raises:
    var block = HeaderBlock()
    var payload = _fragment(20, 0xAB)
    var done = block.begin(
        _frame(FrameType.HEADERS, FLAG_END_HEADERS, 1), payload.as_span()
    )
    assert_true(done)
    assert_false(block.is_open())

    var taken = block.take()
    assert_equal(len(taken), 20)
    assert_equal(taken[0], 0xAB)


def test_a_block_carries_on_across_continuation_frames() raises:
    var block = HeaderBlock()
    var head = _fragment(10, 1)
    assert_false(block.begin(_frame(FrameType.HEADERS, 0, 3), head.as_span()))
    assert_true(block.is_open())
    assert_equal(block.stream_id(), 3)

    var middle = _fragment(10, 2)
    assert_false(
        block.extend(_frame(FrameType.CONTINUATION, 0, 3), middle.as_span())
    )

    var tail = _fragment(10, 3)
    assert_true(
        block.extend(
            _frame(FrameType.CONTINUATION, FLAG_END_HEADERS, 3),
            tail.as_span(),
        )
    )
    assert_false(block.is_open())

    var taken = block.take()
    assert_equal(len(taken), 30)
    assert_equal(taken[0], 1)
    assert_equal(taken[10], 2)
    assert_equal(taken[20], 3)


def test_taking_a_block_leaves_nothing_behind_for_the_next_one() raises:
    var block = HeaderBlock()
    var first = _fragment(10, 1)
    _ = block.begin(
        _frame(FrameType.HEADERS, FLAG_END_HEADERS, 1), first.as_span()
    )
    _ = block.take()
    assert_equal(block.stream_id(), 0)

    var second = _fragment(4, 2)
    _ = block.begin(
        _frame(FrameType.HEADERS, FLAG_END_HEADERS, 3), second.as_span()
    )
    var taken = block.take()
    assert_equal(len(taken), 4)


def test_nothing_but_a_continuation_may_arrive_while_a_block_is_open() raises:
    # RFC 9113 section 6.10. This is what makes the two bounds below mean
    # anything: without it a peer could hold a block open on one stream and
    # carry on doing whatever it liked on the others.
    var block = HeaderBlock()
    var head = _fragment(10, 1)
    _ = block.begin(_frame(FrameType.HEADERS, 0, 1), head.as_span())

    block.check_allows(_frame(FrameType.CONTINUATION, 0, 1))
    with assert_raises():
        block.check_allows(_frame(FrameType.DATA, 0, 1))
    with assert_raises():
        block.check_allows(_frame(FrameType.SETTINGS, 0, 0))
    with assert_raises():
        block.check_allows(_frame(FrameType.PING, 0, 0))


def test_a_continuation_on_another_stream_is_refused() raises:
    var block = HeaderBlock()
    var head = _fragment(10, 1)
    _ = block.begin(_frame(FrameType.HEADERS, 0, 1), head.as_span())
    with assert_raises():
        block.check_allows(_frame(FrameType.CONTINUATION, 0, 3))


def test_a_continuation_with_no_block_open_is_refused() raises:
    var block = HeaderBlock()
    with assert_raises():
        block.check_allows(_frame(FrameType.CONTINUATION, 0, 1))

    # And once a block has finished, the one after it is refused too.
    var head = _fragment(10, 1)
    _ = block.begin(
        _frame(FrameType.HEADERS, FLAG_END_HEADERS, 1), head.as_span()
    )
    with assert_raises():
        block.check_allows(_frame(FrameType.CONTINUATION, 0, 1))


def test_anything_may_arrive_when_no_block_is_open() raises:
    var block = HeaderBlock()
    block.check_allows(_frame(FrameType.DATA, FLAG_END_STREAM, 1))
    block.check_allows(_frame(FrameType.HEADERS, 0, 1))
    block.check_allows(_frame(FrameType.SETTINGS, 0, 0))


def test_a_block_over_the_size_bound_is_refused() raises:
    var block = HeaderBlock(max_size=100)
    var head = _fragment(60, 1)
    _ = block.begin(_frame(FrameType.HEADERS, 0, 1), head.as_span())

    var more = _fragment(41, 2)
    with assert_raises():
        _ = block.extend(_frame(FrameType.CONTINUATION, 0, 1), more.as_span())


def test_a_block_exactly_at_the_size_bound_is_allowed() raises:
    var block = HeaderBlock(max_size=100)
    var head = _fragment(100, 1)
    assert_true(
        block.begin(
            _frame(FrameType.HEADERS, FLAG_END_HEADERS, 1), head.as_span()
        )
    )
    assert_equal(len(block.take()), 100)


def test_a_single_frame_over_the_size_bound_is_refused() raises:
    var block = HeaderBlock(max_size=100)
    var head = _fragment(101, 1)
    with assert_raises():
        _ = block.begin(
            _frame(FrameType.HEADERS, FLAG_END_HEADERS, 1), head.as_span()
        )


def test_a_run_of_empty_continuations_is_refused() raises:
    # The one that matters. Every frame here is legal, costs the sender nine
    # octets, and adds nothing to the buffer, so a receiver that only bounds the
    # size would sit in this loop until something else gave out. This is
    # CVE-2024-27316 and the family around it.
    var block = HeaderBlock(max_continuations=8)
    var head = _fragment(4, 1)
    _ = block.begin(_frame(FrameType.HEADERS, 0, 1), head.as_span())

    var empty = Bytes()
    for _ in range(8):
        assert_false(
            block.extend(_frame(FrameType.CONTINUATION, 0, 1), empty.as_span())
        )

    with assert_raises():
        _ = block.extend(_frame(FrameType.CONTINUATION, 0, 1), empty.as_span())


def test_the_frame_count_starts_again_with_each_block() raises:
    var block = HeaderBlock(max_continuations=2)
    var head = _fragment(4, 1)
    var empty = Bytes()

    for _ in range(3):
        _ = block.begin(_frame(FrameType.HEADERS, 0, 1), head.as_span())
        _ = block.extend(_frame(FrameType.CONTINUATION, 0, 1), empty.as_span())
        _ = block.extend(
            _frame(FrameType.CONTINUATION, FLAG_END_HEADERS, 1),
            empty.as_span(),
        )
        assert_equal(len(block.take()), 4)


def test_taking_a_block_that_is_still_arriving_is_our_own_mistake() raises:
    var block = HeaderBlock()
    var head = _fragment(10, 1)
    _ = block.begin(_frame(FrameType.HEADERS, 0, 1), head.as_span())
    with assert_raises():
        _ = block.take()


def test_the_defaults_leave_room_for_anything_real() raises:
    # The size bound is on the compressed block, so it is well past what
    # SETTINGS_MAX_HEADER_LIST_SIZE would allow after decoding, and at the
    # default maximum frame size it is reached in five frames rather than
    # sixty four.
    assert_equal(DEFAULT_MAX_BLOCK_SIZE, 65536)
    assert_equal(DEFAULT_MAX_CONTINUATIONS, 64)
