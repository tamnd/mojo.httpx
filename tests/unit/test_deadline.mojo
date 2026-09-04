"""Tests for deadlines.

The timing here is deliberately coarse. A test that asserts a deadline fires
within a millisecond fails on a loaded machine and teaches everybody to rerun
the suite until it passes, which is worse than not having the test. What is
asserted instead is the shape: a deadline in the future has not passed, one in
the past has, the milliseconds left never mean wait forever, and the kind that
comes back names the phase the deadline was made for.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from httpx._exceptions import (
    ErrorKind,
    is_connect_timeout,
    is_pool_timeout,
    is_read_timeout,
    is_timeout,
    is_write_timeout,
    kind_of,
)
from httpx._io.deadline import (
    MAX_SLICE_MS,
    Deadline,
    Deadlines,
    connect_deadline,
    now_ns,
    pool_deadline,
    read_deadline,
    write_deadline,
)


def test_a_deadline_in_the_future_has_not_passed() raises:
    var deadline = Deadline.after(30.0)
    assert_false(deadline.expired())
    assert_true(deadline.remaining_ms() > 0)


def test_a_deadline_of_zero_has_already_passed() raises:
    # `timeout=0` is how a caller asks for a non blocking attempt, so it has to
    # produce a deadline that is already gone rather than an error.
    assert_true(Deadline.after(0.0).expired())
    assert_true(Deadline.after(-1.0).expired())
    assert_equal(Deadline.after(0.0).remaining_ms(), 0)


def test_an_unlimited_deadline_never_passes_and_still_bounds_the_wait() raises:
    # The bound is the point. A wait with no timeout at all cannot be
    # interrupted by anything, so even an unlimited deadline waits in slices.
    var deadline = Deadline.never()
    assert_false(deadline.expired())
    assert_equal(deadline.remaining_ms(), MAX_SLICE_MS)


def test_the_wait_is_never_longer_than_one_slice() raises:
    # A long timeout still comes back regularly, so a caller loop stays
    # responsive and no single poll parks in the kernel for a minute.
    assert_equal(Deadline.after(60.0).remaining_ms(), MAX_SLICE_MS)


def test_a_wait_shorter_than_a_millisecond_rounds_up() raises:
    # Rounding down gives zero, and a caller that polls with zero in a loop
    # burns a core until the deadline passes.
    var deadline = Deadline(now_ns() + UInt64(500_000), True, ErrorKind.TIMEOUT)
    assert_equal(deadline.remaining_ms(), 1)


def test_each_phase_raises_the_error_named_after_it() raises:
    # The phase is decided where the deadline is made, because that is the only
    # place that knows whether this wait is a connect or a read. A user seeing
    # ReadTimeout instead of ConnectTimeout looks at the wrong end of the
    # problem.
    var connect = connect_deadline(Optional[Float64](0.0))
    var read = read_deadline(Optional[Float64](0.0))
    var write = write_deadline(Optional[Float64](0.0))
    var pool = pool_deadline(Optional[Float64](0.0))

    var seen = 0
    try:
        connect.check("connect to example.com:443")
    except e:
        seen += 1
        assert_true(is_connect_timeout(e))
    try:
        read.check("read from example.com:443")
    except e:
        seen += 1
        assert_true(is_read_timeout(e))
    try:
        write.check("write to example.com:443")
    except e:
        seen += 1
        assert_true(is_write_timeout(e))
    try:
        pool.check("acquire a connection to example.com:443")
    except e:
        seen += 1
        assert_true(is_pool_timeout(e))
    assert_equal(seen, 4)


def test_no_timeout_configured_means_no_deadline() raises:
    for deadline in [
        connect_deadline(None),
        read_deadline(None),
        write_deadline(None),
        pool_deadline(None),
    ]:
        assert_false(deadline.limited)
        assert_false(deadline.expired())
        deadline.check("do something that has no time limit")


def test_a_timeout_message_says_what_timed_out() raises:
    # "timed out" on its own is the least useful error an HTTP client can
    # produce, so the subject travels to the raise site.
    var raised = False
    try:
        Deadline.after(0.0).check("connect to example.com:443")
    except e:
        raised = True
        assert_true("example.com:443" in String(e))
    assert_true(raised)


def test_a_deadline_can_be_relabelled_without_moving() raises:
    # One connect budget covers DNS, the TCP connect and the TLS handshake, and
    # each stage wants its own error name while sharing the same instant.
    var original = Deadline.after(0.0, ErrorKind.CONNECT_TIMEOUT)
    var relabelled = original.with_kind(ErrorKind.READ_TIMEOUT)
    assert_equal(original.at_ns, relabelled.at_ns)
    with assert_raises():
        relabelled.check("read something")


def test_the_earlier_of_two_deadlines_wins_and_keeps_its_name() raises:
    # A per operation timeout inside a total budget. Whichever runs out first is
    # the one whose name the caller should see.
    var soon = Deadline.after(0.0, ErrorKind.READ_TIMEOUT)
    var later = Deadline.after(30.0, ErrorKind.CONNECT_TIMEOUT)
    assert_true(soon.earlier_of(later).kind == ErrorKind.READ_TIMEOUT)
    assert_true(later.earlier_of(soon).kind == ErrorKind.READ_TIMEOUT)
    # An unlimited deadline never wins, whichever side it is on.
    var forever = Deadline.never(ErrorKind.POOL_TIMEOUT)
    assert_true(forever.earlier_of(later).kind == ErrorKind.CONNECT_TIMEOUT)
    assert_true(later.earlier_of(forever).kind == ErrorKind.CONNECT_TIMEOUT)


def test_a_renewed_deadline_starts_its_budget_again() raises:
    # What makes a read timeout a limit on silence rather than on size. Each
    # read gets the whole budget back, so a body that keeps arriving never runs
    # out of time for being long.
    var original = Deadline.after(30.0, ErrorKind.READ_TIMEOUT)
    var renewed = original.renewed()
    assert_true(renewed.at_ns >= original.at_ns)
    assert_true(renewed.kind == ErrorKind.READ_TIMEOUT)
    assert_true(renewed.limited)


def test_an_expired_deadline_renews_to_a_live_one() raises:
    # The case that matters for a long download: the previous read used the
    # whole budget, and the next read still gets one.
    var spent = Deadline.after(0.0, ErrorKind.READ_TIMEOUT)
    assert_true(spent.expired())
    # Nothing to renew from, because zero was an instant and not a budget.
    assert_true(spent.renewed().expired())

    var used = Deadline(now_ns(), True, ErrorKind.READ_TIMEOUT, UInt64(10**9))
    assert_true(used.expired())
    assert_false(used.renewed().expired())


def test_an_unlimited_deadline_renews_to_itself() raises:
    var forever = Deadline.never(ErrorKind.READ_TIMEOUT)
    assert_false(forever.renewed().limited)


def test_a_deadline_made_from_an_instant_does_not_renew() raises:
    # A hard limit somebody set on purpose. Guessing a budget for it would turn
    # it into no limit at all, so it comes back unchanged.
    var at = now_ns() + UInt64(10**9)
    var fixed = Deadline(at, True, ErrorKind.READ_TIMEOUT)
    assert_equal(fixed.renewed().at_ns, at)


def test_a_deadline_can_be_stopped_from_renewing() raises:
    # Used for the wait on a 100 Continue, which is one total budget rather than
    # one budget per read.
    var budgeted = Deadline.after(30.0, ErrorKind.READ_TIMEOUT)
    var fixed = budgeted.fixed()
    assert_equal(fixed.at_ns, budgeted.at_ns)
    assert_equal(fixed.renewed().at_ns, budgeted.at_ns)


def test_relabelling_keeps_the_budget() raises:
    # The connect deadline is relabelled as it moves through DNS and the
    # handshake, and losing the budget on the way would quietly make it a
    # deadline that cannot be restarted.
    var original = Deadline.after(30.0, ErrorKind.CONNECT_TIMEOUT)
    var relabelled = original.with_kind(ErrorKind.READ_TIMEOUT)
    assert_equal(relabelled.budget_ns, original.budget_ns)


def test_the_clock_only_moves_forwards() raises:
    # Monotonic, not wall clock. A clock correction that stepped backwards would
    # otherwise extend every timeout in flight.
    var first = now_ns()
    var second = now_ns()
    assert_true(second >= first)


def test_a_generic_timeout_is_still_a_timeout() raises:
    var raised = False
    try:
        Deadline.after(0.0).check("wait for something unspecified")
    except e:
        raised = True
        assert_true(is_timeout(e))
        assert_true(kind_of(e) == ErrorKind.TIMEOUT)
    assert_true(raised)


def test_a_bundle_labels_each_phase_with_its_own_error() raises:
    # The reason the four are a bundle rather than one number. A request that
    # times out has to say which part of it did.
    var bundle = Deadlines.uniform(Optional[Float64](0.0))
    assert_true(bundle.connect.kind == ErrorKind.CONNECT_TIMEOUT)
    assert_true(bundle.read.kind == ErrorKind.READ_TIMEOUT)
    assert_true(bundle.write.kind == ErrorKind.WRITE_TIMEOUT)
    assert_true(bundle.pool.kind == ErrorKind.POOL_TIMEOUT)


def test_a_bundle_starts_all_four_clocks_together() raises:
    # The point of making them in one place. Four deadlines created wherever
    # each phase happened to begin would each get the whole budget, so a request
    # that spent a second in the pool would silently get a second longer to
    # connect.
    var bundle = Deadlines.uniform(Optional[Float64](30.0))
    # The pool deadline is made last, so it is the one furthest out.
    var spread = bundle.pool.at_ns - bundle.connect.at_ns
    assert_true(spread < UInt64(1_000_000))


def test_a_bundle_can_leave_a_phase_unlimited() raises:
    var bundle = Deadlines.after(
        Optional[Float64](5.0), None, Optional[Float64](5.0), None
    )
    assert_true(bundle.connect.limited)
    assert_false(bundle.read.limited)
    assert_true(bundle.write.limited)
    assert_false(bundle.pool.limited)


def test_a_bundle_with_no_limits_at_all_never_expires() raises:
    var bundle = Deadlines.never()
    assert_false(bundle.connect.expired())
    assert_false(bundle.read.expired())
    assert_false(bundle.write.expired())
    assert_false(bundle.pool.expired())


def test_a_deadline_in_milliseconds_is_the_same_deadline() raises:
    # The two constructors exist because half the callers here think in seconds
    # and the transport layer thinks in milliseconds. Coarse comparison, since
    # the two readings of the clock are not the same reading.
    var seconds = Deadline.after(0.5)
    var millis = Deadline.after_ms(500)
    assert_true(millis.limited)
    assert_false(millis.expired())
    # In nanoseconds, because `remaining_ms` is the length of the next wait and
    # is capped at MAX_SLICE_MS, so it cannot tell a half second from an hour.
    assert_true(millis.remaining_ns() > UInt64(400_000_000))
    assert_true(millis.remaining_ns() <= UInt64(500_000_000))
    assert_true(seconds.remaining_ns() > UInt64(400_000_000))


def test_zero_milliseconds_has_already_passed() raises:
    # `timeout=0` is how a caller asks for one non blocking attempt, so it makes
    # a deadline rather than an error.
    assert_true(Deadline.after_ms(0).expired())
    assert_true(Deadline.after_ms(-5).expired())
    assert_equal(Deadline.after_ms(0).remaining_ns(), UInt64(0))


def test_the_nanoseconds_left_run_down_to_zero_and_stop() raises:
    var live = Deadline.after_ms(500)
    assert_true(live.remaining_ns() > UInt64(0))
    assert_true(live.remaining_ns() <= UInt64(500_000_000))
    var passed = Deadline.after_ms(0)
    assert_equal(passed.remaining_ns(), UInt64(0))


def test_an_unlimited_deadline_reports_no_nanoseconds_left() raises:
    # Zero here does not mean expired, it means the question does not apply,
    # which is why `remaining_ms` checks `limited` before asking.
    var forever = Deadline.never()
    assert_equal(forever.remaining_ns(), UInt64(0))
    assert_false(forever.expired())
    assert_equal(forever.remaining_ms(), MAX_SLICE_MS)
