"""Decoding a response body into text, given a charset label.

```mojo
var text = decode_charset(Span(body), "iso-8859-1")
```

Nothing here raises. A body that does not decode still deserves to be shown, so
every undecodable byte becomes U+FFFD, which is what Python's `errors="replace"`
does and therefore what httpx2 gives back from `Response.text`. The strict path
is still there for anyone who wants it: `Bytes.to_string` refuses invalid UTF-8
and the JSON parser refuses it too, so a caller who needs to know keeps a way to
find out.

## Which encodings

UTF-8, UTF-16 and UTF-32 in both byte orders and with a byte order mark, Latin-1,
Windows-1252 and ASCII. That is the set that appears on HTTP responses in
practice, and everything in it is a table lookup or arithmetic rather than a
database.

Anything else is unknown, which is not an error: an unknown label falls back to
`default_encoding` the same way a missing one does. httpx2 knows every codec
Python ships, so a `Shift_JIS` body is one place this reads a body differently,
and that is written down in docs/deviations.md rather than left to be discovered.

## Labels are matched loosely

`UTF-8`, `utf8`, `utf_8` and even `'utf-8'` with the quotes still attached all
mean UTF-8, because Python's codec lookup accepts all four and a server that
sends any of them is not trying to be difficult. Matching is on the letters and
digits only, which gets all of them without a list of spellings.

## Replacing invalid UTF-8

One U+FFFD per maximal subpart, which is the Unicode recommended practice and
what Python does. The rule is that a broken sequence consumes the longest prefix
that could still have become valid, so `E1 80 E2` is two replacements and not
three: `E1 80` was on its way to being a three byte character until `E2` arrived.
Getting this wrong is not a crash, it is a different string, which is exactly the
kind of difference a parity suite exists to catch.
"""

from httpx._bytes import append_codepoint, to_lower, utf8_length, utf8_width

comptime UNKNOWN = 0
comptime UTF_8 = 1
comptime UTF_16 = 2
comptime UTF_16LE = 3
comptime UTF_16BE = 4
comptime UTF_32 = 5
comptime UTF_32LE = 6
comptime UTF_32BE = 7
comptime LATIN_1 = 8
comptime WINDOWS_1252 = 9
comptime ASCII = 10

comptime REPLACEMENT = UInt32(0xFFFD)
comptime BOM = UInt32(0xFEFF)

comptime DEFAULT_CHARSET = StaticString("utf-8")
"""What a body is read as when nothing says otherwise.

RFC 9110 has no default charset for `text/*` any more, and the old RFC 2616
answer of Latin-1 is wrong for essentially every response sent this decade. UTF-8
is what httpx2 falls back to and it is what the content almost always is.
"""


comptime CharsetDetector = def(List[UInt8]) raises thin -> String
"""A function that guesses an encoding by looking at the bytes.

The shape httpx2's `default_encoding` takes when it is given a callable, which
is how `charset_normalizer` gets plugged in there. Nothing in this library
implements one, because statistical charset detection is a corpus and a model
rather than a function, and shipping a bad one would be worse than shipping
none. The hook is here so that a caller who has one can use it.
"""


struct DefaultEncoding(Copyable, Movable):
    """What to read a body as when the response does not say.

    Either a fixed name or a detector, matching the two things httpx2 accepts for
    `default_encoding`. Mojo has no union type, so this is a struct with one of
    the two set, and the constructors are what keep a caller from setting both.
    """

    var name: String
    var detect: Optional[CharsetDetector]

    def __init__(out self, name: StringSpan = DEFAULT_CHARSET):
        self.name = String(name)
        self.detect = None

    def __init__(out self, detect: CharsetDetector):
        self.name = String(DEFAULT_CHARSET)
        self.detect = detect

    def copy(self) -> Self:
        var out = Self(self.name)
        out.detect = self.detect
        return out^

    def resolve(self, content: List[UInt8]) raises -> String:
        """The encoding to try, given the body that is about to be read."""
        if self.detect:
            return self.detect.value()(content)
        return self.name.copy()


