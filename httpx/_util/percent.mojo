"""Percent encoding, one character set per URL component.

The thing that makes this worth its own module is that there is no single answer
to "is this character safe". A `?` is data inside a path and a delimiter inside a
query. A `+` is a literal plus inside a path and a space inside a form encoded
query value. Encoding a URL with one table for the whole string is the bug that
produces `https://example.com/a%2Fb` when the caller wrote a two segment path,
and the bug that turns a `&` inside a query value into a parameter separator. So
the sets live here, named after the component they belong to, and every caller
has to say which one it means.

The two query regimes are the pair most often conflated. `QUERY` is for a query
string that is already assembled and whose `&` and `=` are structure to preserve.
`FORM` is for a single key or value going into one, where `&` and `=` are data
and must not survive as structure. `QueryParams` uses `FORM`; assigning a whole
query string uses `QUERY`.
"""

from httpx._bytes import Bytes, _quote
from httpx._exceptions import ErrorKind, new_error

comptime _DIGITS = StaticString("0123456789ABCDEF")

# RFC 3986 section 2.3. These never need encoding and, just as importantly, must
# be decoded when they appear encoded, because `%41` and `A` are the same URL and
# two spellings of one URL breaks comparison and caching.
comptime _UNRESERVED_CHARS = StaticString(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
)


struct CharSet(ImplicitlyCopyable, Movable):
    """Which byte values a component may carry without being escaped.

    A 256 bit set held in four registers, so membership is a shift and a mask
    rather than a scan of a string of safe characters. Every byte of every URL
    goes through this, which is the only reason it is worth the four words.
    """

    var _bits: SIMD[DType.uint64, 4]

    def __init__(out self, chars: StaticString):
        """Build a set containing exactly the bytes of `chars`."""
        self._bits = SIMD[DType.uint64, 4](0)
        var bytes = chars.as_bytes()
        for i in range(bytes.__len__()):
            var value = Int(bytes[i])
            self._bits[value >> 6] |= UInt64(1) << UInt64(value & 63)

    def __contains__(self, byte: UInt8) -> Bool:
        var value = Int(byte)
        return (self._bits[value >> 6] >> UInt64(value & 63)) & UInt64(
            1
        ) == UInt64(1)

    def __or__(self, other: Self) -> Self:
        """The union, so a component set can be written as unreserved plus extras.

        Spelling each set out in full would mean repeating the sixty six
        unreserved characters six times, and a typo in one copy would be a
        component that silently encodes differently from the rest.
        """
        var result = self
        result._bits |= other._bits
        return result


comptime UNRESERVED = CharSet(_UNRESERVED_CHARS)

# The sub-delims and the component delimiters each component tolerates, from RFC
# 3986 section 3.3 for the path and 3.4 for the query. A `/` is left alone in the
# path because it is the segment separator, and in the query because RFC 3986
# explicitly permits it there and encoding it breaks paths carried in a query.
comptime PATH = UNRESERVED | CharSet("!$&'()*+,;=:@/")
comptime QUERY = UNRESERVED | CharSet("!$&'()*+,;=:@/?")
comptime FRAGMENT = UNRESERVED | CharSet("!$&'()*+,;=:@/?")

# No `:` and no `@`. Both terminate the userinfo, so a password containing either
# one has to be escaped or it moves the host.
comptime USERINFO = UNRESERVED | CharSet("!$&'()*+,;=")

# One key or one value of a form encoded query. Nothing beyond unreserved is
# safe, because every sub-delim is either a separator or, in the case of `+`, a
# space in disguise.
comptime FORM = UNRESERVED


def _hex_value(byte: UInt8) -> Int:
    """The value of one hex digit, or -1 if it is not one."""
    if byte >= UInt8(ord("0")) and byte <= UInt8(ord("9")):
        return Int(byte) - ord("0")
    if byte >= UInt8(ord("a")) and byte <= UInt8(ord("f")):
        return Int(byte) - ord("a") + 10
    if byte >= UInt8(ord("A")) and byte <= UInt8(ord("F")):
        return Int(byte) - ord("A") + 10
    return -1


def _decode_escape[
    o: ImmOrigin
](source: Span[UInt8, o], at: Int) raises -> UInt8:
    """The byte encoded by the escape starting at `at`, which must be a `%`.

    Every decoder needs this and they must all reject the same things, so it is
    written once. A `%` that is not followed by two hex digits raises rather than
    being passed through. Passing it through is what most implementations do, and
    it means two of them reading the same URL disagree about where a path segment
    ends, which is the shape of a path traversal that gets past a proxy.
    """
    if at + 2 >= source.__len__():
        raise new_error(
            ErrorKind.INVALID_URL,
            String("truncated percent escape at the end of ", _quote(source)),
        )
    var high = _hex_value(source[at + 1])
    var low = _hex_value(source[at + 2])
    if high < 0 or low < 0:
        raise new_error(
            ErrorKind.INVALID_URL,
            String(
                "malformed percent escape ",
                _quote(source[at : at + 3]),
                " in ",
                _quote(source),
            ),
        )
    return UInt8((high << 4) | low)


