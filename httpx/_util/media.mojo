"""Reading a `Content-Type` into a media type and its parameters.

```mojo
var media = parse_media_type('text/html; charset="utf-8"'.as_bytes())
media.mime            # text/html
media.param("charset")  # utf-8
```

Nothing here raises. A `Content-Type` arrives from the network, and a client that
throws on a malformed one turns a header nobody reads into a failure to read the
body. Anything that does not parse comes back as an empty media type or a missing
parameter, and every caller already has to handle both because the header is
optional in the first place.

Two details are the whole reason this is not a `split` on semicolons. A parameter
value may be a quoted string, so `filename="a;b.txt"` holds a semicolon that is
not a separator, and inside those quotes a backslash escapes the next character.
Getting either wrong means a boundary or a filename that is quietly truncated at
the first punctuation mark an attacker puts in it.
"""

from httpx._bytes import equal_ascii_ci, is_ows, to_lower, trim_ows

comptime _SEMICOLON = UInt8(ord(";"))
comptime _EQUALS = UInt8(ord("="))
comptime _QUOTE = UInt8(ord('"'))
comptime _BACKSLASH = UInt8(ord("\\"))


struct MediaType(Movable):
    """A parsed `Content-Type` or `Content-Disposition`.

    `mime` is lowercased, because media types are case insensitive and comparing
    them any other way misses the server that wrote `Text/HTML`. Parameter names
    are lowercased for the same reason. Parameter values are left exactly as they
    arrived, because a multipart boundary and a filename are both case sensitive
    and lowercasing either one corrupts it.
    """

    var mime: String
    var names: List[String]
    var values: List[String]

    def __init__(out self):
        self.mime = String()
        self.names = List[String]()
        self.values = List[String]()

    def copy(self) -> Self:
        var out = Self()
        out.mime = self.mime.copy()
        out.names = self.names.copy()
        out.values = self.values.copy()
        return out^

    def param(self, name: StringSpan) -> Optional[String]:
        """The first parameter with this name, or nothing.

        The first and not the last. A header carrying `charset` twice is either
        a mistake or an attempt to have two readers disagree, and taking the
        first is what `email.message` does, which is what httpx2 reads its
        charset through.
        """
        for i in range(len(self.names)):
            if self.names[i] == name:
                return self.values[i].copy()
        return None

    def has_param(self, name: StringSpan) -> Bool:
        for i in range(len(self.names)):
            if self.names[i] == name:
                return True
        return False

    def matches(self, mime: StaticString) -> Bool:
        return equal_ascii_ci(self.mime.as_bytes(), mime.as_bytes())


def _lowered[o: ImmOrigin](value: Span[UInt8, o]) -> String:
    var out = String()
    for i in range(value.__len__()):
        out += chr(Int(to_lower(value[i])))
    return out^


def _text[o: ImmOrigin](value: Span[UInt8, o]) -> String:
    """Bytes to a `String` without validating them as UTF-8.

    A header value can hold any byte from 0x20 up, and a server sending a
    Latin-1 filename is a real thing rather than a hypothetical. Every byte
    above 0x7F becomes its own code point, which is the Latin-1 reading and the
    one RFC 9110 names for a header that arrives without a stated encoding.
    """
    var out = String()
    for i in range(value.__len__()):
        out += chr(Int(value[i]))
    return out^


def parse_media_type[o: ImmOrigin](value: Span[UInt8, o]) -> MediaType:
    """Split a media type header into its type and its parameters."""
    var out = MediaType()
    var n = value.__len__()

    var at = 0
    while at < n and value[at] != _SEMICOLON:
        at += 1
    out.mime = _lowered(trim_ows(value[0:at]))

    while at < n:
        at += 1  # step over the semicolon
        var name_start = at
        while at < n and value[at] != _EQUALS and value[at] != _SEMICOLON:
            at += 1
        var name = _lowered(trim_ows(value[name_start:at]))

        if at >= n or value[at] == _SEMICOLON:
            # A parameter with no value. Nothing HTTP defines uses one, and
            # skipping it rather than storing an empty string means `param`
            # cannot report a charset that was never given.
            continue

        at += 1  # step over the equals
        while at < n and is_ows(value[at]):
            at += 1

        var text: String
        if at < n and value[at] == _QUOTE:
            at += 1
            var decoded = List[UInt8]()
            while at < n and value[at] != _QUOTE:
                # A backslash inside a quoted string escapes whatever follows,
                # which is how a quote gets into a filename. Dropping the
                # backslash here is what makes the closing quote unambiguous.
                if value[at] == _BACKSLASH and at + 1 < n:
                    at += 1
                decoded.append(value[at])
                at += 1
            if at < n:
                at += 1  # step over the closing quote
            text = _text(Span(decoded))
            # Whatever is left before the next semicolon is junk after a closing
            # quote. Skipping it keeps a malformed header from being read as a
            # second parameter nobody wrote.
            while at < n and value[at] != _SEMICOLON:
                at += 1
        else:
            var value_start = at
            while at < n and value[at] != _SEMICOLON:
                at += 1
            text = _text(trim_ows(value[value_start:at]))

        if name != "":
            out.names.append(name^)
            out.values.append(text^)

    return out^