def normalize_label(label: StringSpan) -> String:
    """Reduce a charset label to the letters and digits in it, lowercased.

    `UTF-8`, `utf_8` and `'utf-8'` all come out as `utf8`. Python's codec lookup
    is this loose, so a server sending any of those spellings gets the encoding
    it meant out of httpx2, and matching that is the point.
    """
    var out = String()
    for byte in label.as_bytes():
        var lowered = to_lower(byte)
        var digit = lowered >= UInt8(ord("0")) and lowered <= UInt8(ord("9"))
        var letter = lowered >= UInt8(ord("a")) and lowered <= UInt8(ord("z"))
        if digit or letter:
            out += chr(Int(lowered))
    return out^


def charset_id(label: StringSpan) -> Int:
    """Which decoder a label names, or `UNKNOWN`.

    The aliases are the ones Python's `encodings.aliases` carries for these
    encodings, minus the spellings that only differ by punctuation, which
    `normalize_label` has already removed.
    """
    var name = normalize_label(label)

    if (
        name == "utf8"
        or name == "utf"
        or name == "u8"
        or name == "cp65001"
        or name == "unicode11utf8"
        or name == "unicode20utf8"
        or name == "xunicode20utf8"
    ):
        return UTF_8

    if name == "utf16" or name == "u16":
        return UTF_16
    if name == "utf16le" or name == "unicodelittleunmarked":
        return UTF_16LE
    if name == "utf16be" or name == "unicodebigunmarked":
        return UTF_16BE

    if name == "utf32" or name == "u32":
        return UTF_32
    if name == "utf32le":
        return UTF_32LE
    if name == "utf32be":
        return UTF_32BE

    if (
        name == "latin1"
        or name == "latin"
        or name == "l1"
        or name == "iso88591"
        or name == "iso8859"
        or name == "8859"
        or name == "cp819"
        or name == "ibm819"
        or name == "isoir100"
        or name == "csisolatin1"
    ):
        return LATIN_1

    if (
        name == "windows1252"
        or name == "cp1252"
        or name == "xcp1252"
        or name == "1252"
        or name == "ms1252"
    ):
        return WINDOWS_1252

    if (
        name == "ascii"
        or name == "usascii"
        or name == "us"
        or name == "646"
        or name == "iso646us"
        or name == "isoir6"
        or name == "ansix341968"
        or name == "cp367"
        or name == "ibm367"
        or name == "csascii"
    ):
        return ASCII

    return UNKNOWN


def is_known_charset(label: StringSpan) -> Bool:
    """Whether a label names an encoding this can decode.

    The gate on whether a `charset` parameter is used at all. An unknown label
    falls back to `default_encoding`, which is what httpx2 does with a label
    Python has no codec for, so a header saying `charset=nonsense` reads the body
    the same way a header saying nothing does.
    """
    return charset_id(label) != UNKNOWN


def decode_charset[
    o: ImmOrigin
](bytes: Span[UInt8, o], label: StringSpan) -> String:
    """Decode `bytes` as `label`, replacing anything undecodable.

    An unknown label is read as UTF-8 rather than refused. The caller decides
    what an unknown label means, through `is_known_charset`, and by the time the
    bytes get here somebody has already decided this is the encoding to try.
    """
    var id = charset_id(label)
    if id == UNKNOWN:
        id = UTF_8
    return decode_by_id(bytes, id)


def decode_by_id[o: ImmOrigin](bytes: Span[UInt8, o], id: Int) -> String:
    if id == LATIN_1:
        return _decode_single(bytes, False)
    if id == WINDOWS_1252:
        return _decode_single(bytes, True)
    if id == ASCII:
        return _decode_ascii(bytes)
    if id == UTF_16LE:
        return _decode_utf16(bytes, False)
    if id == UTF_16BE:
        return _decode_utf16(bytes, True)
    if id == UTF_16:
        return _decode_utf16_bom(bytes)
    if id == UTF_32LE:
        return _decode_utf32(bytes, False)
    if id == UTF_32BE:
        return _decode_utf32(bytes, True)
    if id == UTF_32:
        return _decode_utf32_bom(bytes)
    return _decode_utf8(bytes)


def _finish(var out: List[UInt8]) -> String:
    """Wrap bytes this module built into a `String`.

    Sound because every byte in `out` was written by `append_codepoint`, which
    encodes one code point at a time and substitutes U+FFFD for anything it
    cannot encode. There is no path that puts a byte in here any other way, so
    the buffer is valid UTF-8 by construction and validating it again would only
    be walking it twice.
    """
    return String(StringSpan(unsafe_from_utf8=Span(out)))


