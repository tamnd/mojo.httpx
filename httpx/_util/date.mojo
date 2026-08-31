"""Dates on the wire.

Two jobs. Converting between a calendar date and Unix seconds, which is pure
arithmetic, and reading the dates servers actually send, which is not.

The reading side implements the cookie-date algorithm from RFC 6265 section
5.1.1 rather than any of the three date formats RFC 9110 defines. That is
deliberate. The three formats describe what a server is supposed to send, and
the cookie-date algorithm describes how to read what it really sends, which
includes single digit days, two digit years, missing or invented timezone names,
and separators nobody standardized. All three legal formats parse correctly
under the lenient algorithm, so there is nothing to gain by trying them first.

The one thing the algorithm refuses to do is guess a timezone. Every date is
read as UTC, because a cookie date that is off by an hour expires an hour early
or an hour late and neither is worse than dropping the cookie outright, whereas
a date silently shifted by a misread zone name is a bug that only shows up
twice a year.
"""

from httpx._bytes import index_of, is_digit, to_lower

comptime _COLON = UInt8(0x3A)
comptime _ZERO = UInt8(0x30)

comptime _MONTHS = StaticString("janfebmaraprmayjunjulaugsepoctnovdec")
comptime _MONTH_NAMES = StaticString("JanFebMarAprMayJunJulAugSepOctNovDec")
comptime _DAY_NAMES = StaticString("SunMonTueWedThuFriSat")

comptime SECONDS_PER_DAY = 86400


def days_from_civil(year: Int, month: Int, day: Int) -> Int:
    """Days between 1970-01-01 and the given proleptic Gregorian date.

    Howard Hinnant's algorithm, which is worth using unchanged rather than
    reinventing: it is branch free, exact over the whole range of the calendar,
    and it does not need a table of month lengths, so there is no leap year
    special case to get wrong. The trick is shifting the year to start in March,
    which puts the leap day at the end where it stops perturbing anything.

    Days out of range for the month are not rejected, they carry. February 30th
    becomes March 2nd. That is what the cookie-date algorithm asks for, and the
    caller that wants a calendar check does it before calling.
    """
    var y = year
    if month <= 2:
        y -= 1
    # Mojo's `//` floors, which is what this needs for years before 1 and what
    # the original expresses with an explicit adjustment for negative input.
    var era = y // 400
    var year_of_era = y - era * 400
    var shifted = month + 9 if month <= 2 else month - 3
    var day_of_year = (153 * shifted + 2) // 5 + day - 1
    var day_of_era = (
        year_of_era * 365 + year_of_era // 4 - year_of_era // 100 + day_of_year
    )
    return era * 146097 + day_of_era - 719468


def civil_from_days(days: Int) -> Tuple[Int, Int, Int]:
    """The inverse of `days_from_civil`, as year, month, day."""
    var z = days + 719468
    var era = z // 146097
    var day_of_era = z - era * 146097
    var year_of_era = (
        day_of_era
        - day_of_era // 1460
        + day_of_era // 36524
        - day_of_era // 146096
    ) // 365
    var year = year_of_era + era * 400
    var day_of_year = day_of_era - (
        365 * year_of_era + year_of_era // 4 - year_of_era // 100
    )
    var shifted = (5 * day_of_year + 2) // 153
    var day = day_of_year - (153 * shifted + 2) // 5 + 1
    var month = shifted + 3 if shifted < 10 else shifted - 9
    if month <= 2:
        year += 1
    return (year, month, day)


def _is_delimiter(byte: UInt8) -> Bool:
    """The cookie-date delimiter set, RFC 6265 section 5.1.1.

    Everything outside it is part of a token, which is why a colon survives and
    a slash does not: `10:20:30` has to stay whole and `10/Jun/2026` has to come
    apart.
    """
    if byte == 0x09:
        return True
    if byte >= 0x20 and byte <= 0x2F:
        return True
    if byte >= 0x3B and byte <= 0x40:
        return True
    if byte >= 0x5B and byte <= 0x60:
        return True
    return byte >= 0x7B and byte <= 0x7E


def _read_number[
    o: ImmOrigin
](token: Span[UInt8, o], least: Int, most: Int, exact: Bool = False) -> Int:
    """The leading run of digits, or -1 when it is not the right length.

    `exact` is the difference between a field and a whole token. The seconds in
    `08:49:37GMT` are a field that happens to be followed by letters, which the
    grammar allows, while the hours in `1a:49:37` are not a valid field at all.
    """
    var digits = 0
    var value = 0
    while digits < token.__len__() and is_digit(token[digits]):
        value = value * 10 + Int(token[digits] - _ZERO)
        digits += 1
    if digits < least or digits > most:
        return -1
    if exact and digits != token.__len__():
        return -1
    return value


