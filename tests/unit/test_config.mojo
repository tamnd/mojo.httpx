"""Tests for the timeout configuration and the deadlines it produces.

The interesting part is the conversion. A `Timeout` is four numbers a person
wrote down, and a `Deadlines` is four instants a socket loop can compare
against, so the tests here are mostly about the boundary between the two: that
every phase keeps its own number, that an unset phase really means no limit
rather than a limit of zero, and that all four clocks start at the same moment.
"""

from std.testing import assert_equal, assert_raises, assert_true

from httpx._config import DEFAULT_TIMEOUT_SECONDS, Timeout
from httpx._exceptions import ErrorKind, is_invalid_argument
from httpx._io.deadline import NANOS_PER_MS


def test_the_default_timeout_is_five_seconds_on_every_phase() raises:
    var timeout = Timeout()
    assert_equal(timeout.connect.value(), DEFAULT_TIMEOUT_SECONDS)
    assert_equal(timeout.read.value(), DEFAULT_TIMEOUT_SECONDS)
    assert_equal(timeout.write.value(), DEFAULT_TIMEOUT_SECONDS)
    assert_equal(timeout.pool.value(), DEFAULT_TIMEOUT_SECONDS)


def test_one_number_covers_every_phase() raises:
    var timeout = Timeout.uniform(Optional[Float64](2.5))
    assert_equal(timeout.connect.value(), 2.5)
    assert_equal(timeout.read.value(), 2.5)
    assert_equal(timeout.write.value(), 2.5)
    assert_equal(timeout.pool.value(), 2.5)


def test_each_phase_keeps_its_own_number() raises:
    var timeout = Timeout(
        Optional[Float64](1.0),
        Optional[Float64](2.0),
        Optional[Float64](3.0),
        Optional[Float64](4.0),
    )
    assert_equal(timeout.connect.value(), 1.0)
    assert_equal(timeout.read.value(), 2.0)
    assert_equal(timeout.write.value(), 3.0)
    assert_equal(timeout.pool.value(), 4.0)


def test_one_phase_can_be_unlimited_while_the_others_are_not() raises:
    # What a caller downloading something large actually wants: no ceiling on
    # the read, and the usual protection everywhere else.
    var timeout = Timeout(
        Optional[Float64](5.0),
        None,
        Optional[Float64](5.0),
        Optional[Float64](5.0),
    )
    assert_true(timeout.connect)
    assert_true(not timeout.read)
    var deadlines = timeout.deadlines()
    assert_true(deadlines.connect.limited)
    assert_true(not deadlines.read.limited)


def test_a_disabled_timeout_limits_nothing() raises:
    var deadlines = Timeout.disabled().deadlines()
    assert_true(not deadlines.connect.limited)
    assert_true(not deadlines.read.limited)
    assert_true(not deadlines.write.limited)
    assert_true(not deadlines.pool.limited)


def test_a_zero_timeout_is_a_request_not_to_wait() raises:
    # Zero is how a caller asks for an attempt that either succeeds now or
    # fails, so it has to be accepted and it has to produce a deadline that has
    # already passed.
    var deadlines = Timeout.uniform(Optional[Float64](0.0)).deadlines()
    assert_true(deadlines.connect.expired())
    assert_true(deadlines.read.expired())


def test_a_negative_timeout_is_rejected() raises:
    with assert_raises():
        _ = Timeout.uniform(Optional[Float64](-1.0))


def test_a_negative_timeout_names_the_phase_it_came_from() raises:
    try:
        _ = Timeout(
            Optional[Float64](1.0),
            Optional[Float64](1.0),
            Optional[Float64](-0.5),
            Optional[Float64](1.0),
        )
        assert_true(False, "a negative write timeout should not be accepted")
    except e:
        assert_true(is_invalid_argument(e))
        assert_true("write" in String(e))


def test_the_four_deadlines_start_at_the_same_moment() raises:
    # The reason they are made together. Made one at a time, a request that
    # spent a second waiting for a connection would get a second longer to
    # connect, and nobody asked for that.
    var deadlines = Timeout.uniform(Optional[Float64](30.0)).deadlines()
    var spread = deadlines.pool.at_ns - deadlines.connect.at_ns
    assert_true(spread < UInt64(NANOS_PER_MS))


def test_each_deadline_carries_the_error_its_phase_should_raise() raises:
    var deadlines = Timeout().deadlines()
    assert_true(deadlines.connect.kind == ErrorKind.CONNECT_TIMEOUT)
    assert_true(deadlines.read.kind == ErrorKind.READ_TIMEOUT)
    assert_true(deadlines.write.kind == ErrorKind.WRITE_TIMEOUT)
    assert_true(deadlines.pool.kind == ErrorKind.POOL_TIMEOUT)


def test_a_timeout_prints_what_it_is() raises:
    var timeout = Timeout(
        Optional[Float64](1.0), None, Optional[Float64](3.0), None
    )
    var text = String(timeout)
    assert_true("connect=1.0" in text)
    assert_true("read=None" in text)
    assert_true("write=3.0" in text)
    assert_true("pool=None" in text)