def _decode_utf8[o: ImmOrigin](bytes: Span[UInt8, o]) -> String:
    var out = List[UInt8]()
    var n = bytes.__len__()
    var at = 0
    while at < n:
        var width = utf8_length(bytes, at)
        if width > 0:
            for i in range(at, at + width):
                out.append(bytes[i])
            at += width
        else:
            append_codepoint(out, REPLACEMENT)
            at += _subpart(bytes, at)
    return _finish(out^)


def _subpart[o: ImmOrigin](bytes: Span[UInt8, o], at: Int) -> Int:
    """How many bytes an invalid sequence at `at` swallows. Never less than one.

    The maximal subpart rule: consume the longest prefix that was still on its
    way to being a valid character, and stop at the first byte that proves it is
    not. That is what decides whether `E1 80 E2` is one replacement or two, and
    getting it wrong produces a different string rather than an error.
    """
    var n = bytes.__len__()
    var width = utf8_width(bytes[at])
    if width == 0:
        return 1

    # The second byte carries the range checks, so the bounds depend on the lead.
    # These are the same four special cases `utf8_length` applies, and they are
    # here rather than shared because that function answers a different question.
    var low = UInt8(0x80)
    var high = UInt8(0xBF)
    var lead = bytes[at]
    if lead == 0xE0:
        low = 0xA0
    elif lead == 0xED:
        high = 0x9F
    elif lead == 0xF0:
        low = 0x90
    elif lead == 0xF4:
        high = 0x8F

    if at + 1 >= n or bytes[at + 1] < low or bytes[at + 1] > high:
        return 1

    var taken = 2
    while taken < width and at + taken < n:
        if (bytes[at + taken] & 0xC0) != 0x80:
            break
        taken += 1
    return taken


def _decode_ascii[o: ImmOrigin](bytes: Span[UInt8, o]) -> String:
    var out = List[UInt8]()
    for i in range(bytes.__len__()):
        var byte = bytes[i]
        if byte < 0x80:
            out.append(byte)
        else:
            append_codepoint(out, REPLACEMENT)
    return _finish(out^)


comptime _CP1252_HIGH = SIMD[DType.uint32, 32](
    0x20AC,
    0xFFFD,
    0x201A,
    0x0192,
    0x201E,
    0x2026,
    0x2020,
    0x2021,
    0x02C6,
    0x2030,
    0x0160,
    0x2039,
    0x0152,
    0xFFFD,
    0x017D,
    0xFFFD,
    0xFFFD,
    0x2018,
    0x2019,
    0x201C,
    0x201D,
    0x2022,
    0x2013,
    0x2014,
    0x02DC,
    0x2122,
    0x0161,
    0x203A,
    0x0153,
    0xFFFD,
    0x017E,
    0x0178,
)
"""Code points for bytes 0x80 through 0x9F in Windows-1252.

The only range where Windows-1252 and Latin-1 differ. Latin-1 puts the C1
control characters here and Windows-1252 puts printable characters, which is why
a page labelled one and encoded as the other shows the wrong punctuation rather
than failing outright.

The five entries that are U+FFFD are the byte values Windows-1252 leaves
undefined: 0x81, 0x8D, 0x8F, 0x90 and 0x9D. Python's codec has no character for
them either and replaces them.
"""


def _decode_single[
    o: ImmOrigin
](bytes: Span[UInt8, o], windows: Bool) -> String:
    """Latin-1, or Windows-1252 when `windows` is set.

    One function because the two differ in exactly one range of thirty two
    bytes. Writing them separately would mean two copies of the part that is the
    same and one place for them to drift.
    """
    var out = List[UInt8]()
    for i in range(bytes.__len__()):
        var byte = bytes[i]
        if windows and byte >= 0x80 and byte <= 0x9F:
            append_codepoint(out, _CP1252_HIGH[Int(byte) - 0x80])
        else:
            append_codepoint(out, UInt32(byte))
    return _finish(out^)


def _unit16[o: ImmOrigin](bytes: Span[UInt8, o], at: Int, big: Bool) -> UInt32:
    if big:
        return (UInt32(bytes[at]) << 8) | UInt32(bytes[at + 1])
    return UInt32(bytes[at]) | (UInt32(bytes[at + 1]) << 8)