def _month_from[o: ImmOrigin](token: Span[UInt8, o]) -> Int:
    """The month number for a token whose first three bytes name a month.

    Only the first three bytes are looked at, so `Novem` and `November` and
    `Nov` are the same month. That is what the algorithm says, and it is also
    what makes the non English month names some servers emit fail cleanly
    instead of matching something else.
    """
    if token.__len__() < 3:
        return -1
    var names = _MONTHS.as_bytes()
    for index in range(12):
        var matched = True
        for i in range(3):
            if to_lower(token[i]) != names[index * 3 + i]:
                matched = False
                break
        if matched:
            return index + 1
    return -1


def _read_time[
    o: ImmOrigin
](
    token: Span[UInt8, o], mut hour: Int, mut minute: Int, mut second: Int
) -> Bool:
    var first = index_of(token, _COLON)
    if first < 0:
        return False
    var last = index_of(token, _COLON, first + 1)
    if last < 0:
        return False
    var h = _read_number(token[0:first], 1, 2, exact=True)
    var m = _read_number(token[first + 1 : last], 1, 2, exact=True)
    var s = _read_number(token[last + 1 : token.__len__()], 1, 2)
    if h < 0 or m < 0 or s < 0:
        return False
    hour = h
    minute = m
    second = s
    return True


def parse_cookie_date[o: ImmOrigin](text: Span[UInt8, o]) raises -> Int:
    """Read a date the way RFC 6265 section 5.1.1 says to, into Unix seconds.

    The shape of the algorithm is the interesting part. It does not match a
    format. It splits the string into tokens and then asks each token, in a
    fixed order of preference, whether it could be the time, the day, the month
    or the year, taking the first thing that fits and never revisiting. That is
    why `Wed, 09 Jun 2021 10:18:14 GMT` and `Wed Jun 09 2021 10:18:14` and
    `09-Jun-21 10:18:14` all read the same, and it is also why a token that
    looks like nothing, a timezone name for instance, is simply skipped.

    Raises when a field is missing or out of range. The caller treats that as a
    session cookie rather than a cookie that expired, which is the safe
    direction: the alternative is deleting a cookie because a server sent a date
    we could not read.
    """
    var hour = -1
    var minute = -1
    var second = -1
    var day = -1
    var month = -1
    var year = -1

    var i = 0
    var length = text.__len__()
    while i < length:
        if _is_delimiter(text[i]):
            i += 1
            continue
        var start = i
        while i < length and not _is_delimiter(text[i]):
            i += 1
        var token = text[start:i]

        if hour < 0 and _read_time(token, hour, minute, second):
            continue
        if day < 0:
            var found = _read_number(token, 1, 2)
            if found >= 0:
                day = found
                continue
        if month < 0:
            var found = _month_from(token)
            if found >= 0:
                month = found
                continue
        if year < 0:
            var found = _read_number(token, 2, 4)
            if found >= 0:
                year = found
                continue

    # Two digit years, from the days when that seemed like enough. The split is
    # fixed by the RFC rather than chosen, so a cookie dated 70 is 1970 and a
    # cookie dated 69 is 2069.
    if year >= 70 and year <= 99:
        year += 1900
    elif year >= 0 and year <= 69:
        year += 2000

    if hour < 0 or day < 0 or month < 0 or year < 0:
        raise Error("could not read a date from " + _shown(text))
    if day < 1 or day > 31:
        raise Error("day out of range in " + _shown(text))
    if year < 1601:
        raise Error("year out of range in " + _shown(text))
    if hour > 23 or minute > 59 or second > 59:
        raise Error("time out of range in " + _shown(text))

    var days = days_from_civil(year, month, day)
    return days * SECONDS_PER_DAY + hour * 3600 + minute * 60 + second


def _shown[o: ImmOrigin](text: Span[UInt8, o]) raises -> String:
    return String("'", StringSpan(from_utf8=text), "'")


def format_http_date(seconds: Int) -> String:
    """Render Unix seconds as an IMF-fixdate, the one format a client may send.

    `Sun, 06 Nov 1994 08:49:37 GMT`. Fixed width, always UTC, always the English
    abbreviations regardless of anything else, because this is a protocol
    element and not something a person reads.
    """
    var days = seconds // SECONDS_PER_DAY
    var rest = seconds - days * SECONDS_PER_DAY
    var civil = civil_from_days(days)
    var weekday = (days + 4) % 7
    var names = _DAY_NAMES.as_bytes()
    var months = _MONTH_NAMES.as_bytes()
    var out = String()
    out += StringSpan(unsafe_from_utf8=names[weekday * 3 : weekday * 3 + 3])
    out += ", "
    out += _padded(civil[2], 2)
    out += " "
    var m = civil[1] - 1
    out += StringSpan(unsafe_from_utf8=months[m * 3 : m * 3 + 3])
    out += " "
    out += _padded(civil[0], 4)
    out += " "
    out += _padded(rest // 3600, 2)
    out += ":"
    out += _padded((rest // 60) % 60, 2)
    out += ":"
    out += _padded(rest % 60, 2)
    out += " GMT"
    return out^


def _padded(value: Int, width: Int) -> String:
    var text = String(value)
    var out = String()
    for _ in range(width - text.byte_length()):
        out += "0"
    out += text
    return out^
