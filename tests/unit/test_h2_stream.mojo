"""Tests for the stream state machine, identifiers and the reset bound.

The state tests are mostly about what a server may not do: answer a stream that
was never opened, keep sending after it said it was finished, or send a third
header block where the protocol has room for two. Those all pass on an
implementation that only looks at flags, which is why the states are written out.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from httpx._proto.h2.frames import DEFAULT_WINDOW_SIZE
from httpx._proto.h2.stream import (
    DEFAULT_MAX_CONSECUTIVE_RESETS,
    H2Stream,
    MAX_STREAM_ID,
    ResetTracker,
    StreamIds,
    StreamState,
)


def test_a_new_stream_is_idle_with_the_default_windows() raises:
    var stream = H2Stream(1)
    assert_equal(stream.id, 1)
    assert_true(stream.state == StreamState.IDLE)
    assert_equal(stream.send.available, DEFAULT_WINDOW_SIZE)
    assert_equal(stream.recv.capacity(), DEFAULT_WINDOW_SIZE)
    assert_equal(stream.header_blocks, 0)


def test_a_request_with_a_body_opens_the_stream() raises:
    var stream = H2Stream(1)
    stream.send_headers(end_stream=False)
    assert_true(stream.state == StreamState.OPEN)

    stream.send_data(100, end_stream=False)
    assert_true(stream.state == StreamState.OPEN)
    assert_equal(stream.send.available, DEFAULT_WINDOW_SIZE - 100)

    stream.send_data(50, end_stream=True)
    assert_true(stream.state == StreamState.HALF_CLOSED_LOCAL)


def test_a_request_with_no_body_half_closes_at_once() raises:
    var stream = H2Stream(1)
    stream.send_headers(end_stream=True)
    assert_true(stream.state == StreamState.HALF_CLOSED_LOCAL)


def test_a_whole_exchange_ends_closed() raises:
    var stream = H2Stream(1)
    stream.send_headers(end_stream=True)
    stream.recv_headers(end_stream=False)
    assert_true(stream.state == StreamState.HALF_CLOSED_LOCAL)

    stream.recv_data(500, end_stream=False)
    stream.recv_data(0, end_stream=True)
    assert_true(stream.state == StreamState.CLOSED)


def test_a_server_that_answers_early_half_closes_its_own_side() raises:
    # Normal for a rejection. There is no reason to read a large upload only to
    # refuse it, so the response arrives while the request body is still going
    # out.
    var stream = H2Stream(1)
    stream.send_headers(end_stream=False)
    stream.recv_headers(end_stream=True)
    assert_true(stream.state == StreamState.HALF_CLOSED_REMOTE)


def test_sending_a_request_twice_on_one_stream_is_refused() raises:
    var stream = H2Stream(1)
    stream.send_headers(end_stream=False)
    with assert_raises():
        stream.send_headers(end_stream=False)


def test_sending_a_body_before_the_headers_is_refused() raises:
    var stream = H2Stream(1)
    with assert_raises():
        stream.send_data(10, end_stream=False)


def test_sending_a_body_after_the_stream_is_finished_is_refused() raises:
    var stream = H2Stream(1)
    stream.send_headers(end_stream=True)
    with assert_raises():
        stream.send_data(10, end_stream=False)


def test_sending_more_than_the_stream_window_holds_is_refused() raises:
    var stream = H2Stream(1, send_window=100)
    stream.send_headers(end_stream=False)
    stream.send_data(100, end_stream=False)
    with assert_raises():
        stream.send_data(1, end_stream=False)


def test_a_response_on_a_stream_nothing_was_asked_on_is_refused() raises:
    var stream = H2Stream(1)
    with assert_raises():
        stream.recv_headers(end_stream=False)


def test_body_bytes_on_a_stream_nothing_was_asked_on_are_refused() raises:
    var stream = H2Stream(1)
    with assert_raises():
        stream.recv_data(10, end_stream=False)


def test_a_server_that_carries_on_after_ending_the_stream_is_refused() raises:
    var stream = H2Stream(1)
    stream.send_headers(end_stream=False)
    stream.recv_headers(end_stream=True)
    with assert_raises():
        stream.recv_data(10, end_stream=False)

    var other = H2Stream(3)
    other.send_headers(end_stream=False)
    other.recv_headers(end_stream=True)
    with assert_raises():
        other.recv_headers(end_stream=False)


def test_a_response_on_a_reset_stream_is_refused() raises:
    var stream = H2Stream(1)
    stream.send_headers(end_stream=True)
    stream.reset()
    assert_true(stream.state == StreamState.CLOSED)
    with assert_raises():
        stream.recv_headers(end_stream=False)


def test_trailers_are_allowed_and_a_third_block_is_not() raises:
    # RFC 9113 section 8.1 has room for the response headers and then trailers.
    # Without the count a third block would quietly replace the response.
    var stream = H2Stream(1)
    stream.send_headers(end_stream=True)
    stream.recv_headers(end_stream=False)
    assert_equal(stream.header_blocks, 1)

    stream.recv_data(10, end_stream=False)
    stream.recv_headers(end_stream=False)
    assert_equal(stream.header_blocks, 2)

    with assert_raises():
        stream.recv_headers(end_stream=False)


def test_body_bytes_are_charged_even_on_a_stream_that_has_ended() raises:
    # The frame spent connection window at the sender whether or not we keep it,
    # and a receiver that skipped the accounting would be out of step with the
    # sender for the rest of the connection.
    var stream = H2Stream(1, recv_window=1000)
    stream.send_headers(end_stream=False)
    stream.recv_headers(end_stream=True)

    with assert_raises():
        stream.recv_data(400, end_stream=False)
    assert_equal(stream.recv.allowed(), 600)


def test_receiving_more_than_the_stream_window_holds_is_refused() raises:
    var stream = H2Stream(1, recv_window=100)
    stream.send_headers(end_stream=True)
    stream.recv_headers(end_stream=False)
    with assert_raises():
        stream.recv_data(101, end_stream=False)


def test_our_identifiers_are_odd_and_go_up_by_two() raises:
    var ids = StreamIds()
    assert_equal(ids.highest(), 0)
    assert_equal(ids.take(), 1)
    assert_equal(ids.take(), 3)
    assert_equal(ids.take(), 5)
    assert_equal(ids.highest(), 5)


def test_an_identifier_we_have_not_opened_is_refused() raises:
    var ids = StreamIds()
    _ = ids.take()
    _ = ids.take()
    ids.check_named(1)
    ids.check_named(3)
    with assert_raises():
        ids.check_named(5)
    with assert_raises():
        ids.check_named(99)


def test_an_even_identifier_is_refused() raises:
    # Even ones are streams the server opened, and the only way it gets one is
    # a pushed stream, which we turn off in our own SETTINGS.
    var ids = StreamIds()
    _ = ids.take()
    _ = ids.take()
    _ = ids.take()
    with assert_raises():
        ids.check_named(2)


def test_stream_zero_where_a_stream_was_expected_is_refused() raises:
    var ids = StreamIds()
    _ = ids.take()
    with assert_raises():
        ids.check_named(0)


def test_a_connection_that_runs_out_of_identifiers_says_so() raises:
    # Walking there two at a time would take a billion turns, so start near the
    # end. The pool asks rather than being told, because running out is not a
    # failed request, it is a connection that has finished its useful life.
    var ids = StreamIds(UInt32(MAX_STREAM_ID) - 2)
    assert_false(ids.exhausted())

    assert_equal(ids.take(), UInt32(MAX_STREAM_ID) - 2)
    assert_equal(ids.take(), UInt32(MAX_STREAM_ID))

    assert_true(ids.exhausted())
    assert_equal(ids.highest(), UInt32(MAX_STREAM_ID))
    with assert_raises():
        _ = ids.take()


def test_a_run_of_resets_with_nothing_getting_through_is_refused() raises:
    # The mirror of CVE-2023-44487. A server that resets everything and a client
    # that keeps opening more streams is a loop that costs both sides and
    # finishes nothing.
    var tracker = ResetTracker(max_consecutive=4)
    for i in range(4):
        tracker.record_reset()
        assert_equal(tracker.consecutive(), i + 1)
    with assert_raises():
        tracker.record_reset()


def test_one_stream_getting_through_clears_the_run() raises:
    var tracker = ResetTracker(max_consecutive=4)
    for _ in range(20):
        tracker.record_reset()
        tracker.record_reset()
        tracker.record_reset()
        tracker.record_success()
        assert_equal(tracker.consecutive(), 0)


def test_the_reset_bound_has_a_default() raises:
    var tracker = ResetTracker()
    assert_equal(tracker.max_consecutive, DEFAULT_MAX_CONSECUTIVE_RESETS)
