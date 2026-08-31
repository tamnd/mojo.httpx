"""IDNA: turning a hostname a human typed into the one that goes on the wire.

Two forms of every name exist and both are needed. The A-label form is ASCII,
is what DNS resolves and what goes in a `Host` header, and is what cookie domain
matching compares. The U-label form is the Unicode the user typed and is what
gets shown back to them. `URL.raw_host` is the first and `URL.host` is the
second, and mixing them up is how a request goes to one host and a cookie is
scoped to another.

Almost every hostname is already ASCII, so that path allocates nothing and
touches no table. Everything below it exists for the rest.

Punycode here is RFC 3492 in full, including the overflow checks, which are not
optional: the algorithm accumulates an unbounded integer in a fixed width one and
a crafted label can carry it past the end.

Above punycode sits UTS-46, which is what turns what a person typed into what
punycode can encode. It maps case and the compatibility characters, normalizes to
NFC, and then checks each label against the IDNA 2008 rules that survive into
UTS-46: no leading combining mark, no misplaced zero width joiner, and the bidi
rule from RFC 5893 for any name with a right to left character in it. CheckHyphens
is off, matching the URL Standard, so `a--b` and `-a-` are names like any other.
Transitional processing is off too, so the four deviation characters keep their
own meaning rather than being folded the way IDNA 2003 folded them.
"""

from httpx._bytes import Bytes, _quote, to_lower
from httpx._exceptions import ErrorKind, new_error
from httpx._util._unicode import (
    DISALLOWED,
    IGNORED,
    MAPPED,
    VALID,
    bidi_class,
    combining_class,
    idna_mapping,
    idna_status,
    is_mark,
    joining_type,
    nfc,
)

# RFC 3492 section 5.
comptime _BASE = 36
comptime _TMIN = 1
comptime _TMAX = 26
comptime _SKEW = 38
comptime _DAMP = 700
comptime _INITIAL_BIAS = 72
comptime _INITIAL_N = 128

comptime _PREFIX = StaticString("xn--")

# RFC 1035 section 2.3.4. A label longer than 63 bytes cannot be expressed in the
# wire format at all, and a name longer than 253 cannot be either.
comptime MAX_LABEL = 63
comptime MAX_NAME = 253

# The largest code point, so a decoded value above it is a corrupt label rather
# than a character.
comptime _MAX_CODEPOINT = UInt32(0x10FFFF)

comptime _FULL_STOP = UInt32(0x2E)
comptime _ZWNJ = UInt32(0x200C)
comptime _ZWJ = UInt32(0x200D)

# The combining class of a virama, which is the mark that says two letters join.
comptime _VIRAMA = 9

# The bidi classes the rule in RFC 5893 is written in terms of, as the single
# letters tools/gen_idna.py writes them as.
comptime _BIDI_L = UInt8(ord("L"))
comptime _BIDI_R = UInt8(ord("R"))
comptime _BIDI_AL = UInt8(ord("A"))
comptime _BIDI_AN = UInt8(ord("N"))
comptime _BIDI_EN = UInt8(ord("E"))
comptime _BIDI_ES = UInt8(ord("S"))
comptime _BIDI_CS = UInt8(ord("C"))
comptime _BIDI_ET = UInt8(ord("T"))
comptime _BIDI_ON = UInt8(ord("O"))
comptime _BIDI_BN = UInt8(ord("B"))
comptime _BIDI_NSM = UInt8(ord("M"))

# Joining types, likewise. Non joining is the absence of an entry rather than a
# letter of its own.
comptime _JOIN_D = UInt8(ord("D"))
comptime _JOIN_L = UInt8(ord("L"))
comptime _JOIN_R = UInt8(ord("R"))
comptime _JOIN_T = UInt8(ord("T"))


def _is_ascii_host_byte(byte: UInt8) -> Bool:
    """Whether `byte` may appear in a hostname without any mapping.

    Letters, digits, hyphen and dot. Underscore is deliberately absent even
    though it appears in service records, because it is not valid in a host that
    is going to be connected to, and accepting it here would let it through into
    a `Host` header.
    """
    return (
        (byte >= UInt8(ord("a")) and byte <= UInt8(ord("z")))
        or (byte >= UInt8(ord("A")) and byte <= UInt8(ord("Z")))
        or (byte >= UInt8(ord("0")) and byte <= UInt8(ord("9")))
        or byte == UInt8(ord("-"))
        or byte == UInt8(ord("."))
    )


