"""Tests for the flow control windows.

The cases worth writing down are the ones where the arithmetic is legal and the
meaning is not. A window that goes negative is fine, a window that goes over
2^31 - 1 is an error, and a receive window that goes negative is the peer having
sent more than it was allowed. Those three look almost the same on paper.
"""

from std.testing import assert_equal, assert_raises, assert_true

from httpx._proto.h2.frames import DEFAULT_WINDOW_SIZE, MAX_WINDOW
from httpx._proto.h2.window import MIN_WINDOW, ReceiveWindow, SendWindow


def test_a_fresh_window_is_the_size_the_rfc_starts_at() raises:
    var send = SendWindow()
    assert_equal(send.available, DEFAULT_WINDOW_SIZE)

    var recv = ReceiveWindow()
    assert_equal(recv.capacity(), DEFAULT_WINDOW_SIZE)
    assert_equal(recv.allowed(), DEFAULT_WINDOW_SIZE)
    assert_equal(recv.outstanding(), 0)


def test_a_window_allows_what_fits_and_no_more() raises:
    var window = SendWindow(100)
    assert_equal(window.allows(40), 40)
    assert_equal(window.allows(100), 100)
    assert_equal(window.allows(1000), 100)


def test_an_empty_window_allows_nothing() raises:
    var window = SendWindow(0)
    assert_equal(window.allows(1), 0)
    assert_equal(window.allows(0), 0)


def test_a_negative_window_allows_nothing_rather_than_a_negative_amount() raises:
    # A caller that took the arithmetic at face value here would be told to send
    # a negative number of bytes, which in practice means an underflow somewhere
    # further along.
    var window = SendWindow(0)
    window.resize(-500)
    assert_equal(window.available, -500)
    assert_equal(window.allows(100), 0)


def test_sending_takes_from_the_window() raises:
    var window = SendWindow(100)
    window.consume(30)
    assert_equal(window.available, 70)
    window.consume(70)
    assert_equal(window.available, 0)


def test_sending_more_than_the_window_holds_is_our_own_mistake() raises:
    var window = SendWindow(100)
    with assert_raises():
        window.consume(101)


def test_a_window_update_opens_the_window() raises:
    var window = SendWindow(100)
    window.consume(100)
    window.increase(65535)
    assert_equal(window.available, 65535)


def test_a_window_update_up_to_the_ceiling_is_allowed() raises:
    var window = SendWindow(0)
    window.increase(MAX_WINDOW)
    assert_equal(window.available, MAX_WINDOW)


def test_a_window_update_one_past_the_ceiling_is_refused() raises:
    var window = SendWindow(1)
    with assert_raises():
        window.increase(MAX_WINDOW)


def test_a_new_initial_size_shifts_the_window_rather_than_setting_it() raises:
    # The distinction is the whole of RFC 9113 section 6.9.2. Setting would
    # throw away octets the peer has already granted and not yet been charged
    # for, and the two sides would disagree by that amount from then on.
    var window = SendWindow(65535)
    window.consume(20000)
    assert_equal(window.available, 45535)

    window.resize(1048576 - 65535)
    assert_equal(window.available, 45535 + 1048576 - 65535)


def test_lowering_the_initial_size_can_leave_a_window_owing() raises:
    var window = SendWindow(65535)
    window.consume(65535)
    window.resize(-60000)
    assert_equal(window.available, -60000)

    # And the debt has to be paid off before anything moves again.
    assert_equal(window.allows(1), 0)
    window.increase(60000)
    assert_equal(window.available, 0)
    window.increase(10)
    assert_equal(window.allows(100), 10)


def test_a_resize_past_either_end_of_the_range_is_refused() raises:
    var high = SendWindow(1)
    with assert_raises():
        high.resize(MAX_WINDOW)

    var low = SendWindow(0)
    with assert_raises():
        low.resize(MIN_WINDOW - 1)


def test_receiving_takes_from_what_the_peer_was_allowed() raises:
    var window = ReceiveWindow(1000)
    window.record(400)
    assert_equal(window.allowed(), 600)
    window.record(600)
    assert_equal(window.allowed(), 0)


def test_a_peer_that_sends_more_than_it_was_allowed_is_refused() raises:
    # Without this the advertised window is a suggestion, and a peer that
    # ignores it can push as much as it likes into a client that keeps
    # buffering because it never checked.
    var window = ReceiveWindow(1000)
    window.record(1000)
    with assert_raises():
        window.record(1)


def test_nothing_is_returned_until_half_the_window_is_consumed() raises:
    var window = ReceiveWindow(1000)
    window.record(600)
    assert_equal(window.restore(400), 0)
    assert_equal(window.outstanding(), 400)
    assert_equal(window.allowed(), 400)

    assert_equal(window.restore(100), 500)
    assert_equal(window.outstanding(), 0)
    assert_equal(window.allowed(), 900)


def test_what_is_returned_is_everything_that_had_piled_up() raises:
    var window = ReceiveWindow(1000)
    window.record(1000)
    for _ in range(4):
        assert_equal(window.restore(100), 0)
    assert_equal(window.restore(100), 500)
    assert_equal(window.allowed(), 500)


def test_a_single_large_read_returns_straight_away() raises:
    var window = ReceiveWindow(1000)
    window.record(800)
    assert_equal(window.restore(800), 800)
    assert_equal(window.allowed(), 1000)


def test_returning_window_lets_the_peer_send_again() raises:
    var window = ReceiveWindow(1000)
    window.record(1000)
    with assert_raises():
        window.record(1)

    _ = window.restore(1000)
    window.record(1000)
    assert_equal(window.allowed(), 0)
