"""`Bytes`, and the conventions for parsing over `Span[UInt8]`.

HTTP is a byte protocol. A header value is a sequence of octets, a status line
is a sequence of octets, and a body is a sequence of octets that may not be text
at all. Mojo's `String` is validated UTF-8, which is the wrong type for all
three: a server is entitled to send a Latin-1 header value or a `Content-Type`
we have no encoding for, and a client that refuses to parse the response because
of it is broken.

So the rule for this library is that everything between the socket and the
public API is `Span[UInt8]`, and the conversion to `String` happens once, at the
edge, where a decoding failure can be reported as a `DecodingError` rather than
crashing a parser halfway through a response.

The rule has a second benefit. Parsing over spans copies nothing. A response
with forty headers is parsed into forty pairs of offsets into the one buffer the
socket filled, and the only allocation is the buffer itself.

Two types appear here.

`Bytes` owns a byte buffer. Request and response bodies that are held in memory
are `Bytes`, and so is anything that has to outlive the buffer it was parsed
from.

`Span[UInt8]` borrows one. Every function in this module that inspects bytes
takes a span, because a function that took `Bytes` would force its caller to
allocate in order to ask a question. The origin parameter is written out on
these signatures rather than left to inference, because the ones that return a
sub-span have to say that the result borrows from the same buffer as the input,
and that is only sayable if the origin has a name.

The functions here are the ones the HTTP/1.1 parser needs and no more. They are
deliberately not a general purpose byte string library.
"""

from std.collections.string import StringSpan


comptime _HTAB = UInt8(0x09)
comptime _SPACE = UInt8(0x20)
comptime _CR = UInt8(0x0D)
comptime _LF = UInt8(0x0A)
comptime _ZERO = UInt8(0x30)
comptime _NINE = UInt8(0x39)
comptime _UPPER_A = UInt8(0x41)
comptime _UPPER_F = UInt8(0x46)
comptime _UPPER_Z = UInt8(0x5A)
comptime _LOWER_A = UInt8(0x61)
comptime _LOWER_F = UInt8(0x66)
comptime _LOWER_Z = UInt8(0x7A)
comptime _CASE_BIT = UInt8(0x20)
"""The single bit that separates an ASCII letter from its other case. Only
valid for A to Z, which is why `to_lower` checks the range first."""


struct Bytes(Boolable, Movable, Sized, Writable):
    """An owned byte buffer.

    Copying is explicit. A response body can be megabytes, and a type that
    copies itself whenever it is passed to a function turns a streaming client
    into a memory hog without anything in the source looking wrong. Call `copy`
    where a copy is what you meant.
    """

    var _data: List[UInt8]

    def __init__(out self):
        self._data = List[UInt8]()

    def __init__(out self, var data: List[UInt8]):
        self._data = data^

    def __init__(out self, text: StringSpan):
        """Take the UTF-8 encoding of some text.

        This direction never fails, because a `StringSpan` is already valid
        UTF-8. The other direction, `to_string`, is the one that can.
        """
        self._data = List[UInt8]()
        self.extend(text.as_bytes())

    def __init__[o: ImmOrigin](out self, source: Span[UInt8, o]):
        self._data = List[UInt8]()
        self.extend(source)

    @staticmethod
    def with_capacity(capacity: Int) -> Self:
        """An empty buffer that can grow to `capacity` without reallocating.

        Worth using when the length is known in advance, which for a body with a
        `Content-Length` it is.
        """
        var data = List[UInt8]()
        data.reserve(capacity)
        return Self(data^)

    def copy(self) -> Self:
        var data = List[UInt8]()
        data.reserve(self._data.__len__())
        for i in range(self._data.__len__()):
            data.append(self._data[i])
        return Self(data^)

    def __len__(self) -> Int:
        return self._data.__len__()

    def __bool__(self) -> Bool:
        return self._data.__len__() != 0

    def __getitem__(self, index: Int) -> UInt8:
        return self._data[index]

    def append(mut self, byte: UInt8):
        self._data.append(byte)

    def extend[o: ImmOrigin](mut self, source: Span[UInt8, o]):
        self._data.reserve(self._data.__len__() + source.__len__())
        for i in range(source.__len__()):
            self._data.append(source[i])

    def clear(mut self):
        """Drop the contents but keep the allocation.

        The connection pool reuses read buffers across requests, and that is
        only cheaper than a fresh buffer if the allocation survives.
        """
        self._data.clear()

    def as_span(ref self) -> Span[UInt8, origin_of(self._data)]:
        """Borrow the contents. The result is invalid after the next mutation.
        """
        return Span(self._data)

    def to_string(self) raises -> String:
        """Decode as UTF-8, or raise.

        The raise is the point. A body that is not valid UTF-8 is a real thing a
        server can send, and the caller has to be given the chance to reach for
        the bytes instead of getting a truncated or replacement-character
        string it will not notice is wrong.
        """
        return String(StringSpan(from_utf8=Span(self._data)))

    def write_to[W: Writer](self, mut writer: W):
        """Debug output. Prints the length, not the contents.

        A body is often a megabyte and often not text, so printing it is never
        what the caller wanted. `to_string` is the way to see the contents.
        """
        writer.write("Bytes(", self._data.__len__(), ")")