def _is_std3_byte(byte: UInt8) -> Bool:
    """Whether `byte` may appear inside a label under STD3 ASCII rules.

    The same set as `_is_ascii_host_byte` without the dot, which separates
    labels rather than appearing in one, and without the upper case letters,
    which the mapping table has already folded away by the time this runs.
    """
    return (
        (byte >= UInt8(ord("a")) and byte <= UInt8(ord("z")))
        or (byte >= UInt8(ord("0")) and byte <= UInt8(ord("9")))
        or byte == UInt8(ord("-"))
    )


def _adapt(var delta: Int, num_points: Int, first_time: Bool) -> Int:
    """The bias adaptation from RFC 3492 section 6.1, transcribed as written."""
    if first_time:
        delta //= _DAMP
    else:
        delta //= 2
    delta += delta // num_points
    var k = 0
    while delta > ((_BASE - _TMIN) * _TMAX) // 2:
        delta //= _BASE - _TMIN
        k += _BASE
    return k + (((_BASE - _TMIN + 1) * delta) // (delta + _SKEW))


def _threshold(k: Int, bias: Int) -> Int:
    """`t` for the current position, clamped to [tmin, tmax]."""
    if k <= bias + _TMIN:
        return _TMIN
    if k >= bias + _TMAX:
        return _TMAX
    return k - bias


def _digit_to_byte(digit: Int) -> UInt8:
    """0 through 25 are `a` to `z`, 26 through 35 are `0` to `9`."""
    if digit < 26:
        return UInt8(ord("a") + digit)
    return UInt8(ord("0") + digit - 26)


def _byte_to_digit(byte: UInt8) -> Int:
    """The inverse of `_digit_to_byte`, or -1 when the byte is not a digit."""
    if byte >= UInt8(ord("a")) and byte <= UInt8(ord("z")):
        return Int(byte) - ord("a")
    if byte >= UInt8(ord("A")) and byte <= UInt8(ord("Z")):
        return Int(byte) - ord("A")
    if byte >= UInt8(ord("0")) and byte <= UInt8(ord("9")):
        return Int(byte) - ord("0") + 26
    return -1


def punycode_encode(label: StringSpan) raises -> String:
    """Encode one label to punycode, without the `xn--` prefix."""
    var points = List[UInt32]()
    for codepoint in label.codepoints():
        points.append(codepoint.to_u32())
    return punycode_encode_points(points)


def punycode_encode_points(points: List[UInt32]) raises -> String:
    """Encode one label to punycode, without the `xn--` prefix.

    RFC 3492 section 6.3. The overflow check on `delta` is the security relevant
    part: the algorithm accumulates a value that is unbounded in principle, and a
    label built to make it wrap would decode back to a different name than it
    encodes to.

    Takes code points rather than text because UTS-46 has already decomposed the
    name into them by the time this runs, and going back through a String would
    mean encoding and decoding UTF-8 for nothing.
    """
    var out = String()
    var basic_count = 0
    for i in range(len(points)):
        if points[i] < UInt32(_INITIAL_N):
            out += chr(Int(points[i]))
            basic_count += 1
    var handled = basic_count
    if basic_count > 0:
        out += "-"

    var n = UInt32(_INITIAL_N)
    var delta = 0
    var bias = _INITIAL_BIAS

    while handled < len(points):
        # The smallest code point still to be dealt with, which is the next one
        # the delta encoding steps up to.
        var m = _MAX_CODEPOINT + 1
        for i in range(len(points)):
            if points[i] >= n and points[i] < m:
                m = points[i]

        var step = Int(m - n)
        if step > (Int.MAX - delta) // (handled + 1):
            raise new_error(
                ErrorKind.INVALID_URL,
                String(
                    "punycode overflow encoding a label of ",
                    len(points),
                    " characters",
                ),
            )
        delta += step * (handled + 1)
        n = m

        for i in range(len(points)):
            if points[i] < n:
                if delta == Int.MAX:
                    raise new_error(
                        ErrorKind.INVALID_URL,
                        String(
                            "punycode overflow encoding a label of ",
                            len(points),
                            " characters",
                        ),
                    )
                delta += 1
            elif points[i] == n:
                var q = delta
                var k = _BASE
                while True:
                    var t = _threshold(k, bias)
                    if q < t:
                        break
                    out += chr(Int(_digit_to_byte(t + ((q - t) % (_BASE - t)))))
                    q = (q - t) // (_BASE - t)
                    k += _BASE
                out += chr(Int(_digit_to_byte(q)))
                bias = _adapt(delta, handled + 1, handled == basic_count)
                delta = 0
                handled += 1
        delta += 1
        n += 1

    return out^


def punycode_decode(encoded: StringSpan) raises -> String:
    """Decode one punycode label, without the `xn--` prefix."""
    var points = punycode_decode_points(encoded)
    var text = String()
    for index in range(len(points)):
        text += chr(Int(points[index]))
    return text^


def punycode_decode_points(encoded: StringSpan) raises -> List[UInt32]:
    """Decode one punycode label to code points, without the `xn--` prefix.

    RFC 3492 section 6.2. Every arithmetic step that can overflow is checked,
    because this runs on a name that arrived from outside and the failure mode of
    an unchecked version is a label that decodes to a name nobody wrote.
    """
    var bytes = encoded.as_bytes()
    var output = List[UInt32]()

    # Everything before the last hyphen is literal. The last one is the
    # delimiter, which is why a label may contain hyphens of its own.
    var last_hyphen = -1
    for i in range(bytes.__len__()):
        if bytes[i] == UInt8(ord("-")):
            last_hyphen = i

    var start = 0
    if last_hyphen >= 0:
        for i in range(last_hyphen):
            if bytes[i] >= UInt8(0x80):
                raise new_error(
                    ErrorKind.INVALID_URL,
                    String(
                        (
                            "non ASCII byte in the literal part of a punycode"
                            " label"
                        ),
                        " ",
                        _quote(bytes),
                    ),
                )
            output.append(UInt32(bytes[i]))
        start = last_hyphen + 1

    var n = UInt32(_INITIAL_N)
    var i = 0
    var bias = _INITIAL_BIAS
    var pos = start

    while pos < bytes.__len__():
        var old_i = i
        var w = 1
        var k = _BASE
        while True:
            if pos >= bytes.__len__():
                raise new_error(
                    ErrorKind.INVALID_URL,
                    String("truncated punycode label ", _quote(bytes)),
                )
            var digit = _byte_to_digit(bytes[pos])
            if digit < 0:
                raise new_error(
                    ErrorKind.INVALID_URL,
                    String(
                        "invalid punycode digit ",
                        _quote(bytes[pos : pos + 1]),
                        " in ",
                        _quote(bytes),
                    ),
                )
            pos += 1
            if digit > (Int.MAX - i) // w:
                raise new_error(
                    ErrorKind.INVALID_URL,
                    String("punycode overflow decoding ", _quote(bytes)),
                )
            i += digit * w
            var t = _threshold(k, bias)
            if digit < t:
                break
            if w > Int.MAX // (_BASE - t):
                raise new_error(
                    ErrorKind.INVALID_URL,
                    String("punycode overflow decoding ", _quote(bytes)),
                )
            w *= _BASE - t
            k += _BASE

        var out_len = len(output) + 1
        bias = _adapt(i - old_i, out_len, old_i == 0)
        var advance = i // out_len
        if UInt32(advance) > _MAX_CODEPOINT - n:
            raise new_error(
                ErrorKind.INVALID_URL,
                String("punycode overflow decoding ", _quote(bytes)),
            )
        n += UInt32(advance)
        i = i % out_len

        # Surrogates have no meaning outside UTF-16 and cannot be encoded as
        # UTF-8, so a label that decodes to one is malformed rather than exotic.
        if n >= UInt32(0xD800) and n <= UInt32(0xDFFF):
            raise new_error(
                ErrorKind.INVALID_URL,
                String("punycode label decodes to a surrogate ", _quote(bytes)),
            )
        output.insert(i, n)
        i += 1

    return output^


def encode_host(host: StringSpan) raises -> String:
    """The A-label form of `host`, which is what DNS and `Host` want.

    An all ASCII name with no punycode in it is lowercased and returned, which is
    the overwhelmingly common case and costs one pass. That shortcut is exactly
    UTS-46 for such a name: the only thing the mapping table does to ASCII is
    lower case letters, and STD3 rules reject everything outside letters, digits
    and hyphens, which is what `_is_ascii_host_byte` says. A label that already
    begins with `xn--` is not on that path, because what it decodes to still has
    to be checked.
    """
    if host.byte_length() == 0:
        return String("")

    var bytes = host.as_bytes()
    if _is_plain_ascii(bytes):
        var out = String()
        for i in range(bytes.__len__()):
            if not _is_ascii_host_byte(bytes[i]):
                raise new_error(
                    ErrorKind.INVALID_URL,
                    String(
                        "invalid character ",
                        _quote(bytes[i : i + 1]),
                        " in hostname ",
                        _quote(bytes),
                    ),
                )
            out += chr(Int(to_lower(bytes[i])))
        _check_lengths(out, bytes)
        return out^

    return _uts46_to_ascii(host)


def _is_plain_ascii[o: ImmOrigin](bytes: Span[UInt8, o]) -> Bool:
    """Whether `bytes` can take the short path through `encode_host`."""
    var at = 0
    var label_start = 0
    while at < bytes.__len__():
        if bytes[at] >= UInt8(0x80):
            return False
        if at == label_start and _has_prefix_at(bytes, at):
            return False
        if bytes[at] == UInt8(ord(".")):
            label_start = at + 1
        at += 1
    return True


def _uts46_to_ascii(host: StringSpan) raises -> String:
    """`host` through the whole of UTS-46, ending in A-labels.

    The four steps of UTS-46 section 4 in order: map, normalize, break into
    labels, then convert and validate each one. The order is not negotiable.
    Mapping before normalizing is what makes a fullwidth letter and the letter it
    looks like the same host, and normalizing before splitting is what stops a
    combining sequence that straddles a dot being normalized into a different
    number of labels.
    """
    var mapped = _map_and_normalize(host)

    var labels = List[List[UInt32]]()
    var current = List[UInt32]()
    for i in range(len(mapped)):
        if mapped[i] == _FULL_STOP:
            labels.append(current^)
            current = List[UInt32]()
        else:
            current.append(mapped[i])
    labels.append(current^)

    # A label that arrived as punycode is decoded here, before anything is
    # decided about the name, because the bidi rule reads the whole domain and an
    # RTL label hidden inside an `xn--` label still makes it a bidi domain. How
    # each one was spelled is kept, so that what it encodes back to can be
    # checked against what was written.
    var spelling = List[String]()
    for i in range(len(labels)):
        if _is_encoded_label(labels[i]):
            var decoded = _decode_label(labels[i])
            spelling.append(_ascii_of(labels[i]))
            labels[i] = decoded^
        else:
            spelling.append(String())

    var bidi_domain = False
    for i in range(len(labels)):
        if _has_rtl(labels[i]):
            bidi_domain = True
            break

    var out = String()
    for i in range(len(labels)):
        if i > 0:
            out += "."
        # An empty label is left to `_check_lengths`, which is the one place that
        # knows a trailing dot is the root and an empty label anywhere else is a
        # name with a hole in it.
        if len(labels[i]) == 0:
            continue
        _validate_label(labels[i], bidi_domain, host)
        var encoded = _to_a_label(labels[i], host)
        # RFC 5891 section 4.4. An A-label has exactly one spelling, the one the
        # encoder produces. A label that decodes fine but encodes back to
        # something else was not written by an encoder, and accepting it would
        # give the same name two forms that no longer compare equal.
        if spelling[i].byte_length() > 0 and encoded != spelling[i]:
            raise new_error(
                ErrorKind.INVALID_URL,
                String(
                    "the label ",
                    spelling[i],
                    " is not how punycode spells what it decodes to: ",
                    _quote(host.as_bytes()),
                ),
            )
        out += encoded

    _check_lengths(out, host.as_bytes())
    return out^


def _map_and_normalize(host: StringSpan) raises -> List[UInt32]:
    """UTS-46 steps one and two: the mapping table, then NFC."""
    var out = List[UInt32]()
    for codepoint in host.codepoints():
        var point = codepoint.to_u32()
        var status = idna_status(point)
        if status == DISALLOWED:
            raise new_error(
                ErrorKind.INVALID_URL,
                String(
                    "U+",
                    _codepoint_hex(point),
                    " is not allowed in a hostname: ",
                    _quote(host.as_bytes()),
                ),
            )
        if status == IGNORED:
            continue
        if status == MAPPED:
            for mapped in idna_mapping(point).codepoints():
                out.append(mapped.to_u32())
            continue
        out.append(point)
    return nfc(out)


def _is_encoded_label(label: List[UInt32]) -> Bool:
    """Whether `label` starts with `xn--`.

    The label has been through the mapping table by now, so the prefix is already
    lower case and there is no case to fold here.
    """
    if len(label) < 4:
        return False
    var prefix = _PREFIX.as_bytes()
    for i in range(4):
        if label[i] != UInt32(prefix[i]):
            return False
    return True


def _decode_label(label: List[UInt32]) raises -> List[UInt32]:
    """The characters an `xn--` label stands for.

    Everything an A-label contains must be ASCII, so a non ASCII character in one
    is a name written two ways at once and there is no reading of it to pick.
    """
    var text = String()
    for i in range(4, len(label)):
        if label[i] >= UInt32(0x80):
            raise new_error(
                ErrorKind.INVALID_URL,
                String("a punycode label contains a non ASCII character"),
            )
        text += chr(Int(label[i]))
    var decoded = punycode_decode_points(text)
    if len(decoded) == 0:
        raise new_error(
            ErrorKind.INVALID_URL,
            String("a punycode label that stands for nothing"),
        )
    # An A-label has one spelling. If what it decodes to is not already
    # normalized then the same name has a second encoding, and two spellings of
    # one host is the thing this whole layer exists to prevent.
    var normalized = nfc(decoded)
    if len(normalized) != len(decoded):
        raise new_error(
            ErrorKind.INVALID_URL,
            String("a punycode label that decodes to an unnormalized name"),
        )
    for i in range(len(decoded)):
        if normalized[i] != decoded[i]:
            raise new_error(
                ErrorKind.INVALID_URL,
                String("a punycode label that decodes to an unnormalized name"),
            )
    # UTS-46 section 4.1, the criterion that applies when CheckHyphens is off. A
    # label that decodes to another `xn--` label is encoded twice, and which of
    # the two names it is depends on how many times the reader decodes it.
    if _is_encoded_label(decoded):
        raise new_error(
            ErrorKind.INVALID_URL,
            String("a punycode label that decodes to another punycode label"),
        )
    return decoded^


def _ascii_of(label: List[UInt32]) -> String:
    """`label` as text, for a label already known to hold only ASCII."""
    var out = String()
    for i in range(len(label)):
        out += chr(Int(label[i]))
    return out^


def _has_rtl(label: List[UInt32]) -> Bool:
    """Whether `label` makes the name a bidi domain name, per RFC 5893."""
    for i in range(len(label)):
        var kind = bidi_class(label[i])
        if kind == _BIDI_R or kind == _BIDI_AL or kind == _BIDI_AN:
            return True
    return False


def _validate_label(
    label: List[UInt32], bidi_domain: Bool, host: StringSpan
) raises:
    """UTS-46 section 4.1, with the flags this library fixes.

    CheckHyphens is off, matching the URL Standard, so a label may start or end
    with a hyphen. The rest are on. V1 and V4 hold by construction, since the
    name was normalized before it was split and it was split on the only
    character V4 forbids.
    """
    if is_mark(label[0]):
        raise new_error(
            ErrorKind.INVALID_URL,
            String(
                "a hostname label starts with a combining mark: ",
                _quote(host.as_bytes()),
            ),
        )
    for i in range(len(label)):
        # STD3 ASCII rules. Unicode 17 folded the two disallowed_STD3 statuses
        # into valid and mapped, so the mapping table no longer says which ASCII
        # characters a hostname may hold and the range is checked here instead.
        # Without this a name comes out with a space or a percent sign in it,
        # which is a name the rest of this library would have to escape and a
        # resolver would refuse.
        if label[i] < UInt32(0x80) and not _is_std3_byte(UInt8(label[i])):
            raise new_error(
                ErrorKind.INVALID_URL,
                String(
                    "U+",
                    _codepoint_hex(label[i]),
                    " is not allowed in a hostname: ",
                    _quote(host.as_bytes()),
                ),
            )
        if idna_status(label[i]) != VALID:
            raise new_error(
                ErrorKind.INVALID_URL,
                String(
                    "U+",
                    _codepoint_hex(label[i]),
                    " is not allowed in a hostname: ",
                    _quote(host.as_bytes()),
                ),
            )
    _check_joiners(label, host)
    if bidi_domain:
        _check_bidi(label, host)


def _check_joiners(label: List[UInt32], host: StringSpan) raises:
    """RFC 5892 appendix A.1 and A.2, the rules for the two invisible joiners.

    Both characters are zero width, so a name containing one looks exactly like
    the name without it. They are allowed only where they change how the
    neighbouring letters are drawn, which is the only place they mean anything.
    """
    for i in range(len(label)):
        if label[i] != _ZWNJ and label[i] != _ZWJ:
            continue
        # After a virama both are what joins the letters either side, and that
        # is written the same way in every script that uses one.
        if i > 0 and combining_class(label[i - 1]) == _VIRAMA:
            continue
        if label[i] == _ZWNJ and _joins_across(label, i):
            continue
        raise new_error(
            ErrorKind.INVALID_URL,
            String(
                "a zero width joiner appears where it joins nothing: ",
                _quote(host.as_bytes()),
            ),
        )


def _joins_across(label: List[UInt32], at: Int) -> Bool:
    """Whether the non joiner at `at` sits between two letters that would join.

    Transparent characters on either side are stepped over, since they are the
    marks that sit above and below and do not take part in joining.
    """
    var before = at - 1
    while before >= 0 and joining_type(label[before]) == _JOIN_T:
        before -= 1
    if before < 0:
        return False
    var left = joining_type(label[before])
    if left != _JOIN_L and left != _JOIN_D:
        return False

    var after = at + 1
    while after < len(label) and joining_type(label[after]) == _JOIN_T:
        after += 1
    if after >= len(label):
        return False
    var right = joining_type(label[after])
    return right == _JOIN_R or right == _JOIN_D


def _check_bidi(label: List[UInt32], host: StringSpan) raises:
    """The Bidi Rule of RFC 5893 section 2.

    A name that mixes directions can be written so that what a person reads is
    not the order the bytes are in, which is how one name is made to look like
    another. The rule is a set of restrictions per label that make the displayed
    order follow from the label alone.
    """
    var first = bidi_class(label[0])
    var rtl: Bool
    if first == _BIDI_R or first == _BIDI_AL:
        rtl = True
    elif first == _BIDI_L:
        rtl = False
    else:
        raise _bad_bidi(host)

    var seen_number = False
    var seen_arabic_number = False
    var ends_well = False
    for i in range(len(label)):
        var kind = bidi_class(label[i])
        if rtl:
            if not (
                kind == _BIDI_R
                or kind == _BIDI_AL
                or kind == _BIDI_AN
                or kind == _BIDI_EN
                or kind == _BIDI_ES
                or kind == _BIDI_CS
                or kind == _BIDI_ET
                or kind == _BIDI_ON
                or kind == _BIDI_BN
                or kind == _BIDI_NSM
            ):
                raise _bad_bidi(host)
        else:
            if not (
                kind == _BIDI_L
                or kind == _BIDI_EN
                or kind == _BIDI_ES
                or kind == _BIDI_CS
                or kind == _BIDI_ET
                or kind == _BIDI_ON
                or kind == _BIDI_BN
                or kind == _BIDI_NSM
            ):
                raise _bad_bidi(host)
        if kind == _BIDI_EN:
            seen_number = True
        elif kind == _BIDI_AN:
            seen_arabic_number = True
        # Trailing marks do not count as the end of the label, so the answer is
        # recomputed for every character that is not one and the last write wins.
        if kind != _BIDI_NSM:
            if rtl:
                ends_well = (
                    kind == _BIDI_R
                    or kind == _BIDI_AL
                    or kind == _BIDI_EN
                    or kind == _BIDI_AN
                )
            else:
                ends_well = kind == _BIDI_L or kind == _BIDI_EN

    if not ends_well:
        raise _bad_bidi(host)
    if rtl and seen_number and seen_arabic_number:
        # European and Arabic digits in one label render in an order that
        # depends on which came first, so a name with both has no fixed reading.
        raise _bad_bidi(host)


def _bad_bidi(host: StringSpan) -> Error:
    return new_error(
        ErrorKind.INVALID_URL,
        String(
            "a hostname label breaks the right to left rules: ",
            _quote(host.as_bytes()),
        ),
    )


def _to_a_label(label: List[UInt32], host: StringSpan) raises -> String:
    """One validated label as ASCII, punycoded if it needs to be."""
    var ascii_only = True
    for i in range(len(label)):
        if label[i] >= UInt32(0x80):
            ascii_only = False
            break
    if ascii_only:
        var out = String()
        for i in range(len(label)):
            out += chr(Int(label[i]))
        return out^

    var encoded = String(_PREFIX, punycode_encode_points(label))
    if encoded.byte_length() > MAX_LABEL:
        raise new_error(
            ErrorKind.INVALID_URL,
            String(
                "hostname label is ",
                encoded.byte_length(),
                " bytes encoded, over the ",
                MAX_LABEL,
                " byte limit: ",
                _quote(host.as_bytes()),
            ),
        )
    return encoded^


def _codepoint_hex(point: UInt32) -> String:
    comptime DIGITS = StaticString("0123456789ABCDEF")
    var out = String()
    var started = False
    for step in range(6):
        var shift = UInt32(20 - step * 4)
        var nibble = Int((point >> shift) & UInt32(15))
        if nibble != 0 or started or step >= 2:
            started = True
            # Sound because `nibble` is four bits masked out of a UInt32, so it
            # is 0 to 15 and indexes a sixteen byte ASCII literal in range.
            out += StringSpan(
                unsafe_from_utf8=DIGITS.as_bytes()[nibble : nibble + 1]
            )
    return out^


def _check_lengths[o: ImmOrigin](name: String, original: Span[UInt8, o]) raises:
    """Enforce the DNS length limits on an encoded name.

    A trailing dot is the explicit root and does not count against the total,
    which is why the check subtracts it rather than rejecting it. Every other
    empty label is an error, because `a..b` reads as one host to a person and is
    a name no resolver will answer.
    """
    var length = name.byte_length()
    if length > 0 and name.as_bytes()[length - 1] == UInt8(ord(".")):
        length -= 1
    if length > MAX_NAME:
        raise new_error(
            ErrorKind.INVALID_URL,
            String(
                "hostname is ",
                length,
                " bytes, over the ",
                MAX_NAME,
                " byte limit: ",
                _quote(original),
            ),
        )
    var labels = name.split(".")
    for i in range(len(labels)):
        ref label = labels[i]
        if label.byte_length() == 0:
            if i == len(labels) - 1 and i > 0:
                continue
            raise new_error(
                ErrorKind.INVALID_URL,
                String("empty label in hostname ", _quote(original)),
            )
        if label.byte_length() > MAX_LABEL:
            raise new_error(
                ErrorKind.INVALID_URL,
                String(
                    "hostname label is ",
                    label.byte_length(),
                    " bytes, over the ",
                    MAX_LABEL,
                    " byte limit: ",
                    _quote(original),
                ),
            )


def decode_host(host: StringSpan) raises -> String:
    """The U-label form of `host`, which is what to show a person.

    A label without the `xn--` prefix is passed through unchanged. This is for
    display only. Nothing that decides where a request goes, or what a cookie is
    scoped to, may use the result, because two different A-labels can present the
    same way to a reader.
    """
    var out = String()
    var first = True
    for label in host.split("."):
        if not first:
            out += "."
        first = False
        if label.byte_length() > 4 and _has_prefix(label):
            out += punycode_decode(label[byte = 4 : label.byte_length()])
        else:
            out += label
    return out^


def _has_prefix(label: StringSpan) -> Bool:
    """Whether `label` starts with `xn--`, ignoring case."""
    return _has_prefix_at(label.as_bytes(), 0)


def _has_prefix_at[o: ImmOrigin](bytes: Span[UInt8, o], at: Int) -> Bool:
    """Whether `xn--` starts at `at` in `bytes`, ignoring case."""
    if at + 4 > bytes.__len__():
        return False
    var prefix = _PREFIX.as_bytes()
    for i in range(4):
        if to_lower(bytes[at + i]) != prefix[i]:
            return False
    return True
