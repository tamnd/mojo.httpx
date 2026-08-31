"""IP literals in a host: reading them, and writing each one way.

A host in brackets is an address, not a name, so it never goes through IDNA and
never gets a DNS lookup. That makes it the one host form the client resolves
entirely by itself, which is exactly why it has to be validated here. A parser
that accepts `[::1.2.3.4.5]` because it only checked for a closing bracket will
hand a string to `connect` that means something else, or nothing, and the error
surfaces a long way from the URL that caused it.

The second job is canonical form. `[::1]`, `[0:0:0:0:0:0:0:1]` and `[::0001]`
are one address written three ways, and a client that treats them as three hosts
opens three connections, keys three cache entries and checks three certificates.
RFC 5952 picks one spelling and this writes that one: lowercase hex, no leading
zeros, and the longest run of zero groups collapsed to `::`.

IPv4 is here for a sharper reason. `127.0.0.1`, `0177.0.0.1`, `0x7f.1` and
`2130706433` are the same address to every resolver on the machine, and a host
that is only compared as a string treats them as four different names. That is
the shape of an allowlist bypass: the check reads `0x7f.1`, decides it is not
localhost, and the connection goes to localhost anyway. Recognising every form
and writing the dotted quad is what closes it, so the string that is checked is
the string that is dialled.
"""

from httpx._bytes import _hex_digit, is_digit
from httpx._exceptions import ErrorKind, new_error

comptime _COLON = UInt8(0x3A)
comptime _DOT = UInt8(0x2E)
comptime _ZERO = UInt8(0x30)

comptime _GROUPS = 8
"""Sixteen bytes, read and written as eight groups of two."""


def parse_ipv6[o: ImmOrigin](text: Span[UInt8, o]) raises -> List[UInt16]:
    """The eight groups of an IPv6 address, or a raise.

    This is the WHATWG algorithm rather than a hand rolled scan, because the
    awkward parts of the grammar are not the parts that look awkward. `::` may
    appear once and stands for at least one zero group, a trailing dotted quad
    counts as two groups and may only appear at the end, and a group is one to
    four hex digits with no sign and no `0x`. Every one of those is a place
    where an accepting-too-much parser turns into a host that is not the host
    that was written.
    """
    var pieces = List[UInt16]()
    for _ in range(_GROUPS):
        pieces.append(0)

    var length = text.__len__()
    var index = 0
    var at = 0
    # Where the `::` was, so the groups before it can be pushed to the end once
    # the total is known. -1 means there was none.
    var compress = -1

    if at < length and text[at] == _COLON:
        if at + 1 >= length or text[at + 1] != _COLON:
            raise _bad(text, "a leading colon has to be part of '::'")
        at += 2
        compress = 0

    while at < length:
        if index == _GROUPS:
            raise _bad(text, "more than eight groups")
        if text[at] == _COLON:
            if compress >= 0:
                raise _bad(text, "'::' can only appear once")
            at += 1
            compress = index
            continue

        var value = 0
        var digits = 0
        while digits < 4 and at < length and _hex_digit(text[at]) >= 0:
            value = value * 16 + _hex_digit(text[at])
            at += 1
            digits += 1

        if at < length and text[at] == _DOT:
            if digits == 0:
                raise _bad(text, "a dotted quad with no digits")
            if index > _GROUPS - 2:
                raise _bad(text, "no room for a dotted quad")
            # The digits just read were the first octet, not a hex group, so
            # the scan backs up and reads the whole quad as decimal.
            at -= digits
            _read_ipv4_tail(text, at, index, pieces)
            index += 2
            break

        if at < length:
            if text[at] != _COLON:
                raise _bad(text, "a group has to end at a colon")
            at += 1
            if at >= length:
                raise _bad(text, "a trailing colon has to be part of '::'")

        pieces[index] = UInt16(value)
        index += 1

    if compress >= 0:
        # The groups that were written after the `::` were parsed into the
        # positions right after the ones before it, so they slide to the end and
        # the gap they leave is the run of zeros.
        var moved = index - compress
        var target = _GROUPS - 1
        while moved > 0:
            var source = compress + moved - 1
            var held = pieces[target]
            pieces[target] = pieces[source]
            pieces[source] = held
            target -= 1
            moved -= 1
    elif index != _GROUPS:
        raise _bad(text, "fewer than eight groups and no '::'")

    return pieces^