def to_lower(byte: UInt8) -> UInt8:
    """Lowercase one ASCII letter, leaving everything else alone.

    Deliberately ASCII only. HTTP header names are tokens, which are ASCII by
    definition, and applying a Unicode case mapping to them would make
    `Content-Length` and a Kelvin sign compare equal on some inputs.
    """
    if byte >= _UPPER_A and byte <= _UPPER_Z:
        return byte | _CASE_BIT
    return byte


def equal_ascii_ci[
    a: ImmOrigin, b: ImmOrigin
](left: Span[UInt8, a], right: Span[UInt8, b]) -> Bool:
    """Compare two byte strings, ignoring ASCII case.

    This is how header names are compared. `Content-Type` and `content-type`
    are the same header and a client that treats them as different will miss
    the one the server actually sent.
    """
    if left.__len__() != right.__len__():
        return False
    for i in range(left.__len__()):
        if to_lower(left[i]) != to_lower(right[i]):
            return False
    return True


def index_of[
    o: ImmOrigin
](haystack: Span[UInt8, o], byte: UInt8, start: Int = 0) -> Int:
    """The offset of the first `byte` at or after `start`, or -1.

    Returning -1 rather than raising is on purpose. Not finding a colon in a
    line is an ordinary branch in a parser, not an exceptional one, and a parser
    written around exceptions for its normal control flow is unreadable.
    """
    for i in range(start, haystack.__len__()):
        if haystack[i] == byte:
            return i
    return -1


def index_of_span[
    o: ImmOrigin, n: ImmOrigin
](haystack: Span[UInt8, o], needle: Span[UInt8, n], start: Int = 0) -> Int:
    """The offset of the first occurrence of `needle` at or after `start`, or -1.

    The empty needle matches at `start`, which is what makes a loop over
    successive matches terminate rather than spin.
    """
    var n_len = needle.__len__()
    if n_len == 0:
        return start
    var limit = haystack.__len__() - n_len
    for i in range(start, limit + 1):
        var matched = True
        for j in range(n_len):
            if haystack[i + j] != needle[j]:
                matched = False
                break
        if matched:
            return i
    return -1


def starts_with[
    o: ImmOrigin, p: ImmOrigin
](haystack: Span[UInt8, o], prefix: Span[UInt8, p]) -> Bool:
    if prefix.__len__() > haystack.__len__():
        return False
    for i in range(prefix.__len__()):
        if haystack[i] != prefix[i]:
            return False
    return True


def ends_with[
    o: ImmOrigin, s: ImmOrigin
](haystack: Span[UInt8, o], suffix: Span[UInt8, s]) -> Bool:
    var offset = haystack.__len__() - suffix.__len__()
    if offset < 0:
        return False
    for i in range(suffix.__len__()):
        if haystack[offset + i] != suffix[i]:
            return False
    return True


def is_ows(byte: UInt8) -> Bool:
    """Optional whitespace, as RFC 9110 defines it: space and horizontal tab.

    Not the same set as a general `isspace`. A carriage return or a line feed in
    the middle of a header value is a request smuggling vector, not whitespace
    to be trimmed away, so they are deliberately absent here.
    """
    return byte == _SPACE or byte == _HTAB


