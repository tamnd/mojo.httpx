"""Tests for the calendar arithmetic and the cookie-date reader.

The arithmetic is checked against dates chosen to sit on the boundaries the
algorithm actually has: the epoch, the day before it, the century leap years,
and the March pivot the whole scheme is built around. A round trip over a long
run of consecutive days catches anything the fixed points miss.

The reader is checked against the shapes real servers emit, which is a wider set
than the three formats the specification defines.
"""

from std.testing import assert_equal, assert_raises, assert_true

from httpx._util.date import (
    civil_from_days,
    days_from_civil,
    format_http_date,
    parse_cookie_date,
)


def _parse(text: StringSpan) raises -> Int:
    return parse_cookie_date(text.as_bytes())


def test_the_epoch_is_day_zero() raises:
    assert_equal(days_from_civil(1970, 1, 1), 0)
    assert_equal(days_from_civil(1969, 12, 31), -1)
    assert_equal(days_from_civil(1970, 1, 2), 1)


def test_known_dates_convert() raises:
    # 2000 is a leap year and 1900 is not, which is the rule a naive
    # implementation gets wrong and the only place the 400 year cycle shows.
    assert_equal(days_from_civil(2000, 3, 1), 11017)
    assert_equal(days_from_civil(1900, 3, 1), -25508)
    assert_equal(days_from_civil(2026, 8, 31), 20696)


def test_the_conversion_round_trips() raises:
    # Twelve years of consecutive days, which covers three leap years, both
    # century boundaries around them and every month length.
    for day in range(-2000, 2500):
        var civil = civil_from_days(day)
        assert_equal(days_from_civil(civil[0], civil[1], civil[2]), day)


def test_the_three_legal_formats_read_the_same() raises:
    # RFC 9110 defines these three. A client has to read all of them, and the
    # cookie-date algorithm covers all three without knowing about any of them.
    var imf = _parse("Sun, 06 Nov 1994 08:49:37 GMT")
    assert_equal(imf, 784111777)
    assert_equal(_parse("Sunday, 06-Nov-94 08:49:37 GMT"), imf)
    assert_equal(_parse("Sun Nov  6 08:49:37 1994"), imf)


def test_the_shapes_servers_actually_send() raises:
    var want = _parse("Sun, 06 Nov 1994 08:49:37 GMT")
    # Single digit day, no comma, a timezone that is not GMT, and a timezone
    # name that means nothing. Every one of these is in the wild.
    assert_equal(_parse("Sun, 6 Nov 1994 08:49:37 GMT"), want)
    assert_equal(_parse("06 Nov 1994 08:49:37"), want)
    assert_equal(_parse("Sun, 06 Nov 1994 08:49:37 UTC"), want)
    assert_equal(_parse("Sun, 06-Nov-1994 08:49:37 XYZZY"), want)


def test_a_timezone_offset_is_not_applied() raises:
    # Nothing in the algorithm reads an offset, so a date carrying one is read
    # as if it were UTC. Worth pinning: it is a real limitation rather than an
    # oversight, and the alternative is guessing.
    assert_equal(
        _parse("Sun, 06 Nov 1994 08:49:37 +0500"),
        _parse("Sun, 06 Nov 1994 08:49:37 GMT"),
    )


def test_two_digit_years_split_at_seventy() raises:
    assert_equal(_parse("01 Jan 70 00:00:00"), 0)
    assert_equal(
        _parse("01 Jan 99 00:00:00"), days_from_civil(1999, 1, 1) * 86400
    )
    assert_equal(
        _parse("01 Jan 00 00:00:00"), days_from_civil(2000, 1, 1) * 86400
    )
    assert_equal(
        _parse("01 Jan 69 00:00:00"), days_from_civil(2069, 1, 1) * 86400
    )


def test_the_first_thing_that_fits_wins() raises:
    # The algorithm takes each token in order and never reconsiders. In this
    # date the year comes before the day, and it still reads correctly because
    # `1994` cannot be a day and `06` cannot be a four digit year.
    assert_equal(
        _parse("1994 Nov 06 08:49:37"), _parse("Sun, 06 Nov 1994 08:49:37 GMT")
    )


def test_a_date_before_the_epoch_is_negative() raises:
    assert_true(_parse("01 Jan 1970 00:00:00") == 0)
    assert_true(_parse("31 Dec 1969 23:59:59") == -1)


def test_an_unreadable_date_raises() raises:
    # The caller turns this into a session cookie. It must not turn into a
    # cookie that expired, which is why the failure has to be visible.
    with assert_raises():
        _ = _parse("")
    with assert_raises():
        _ = _parse("not a date at all")
    with assert_raises():
        # No time, so three of the four fields are missing.
        _ = _parse("06 Nov 1994")


def test_out_of_range_fields_are_rejected() raises:
    with assert_raises():
        _ = _parse("32 Nov 1994 08:49:37")
    with assert_raises():
        _ = _parse("06 Nov 1994 24:00:00")
    with assert_raises():
        _ = _parse("06 Nov 1994 08:60:00")
    with assert_raises():
        # Before 1601, which the algorithm rejects outright rather than trying
        # to represent a date the Gregorian calendar did not exist for.
        _ = _parse("06 Nov 1500 08:49:37")


def test_dates_format_as_imf_fixdate() raises:
    assert_equal(format_http_date(784111777), "Sun, 06 Nov 1994 08:49:37 GMT")
    assert_equal(format_http_date(0), "Thu, 01 Jan 1970 00:00:00 GMT")
    assert_equal(format_http_date(-1), "Wed, 31 Dec 1969 23:59:59 GMT")


def test_formatting_and_parsing_are_inverses() raises:
    # Every hour of a leap day and the day either side of it, which is where a
    # wrong weekday or a wrong month rollover would show up.
    var start = days_from_civil(2024, 2, 28) * 86400
    for hour in range(72):
        var when = start + hour * 3600 + 1234
        assert_equal(_parse(format_http_date(when)), when)