def _read_ipv4_tail[
    o: ImmOrigin
](
    text: Span[UInt8, o], var at: Int, index: Int, mut pieces: List[UInt16]
) raises:
    """Read `a.b.c.d` at `at` into the two groups starting at `index`."""
    var length = text.__len__()
    var seen = 0
    while at < length:
        if seen > 0:
            if seen < 4 and text[at] == _DOT:
                at += 1
            else:
                raise _bad(text, "a dotted quad has four parts")
        if at >= length or not is_digit(text[at]):
            raise _bad(text, "a dotted quad part with no digits")
        var octet = -1
        while at < length and is_digit(text[at]):
            var digit = Int(text[at] - _ZERO)
            if octet < 0:
                octet = digit
            elif octet == 0:
                # `01` is not `1`. Some resolvers read a leading zero as octal,
                # so a spelling that two readers disagree about is refused.
                raise _bad(text, "a dotted quad part with a leading zero")
            else:
                octet = octet * 10 + digit
            if octet > 255:
                raise _bad(text, "a dotted quad part above 255")
            at += 1
        var slot = index + seen // 2
        pieces[slot] = pieces[slot] * 256 + UInt16(octet)
        seen += 1
    if seen != 4:
        raise _bad(text, "a dotted quad has four parts")


def format_ipv6(pieces: List[UInt16]) -> String:
    """The RFC 5952 spelling: lowercase, no leading zeros, longest run as `::`.

    Ties go to the leftmost run and a single zero group is written out rather
    than compressed, both because the RFC says so and because two writers that
    choose differently produce two strings for one address.
    """
    var best_at = -1
    var best_length = 0
    var run_at = -1
    var run_length = 0
    for i in range(len(pieces)):
        if pieces[i] == 0:
            if run_at < 0:
                run_at = i
            run_length += 1
            if run_length > best_length:
                best_at = run_at
                best_length = run_length
        else:
            run_at = -1
            run_length = 0
    if best_length < 2:
        best_at = -1

    var out = String()
    # The `::` carries its own separator on both sides, so the next group after
    # it must not add another one. That is the whole reason this is a flag and
    # not a test on the index.
    var need_colon = False
    var i = 0
    while i < len(pieces):
        if i == best_at:
            out += "::"
            need_colon = False
            i += best_length
            continue
        if need_colon:
            out += ":"
        out += _hex(pieces[i])
        need_colon = True
        i += 1
    return out^


def _hex(value: UInt16) -> String:
    comptime DIGITS = StaticString("0123456789abcdef")
    if value == 0:
        return String("0")
    var out = String()
    var started = False
    for step in range(4):
        var shift = UInt16(12 - step * 4)
        var nibble = Int((value >> shift) & UInt16(15))
        if nibble != 0 or started:
            started = True
            # Sound because `nibble` is four bits masked out of a UInt16, so it
            # is 0 to 15 and indexes a sixteen byte ASCII literal in range.
            out += StringSpan(
                unsafe_from_utf8=DIGITS.as_bytes()[nibble : nibble + 1]
            )
    return out^


def _split_labels[o: ImmOrigin](host: Span[UInt8, o]) -> List[Int]:
    """Where each dot-separated label of `host` starts, plus its length.

    Returned as a flat list of start and end pairs so there is one allocation
    and no copies. A single trailing dot is dropped, because `example.com.` and
    `example.com` are the same name and `1.2.3.4.` is the same address.
    """
    var bounds = List[Int]()
    var at = 0
    var length = host.__len__()
    while True:
        var stop = at
        while stop < length and host[stop] != _DOT:
            stop += 1
        bounds.append(at)
        bounds.append(stop)
        if stop >= length:
            break
        at = stop + 1
    if len(bounds) > 2 and bounds[len(bounds) - 2] == bounds[len(bounds) - 1]:
        _ = bounds.pop()
        _ = bounds.pop()
    return bounds^