def trim_ows[o: ImmOrigin](value: Span[UInt8, o]) -> Span[UInt8, o]:
    """Strip leading and trailing optional whitespace.

    Header values arrive as `name: value` with unspecified padding on either
    side of the value, and every comparison downstream assumes it has been
    removed.
    """
    var start = 0
    var end = value.__len__()
    while start < end and is_ows(value[start]):
        start += 1
    while end > start and is_ows(value[end - 1]):
        end -= 1
    return value[start:end]


def is_digit(byte: UInt8) -> Bool:
    return byte >= _ZERO and byte <= _NINE


def parse_decimal[o: ImmOrigin](text: Span[UInt8, o]) raises -> Int:
    """Parse an unsigned decimal integer, strictly.

    Used for `Content-Length`, where being lenient is a security bug rather
    than a convenience. No sign, no whitespace, no leading plus, no empty
    string, and every byte must be a digit, because a `Content-Length` of
    `10 ` or `+10` or `0x10` being accepted by us and rejected by the next hop
    is exactly the disagreement that request smuggling is built on.

    Overflow raises rather than wrapping. A wrapped length would be a buffer
    size, and a negative or tiny buffer size is a memory safety problem.
    """
    if text.__len__() == 0:
        raise Error("ProtocolError: expected a number, found an empty value")
    var total = 0
    for i in range(text.__len__()):
        var byte = text[i]
        if not is_digit(byte):
            raise Error(
                String(
                    "ProtocolError: expected a decimal number, found ",
                    _quote(text),
                )
            )
        var digit = Int(byte - _ZERO)
        if total > (Int.MAX - digit) // 10:
            raise Error(
                String("ProtocolError: number is too large: ", _quote(text))
            )
        total = total * 10 + digit
    return total


def parse_hex[o: ImmOrigin](text: Span[UInt8, o]) raises -> Int:
    """Parse an unsigned hexadecimal integer, strictly.

    This reads chunked transfer sizes. The same strictness argument as
    `parse_decimal` applies, and more sharply: a chunk size is a length that is
    about to be trusted, and the chunk extensions that may follow it have
    already been split off by the caller before this is called.
    """
    if text.__len__() == 0:
        raise Error(
            "ProtocolError: expected a chunk size, found an empty value"
        )
    var total = 0
    for i in range(text.__len__()):
        var digit = _hex_digit(text[i])
        if digit < 0:
            raise Error(
                String("ProtocolError: invalid chunk size: ", _quote(text))
            )
        if total > (Int.MAX - digit) // 16:
            raise Error(
                String("ProtocolError: chunk size is too large: ", _quote(text))
            )
        total = total * 16 + digit
    return total


def _hex_digit(byte: UInt8) -> Int:
    if is_digit(byte):
        return Int(byte - _ZERO)
    if byte >= _LOWER_A and byte <= _LOWER_F:
        return Int(byte - _LOWER_A) + 10
    if byte >= _UPPER_A and byte <= _UPPER_F:
        return Int(byte - _UPPER_A) + 10
    return -1


def _escape(byte: UInt8) -> String:
    """One byte as `\\xNN`, always two digits.

    Written by hand rather than through `hex`, which drops the leading zero and
    would turn a newline into `\\xa`. A variable width escape in a log line is
    ambiguous, and ambiguity in the exact place an attacker controls the bytes
    is not a good trade for four lines saved.
    """
    comptime DIGITS = StaticString("0123456789abcdef")
    return String(
        "\\x",
        StringSpan(
            unsafe_from_utf8=DIGITS.as_bytes()[
                Int(byte >> 4) : Int(byte >> 4) + 1
            ]
        ),
        StringSpan(
            unsafe_from_utf8=DIGITS.as_bytes()[
                Int(byte & 0xF) : Int(byte & 0xF) + 1
            ]
        ),
    )


def _quote[o: ImmOrigin](text: Span[UInt8, o]) -> String:
    """Render bytes for an error message, without trusting them to be text.

    An error message built by concatenating attacker controlled bytes into a
    log line is its own vulnerability, so anything outside printable ASCII is
    escaped and the result is length limited.
    """
    comptime LIMIT = 64
    var out = String("'")
    var shown = min(text.__len__(), LIMIT)
    for i in range(shown):
        var byte = text[i]
        if byte >= 0x20 and byte < 0x7F:
            out += chr(Int(byte))
        else:
            out += _escape(byte)
    out += "'"
    if text.__len__() > LIMIT:
        out += String(" (", text.__len__(), " bytes)")
    return out