def _decode_utf16[o: ImmOrigin](bytes: Span[UInt8, o], big: Bool) -> String:
    var out = List[UInt8]()
    var n = bytes.__len__()
    var at = 0
    while at + 1 < n:
        var unit = _unit16(bytes, at, big)
        at += 2
        if unit >= 0xD800 and unit <= 0xDBFF:
            # A high surrogate is only half a character. Without its partner it
            # is not text and cannot be encoded, so it becomes one replacement
            # and the low surrogate that did not follow is read on its own terms.
            if at + 1 < n:
                var low = _unit16(bytes, at, big)
                if low >= 0xDC00 and low <= 0xDFFF:
                    at += 2
                    var point = (
                        0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                    )
                    append_codepoint(out, point)
                    continue
            append_codepoint(out, REPLACEMENT)
        elif unit >= 0xDC00 and unit <= 0xDFFF:
            append_codepoint(out, REPLACEMENT)
        else:
            append_codepoint(out, unit)
    if at < n:
        # An odd byte at the end. The stream was truncated mid character, which
        # is a real thing on a connection that dropped, so it is one replacement
        # rather than a discarded byte nobody is told about.
        append_codepoint(out, REPLACEMENT)
    return _finish(out^)


def _decode_utf16_bom[o: ImmOrigin](bytes: Span[UInt8, o]) -> String:
    """UTF-16 with the byte order taken from a mark, if there is one.

    No mark means little endian. RFC 2781 says big endian, Python uses the
    machine's own order, and every browser uses little endian, which is also
    what the overwhelming majority of unmarked UTF-16 on the web actually is.

    httpx2 raises here instead, because Python's `utf-16` codec refuses a stream
    with no mark and the `errors="replace"` setting does not cover that check.
    Refusing to read a body over a byte order that is guessable from the content
    is worse than guessing, so this is a deliberate difference and it is written
    down in docs/deviations.md.
    """
    var n = bytes.__len__()
    if n >= 2:
        if bytes[0] == 0xFF and bytes[1] == 0xFE:
            return _decode_utf16(bytes[2:], False)
        if bytes[0] == 0xFE and bytes[1] == 0xFF:
            return _decode_utf16(bytes[2:], True)
    return _decode_utf16(bytes, False)


def _unit32[o: ImmOrigin](bytes: Span[UInt8, o], at: Int, big: Bool) -> UInt32:
    if big:
        return (
            (UInt32(bytes[at]) << 24)
            | (UInt32(bytes[at + 1]) << 16)
            | (UInt32(bytes[at + 2]) << 8)
            | UInt32(bytes[at + 3])
        )
    return (
        UInt32(bytes[at])
        | (UInt32(bytes[at + 1]) << 8)
        | (UInt32(bytes[at + 2]) << 16)
        | (UInt32(bytes[at + 3]) << 24)
    )


def _decode_utf32[o: ImmOrigin](bytes: Span[UInt8, o], big: Bool) -> String:
    var out = List[UInt8]()
    var n = bytes.__len__()
    var at = 0
    while at + 3 < n:
        # `append_codepoint` already substitutes for a surrogate or a value past
        # U+10FFFF, which is every way a UTF-32 unit can fail to be a character.
        append_codepoint(out, _unit32(bytes, at, big))
        at += 4
    if at < n:
        append_codepoint(out, REPLACEMENT)
    return _finish(out^)


def _decode_utf32_bom[o: ImmOrigin](bytes: Span[UInt8, o]) -> String:
    """UTF-32 with the byte order taken from a mark, defaulting to little endian.

    The little endian mark has to be checked first. `FF FE 00 00` starts with the
    UTF-16 little endian mark, so a decoder that looked at two bytes would read a
    UTF-32 document as UTF-16 and produce a nul between every character.
    """
    var n = bytes.__len__()
    if n >= 4:
        if (
            bytes[0] == 0xFF
            and bytes[1] == 0xFE
            and bytes[2] == 0x00
            and bytes[3] == 0x00
        ):
            return _decode_utf32(bytes[4:], False)
        if (
            bytes[0] == 0x00
            and bytes[1] == 0x00
            and bytes[2] == 0xFE
            and bytes[3] == 0xFF
        ):
            return _decode_utf32(bytes[4:], True)
    return _decode_utf32(bytes, False)