def _ipv4_number[
    o: ImmOrigin
](text: Span[UInt8, o], start: Int, end: Int) -> Int:
    """One dotted part as a number, or -1 if it is not one.

    The three bases are not a nicety, they are what the C resolver has always
    accepted, so refusing to read them here would not stop them working, it
    would only stop this library from seeing what it is about to connect to.
    `0x` is hexadecimal, a leading `0` is octal, anything else is decimal.
    """
    var at = start
    var base = 10
    if end - at >= 2 and text[at] == _ZERO:
        if text[at + 1] == UInt8(0x78) or text[at + 1] == UInt8(0x58):
            base = 16
            at += 2
        else:
            base = 8
            at += 1
    if at == end:
        # `0` and `0x` both name zero. Only an originally empty part is not a
        # number, and that is caught by the caller before it gets here.
        return 0 if end > start else -1
    var value = 0
    while at < end:
        var digit = _hex_digit(text[at])
        if digit < 0 or digit >= base:
            return -1
        # Held just above the largest address rather than allowed to run away.
        # Something too big is still a number, and it is the caller that decides
        # a number too big for the space it has is an error. Failing here would
        # instead make `0xffffffff1` look like a name and get a DNS lookup.
        if value <= 0xFFFFFFFF:
            value = value * base + digit
        if value > 0xFFFFFFFF:
            value = 0x100000000
        at += 1
    return value


def looks_like_ipv4[o: ImmOrigin](host: Span[UInt8, o]) -> Bool:
    """Whether `host` should be read as an address rather than as a name.

    The test is on the last label only, which is what the URL standard says and
    is not arbitrary: `foo.09` has to be an error rather than a domain, because
    something that ends in a number is being written as an address by whoever
    wrote it, and quietly resolving it as a name is how the two readings drift
    apart.
    """
    var bounds = _split_labels(host)
    var start = bounds[len(bounds) - 2]
    var end = bounds[len(bounds) - 1]
    if start == end:
        return False
    var all_digits = True
    for i in range(start, end):
        if not is_digit(host[i]):
            all_digits = False
            break
    if all_digits:
        return True
    return _ipv4_number(host, start, end) >= 0


def parse_ipv4[o: ImmOrigin](host: Span[UInt8, o]) raises -> String:
    """`host` as a dotted quad, or a raise.

    Fewer than four parts is legal and means the last one carries the rest of
    the address, which is where `http://256` being `0.0.1.0` comes from. Every
    part that is not the last still has to fit in a byte, and the last has to
    fit in what is left, so nothing here silently truncates.
    """
    var bounds = _split_labels(host)
    var count = len(bounds) // 2
    if count > 4:
        raise _bad4(host, "more than four parts")

    var numbers = List[Int]()
    for i in range(count):
        var start = bounds[i * 2]
        var end = bounds[i * 2 + 1]
        if start == end:
            raise _bad4(host, "an empty part")
        var value = _ipv4_number(host, start, end)
        if value < 0:
            raise _bad4(host, "a part that is not a number")
        numbers.append(value)

    for i in range(count - 1):
        if numbers[i] > 255:
            raise _bad4(host, "a part above 255")
    var room = 1
    for _ in range(5 - count):
        room *= 256
    if numbers[count - 1] >= room:
        raise _bad4(host, "a last part too large for the parts before it")

    var address = numbers[count - 1]
    for i in range(count - 1):
        var shift = 1
        for _ in range(3 - i):
            shift *= 256
        address += numbers[i] * shift

    var out = String()
    for i in range(4):
        if i > 0:
            out += "."
        var shift = 1
        for _ in range(3 - i):
            shift *= 256
        out += String((address // shift) % 256)
    return out^


def _bad4[o: ImmOrigin](text: Span[UInt8, o], why: StaticString) -> Error:
    return new_error(
        ErrorKind.INVALID_URL, String("not an IPv4 address, ", why)
    )


def _bad[o: ImmOrigin](text: Span[UInt8, o], why: StaticString) -> Error:
    # The address is not echoed. It arrived inside a URL from somewhere, and the
    # reason is what tells you what to fix anyway.
    return new_error(
        ErrorKind.INVALID_URL, String("not an IPv6 address, ", why)
    )
