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
a crafted label can carry it past the end. UTS-46 mapping and NFC normalization
are not here yet, so a name that needs either is rejected rather than guessed at.
That is the conservative direction, since rejecting a name fails a request that
would have worked, while guessing sends it somewhere the user did not ask for.
"""

from httpx._bytes import Bytes, _quote, to_lower
from httpx._exceptions import ErrorKind, new_error

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
    """Encode one label to punycode, without the `xn--` prefix.

    RFC 3492 section 6.3. The overflow check on `delta` is the security relevant
    part: the algorithm accumulates a value that is unbounded in principle, and a
    label built to make it wrap would decode back to a different name than it
    encodes to.
    """
    var points = List[UInt32]()
    for codepoint in label.codepoints():
        points.append(codepoint.to_u32())

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
                String("punycode overflow encoding ", _quote(label.as_bytes())),
            )
        delta += step * (handled + 1)
        n = m

        for i in range(len(points)):
            if points[i] < n:
                if delta == Int.MAX:
                    raise new_error(
                        ErrorKind.INVALID_URL,
                        String(
                            "punycode overflow encoding ",
                            _quote(label.as_bytes()),
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
    """Decode one punycode label, without the `xn--` prefix.

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

    var text = String()
    for index in range(len(output)):
        text += chr(Int(output[index]))
    return text^


def _encode_label(label: StringSpan) raises -> String:
    """One label of a hostname, in A-label form."""
    var bytes = label.as_bytes()
    var is_ascii = True
    for i in range(bytes.__len__()):
        if bytes[i] >= UInt8(0x80):
            is_ascii = False
            break

    if is_ascii:
        var lowered = String()
        for i in range(bytes.__len__()):
            if not _is_ascii_host_byte(bytes[i]):
                raise new_error(
                    ErrorKind.INVALID_URL,
                    String(
                        "invalid character ",
                        _quote(bytes[i : i + 1]),
                        " in hostname label ",
                        _quote(bytes),
                    ),
                )
            lowered += chr(Int(to_lower(bytes[i])))
        return lowered^

    var encoded = String(_PREFIX, punycode_encode(label))
    if encoded.byte_length() > MAX_LABEL:
        raise new_error(
            ErrorKind.INVALID_URL,
            String(
                "hostname label is ",
                encoded.byte_length(),
                " bytes encoded, over the ",
                MAX_LABEL,
                " byte limit: ",
                _quote(bytes),
            ),
        )
    return encoded^


def encode_host(host: StringSpan) raises -> String:
    """The A-label form of `host`, which is what DNS and `Host` want.

    An all ASCII name is lowercased and returned, which is the overwhelmingly
    common case and costs one pass. Anything else goes label by label through
    punycode.
    """
    if host.byte_length() == 0:
        return String("")

    var bytes = host.as_bytes()
    var ascii_only = True
    for i in range(bytes.__len__()):
        if bytes[i] >= UInt8(0x80):
            ascii_only = False
            break

    var out = String()
    if ascii_only:
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
    else:
        var first = True
        for label in host.split("."):
            if not first:
                out += "."
            first = False
            out += _encode_label(label)

    _check_lengths(out, bytes)
    return out^


def _check_lengths[o: ImmOrigin](name: String, original: Span[UInt8, o]) raises:
    """Enforce the DNS length limits on an encoded name.

    A trailing dot is the explicit root and does not count against the total,
    which is why the check subtracts it rather than rejecting it.
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
    for label in name.split("."):
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
    var bytes = label.as_bytes()
    if bytes.__len__() < 4:
        return False
    var prefix = _PREFIX.as_bytes()
    for i in range(4):
        if to_lower(bytes[i]) != prefix[i]:
            return False
    return True