def _write_escape(mut out: Bytes, byte: UInt8):
    """Append one byte as `%XX`, upper case.

    RFC 3986 section 6.2.2.1 says the hex digits are case insensitive but that
    upper case is the normal form. Picking one and always producing it is what
    lets two URLs be compared as strings.
    """
    out.append(UInt8(ord("%")))
    out.append(UInt8(_DIGITS.as_bytes()[Int(byte) >> 4]))
    out.append(UInt8(_DIGITS.as_bytes()[Int(byte) & 15]))


def percent_encode[
    o: ImmOrigin
](source: Span[UInt8, o], safe: CharSet) raises -> Bytes:
    """Escape every byte of `source` that `safe` does not permit.

    An existing `%` is escaped to `%25` like any other unsafe byte, because this
    function is for a value that is not yet encoded. Passing it something already
    encoded double encodes it, which is correct: there is no way to tell a literal
    percent from the start of an escape, and guessing is how a filename with a
    percent in it becomes a different filename.
    """
    var out = Bytes.with_capacity(source.__len__())
    for i in range(source.__len__()):
        var byte = source[i]
        if byte in safe:
            out.append(byte)
        else:
            _write_escape(out, byte)
    return out^


def percent_decode[o: ImmOrigin](source: Span[UInt8, o]) raises -> Bytes:
    """Undo percent encoding, refusing anything malformed."""
    var out = Bytes.with_capacity(source.__len__())
    var i = 0
    while i < source.__len__():
        var byte = source[i]
        if byte != UInt8(ord("%")):
            out.append(byte)
            i += 1
            continue
        out.append(_decode_escape(source, i))
        i += 3
    return out^


def percent_normalize[
    o: ImmOrigin
](source: Span[UInt8, o], safe: CharSet) raises -> Bytes:
    """Rewrite `source` so that equal URLs are equal strings.

    Unlike `percent_encode` this treats an existing escape as an escape. Escapes
    of unreserved characters are decoded, every other escape is rewritten with
    upper case digits, and an unescaped byte outside `safe` is escaped. That
    makes the result idempotent, which is the property the whole normalization
    story rests on: running it twice has to give what running it once gave, or
    `URL(String(u)) == u` is false and every cache keyed on a URL has two entries
    for one resource.

    A malformed escape raises rather than being copied through, for the same
    reason it does in `percent_decode`.
    """
    var out = Bytes.with_capacity(source.__len__())
    var i = 0
    while i < source.__len__():
        var byte = source[i]
        if byte != UInt8(ord("%")):
            if byte in safe:
                out.append(byte)
            else:
                _write_escape(out, byte)
            i += 1
            continue
        var decoded = _decode_escape(source, i)
        # Only unreserved characters may be unescaped. Decoding a reserved one
        # would change what the URL means: `%2F` in a path segment is a slash in
        # a name, and turning it into `/` invents a segment boundary.
        if decoded in UNRESERVED:
            out.append(decoded)
        else:
            _write_escape(out, decoded)
        i += 3
    return out^


def form_encode[o: ImmOrigin](source: Span[UInt8, o]) raises -> Bytes:
    """Encode one form key or value, with space as `+`.

    The `+` convention is not in RFC 3986. It comes from HTML form submission and
    is what every server decoding a query string expects, so a space has to
    become `+` here even though it would become `%20` anywhere else in the URL.
    A literal `+` becomes `%2B`, which is what keeps the two apart.
    """
    var out = Bytes.with_capacity(source.__len__())
    for i in range(source.__len__()):
        var byte = source[i]
        if byte == UInt8(ord(" ")):
            out.append(UInt8(ord("+")))
        elif byte in FORM:
            out.append(byte)
        else:
            _write_escape(out, byte)
    return out^


def form_decode[o: ImmOrigin](source: Span[UInt8, o]) raises -> Bytes:
    """Decode one form key or value, reading `+` as a space."""
    var out = Bytes.with_capacity(source.__len__())
    var i = 0
    while i < source.__len__():
        var byte = source[i]
        if byte == UInt8(ord("+")):
            out.append(UInt8(ord(" ")))
            i += 1
            continue
        if byte != UInt8(ord("%")):
            out.append(byte)
            i += 1
            continue
        out.append(_decode_escape(source, i))
        i += 3
    return out^
