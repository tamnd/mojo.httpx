"""Tests for `Duration`.

Small type, so these are mostly arithmetic. The two worth having are the clamp
in `between`, because the alternative to a clamp is an unsigned subtraction that
wraps to about five hundred years, and the six digit formatting, because it is
built from integers rather than by printing a float and the zero padding is easy
to get wrong in a way that only shows on some values.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._util.duration import Duration


def test_the_scales_all_agree() raises:
    var d = Duration(1_500_000_000)
    assert_equal(d.nanoseconds, 1_500_000_000)
    assert_equal(d.microseconds(), 1_500_000.0)
    assert_equal(d.milliseconds(), 1_500.0)
    assert_equal(d.seconds(), 1.5)


def test_a_zero_duration_is_zero_on_every_scale() raises:
    var d = Duration()
    assert_equal(d.nanoseconds, 0)
    assert_equal(d.seconds(), 0.0)


def test_between_measures_the_gap() raises:
    assert_equal(Duration.between(1_000, 3_500).nanoseconds, 2_500)


def test_between_clamps_rather_than_wrapping() raises:
    # These are unsigned, so a subtraction going the wrong way would report
    # roughly five hundred years instead of a negative number.
    assert_equal(Duration.between(3_500, 1_000).nanoseconds, 0)
    assert_equal(Duration.between(7, 7).nanoseconds, 0)


def test_durations_compare_on_the_time_they_hold() raises:
    assert_true(Duration(1) < Duration(2))
    assert_true(Duration(2) >= Duration(2))
    assert_true(Duration(2) == Duration(2))
    assert_false(Duration(2) == Duration(3))
    assert_true(Duration(3) != Duration(2))


def test_it_writes_as_seconds_to_six_places() raises:
    assert_equal(String(Duration(1_234_567_890)), "1.234567s")
    assert_equal(String(Duration(0)), "0.000000s")


def test_the_fraction_is_zero_padded() raises:
    # The case that catches a formatter built by dividing rather than by walking
    # the digits: three microseconds is 0.000003 and not 0.3.
    assert_equal(String(Duration(3_000)), "0.000003s")
    assert_equal(String(Duration(30_000_000)), "0.030000s")


def test_anything_under_a_microsecond_writes_as_zero() raises:
    # Six places is what a `timedelta` resolves to, so this is the same answer
    # httpx2 gives, and the nanoseconds are still there for anyone who needs
    # them.
    assert_equal(String(Duration(999)), "0.000000s")
    assert_equal(Duration(999).nanoseconds, 999)
