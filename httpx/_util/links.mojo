"""Reading a `Link` header into the links it names.

```mojo
var links = parse_links('<https://api/items?page=2>; rel="next"'.as_bytes())
links[0].url            # https://api/items?page=2
links[0].has_rel("next")  # True
```

The header is how a paginated API says where the next page is, which is the one
place a client is expected to follow a URL it was given rather than one the
caller wrote. Nothing here raises, for the same reason nothing in the media type
parser does: the header arrives from the network and is optional, so a malformed
one comes back as no links rather than as a failure to use the response at all.

The syntax is RFC 8288. A link is a URI reference in angle brackets followed by
semicolon separated parameters, and a header may carry several separated by
commas. A parameter value may be a quoted string, so both `;` and `,` can appear
inside one without being separators, which is the whole reason this is a parser
and not two splits.

httpx2 does it with a regular expression that splits on `, *<`, which drops
everything after a parameter value containing a comma and silently stops reading
parameters at the first value containing an `=`. A `Link` header carrying
`title="Volume 2, part 1"` is ordinary rather than exotic, so this parses it
instead.
"""

from httpx._bytes import equal_ascii_ci, is_ows, to_lower, trim_ows

# Shared with the media type parser rather than copied, because a header value
# turns into a string exactly one way and two spellings of that would drift.
from httpx._util.media import _lowered, _text

comptime _COMMA = UInt8(ord(","))
comptime _SEMICOLON = UInt8(ord(";"))
comptime _EQUALS = UInt8(ord("="))
comptime _QUOTE = UInt8(ord('"'))
comptime _BACKSLASH = UInt8(ord("\\"))
comptime _OPEN = UInt8(ord("<"))
comptime _CLOSE = UInt8(ord(">"))


struct Link(Movable, Writable):
    """One entry from a `Link` header.

    Parameter names are lowercased, because RFC 8288 makes them case
    insensitive. Values are left exactly as they arrived: a `title` is text
    meant for a person and a URL is case sensitive in its path.
    """

    var url: String
    """The target, with the angle brackets taken off.

    Not resolved against the response URL. A relative target is legal here and
    resolving it needs the base, which this parser does not have. `Response.link`
    is where that happens, because the response knows where it came from.
    """

    var names: List[String]
    var values: List[String]

    def __init__(out self):
        self.url = String()
        self.names = List[String]()
        self.values = List[String]()

    def copy(self) -> Self:
        var out = Self()
        out.url = self.url.copy()
        out.names = self.names.copy()
        out.values = self.values.copy()
        return out^

    def param(self, name: StringSpan) -> Optional[String]:
        """The first parameter with this name, or nothing.

        The first rather than the last, matching the media type parser. A link
        carrying `rel` twice is either a mistake or an attempt to have two
        readers disagree, and reading them the same way everywhere means only
        one answer is possible.
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

    def rel(self) -> String:
        """The `rel` parameter verbatim, or empty when there is none.

        Verbatim because it may name more than one relation. Use `has_rel` to
        ask about one of them rather than comparing this against a string.
        """
        var found = self.param("rel")
        if found:
            return found.value()
        return String()

    def has_rel(self, name: StringSpan) -> Bool:
        """Whether this link is labelled with that relation.

        `rel` holds a space separated list, so `rel="next preload"` is one link
        that is both, and a client asking for `next` should find it. httpx2 keys
        its dictionary on the whole string, so the same header there is reachable
        only under `"next preload"`. Matching is case insensitive because RFC
        8288 registers relation types in lowercase and treats them that way.
        """
        var value = self.rel()
        var bytes = value.as_bytes()
        var n = bytes.__len__()
        var at = 0
        while at < n:
            while at < n and is_ows(bytes[at]):
                at += 1
            var start = at
            while at < n and not is_ows(bytes[at]):
                at += 1
            if at > start and equal_ascii_ci(bytes[start:at], name.as_bytes()):
                return True
        return False

    def write_to[W: Writer](self, mut writer: W):
        writer.write("<", self.url, ">")
        for i in range(len(self.names)):
            writer.write("; ", self.names[i], '="', self.values[i], '"')


def parse_links[o: ImmOrigin](value: Span[UInt8, o]) -> List[Link]:
    """Split a `Link` header into its links.

    An entry with no angle bracketed target is skipped rather than guessed at.
    RFC 8288 requires the brackets, and a bare URL there is as likely to be a
    stray comma inside a parameter as it is to be a link somebody meant.
    """
    var out = List[Link]()
    var n = value.__len__()
    var at = 0

    while at < n:
        while at < n and value[at] != _OPEN:
            at += 1
        if at >= n:
            break
        at += 1  # step over the opening bracket

        var url_start = at
        # A `>` cannot appear inside a URI reference, so the first one ends the
        # target and there is no escaping to undo.
        while at < n and value[at] != _CLOSE:
            at += 1
        var link = Link()
        link.url = _text(trim_ows(value[url_start:at]))
        if at < n:
            at += 1  # step over the closing bracket

        while at < n and value[at] != _COMMA:
            if value[at] != _SEMICOLON:
                # Junk between the target and the first separator. Stepping over
                # it byte by byte rather than giving up keeps one malformed link
                # from eating the ones after it.
                at += 1
                continue
            at += 1  # step over the semicolon

            var name_start = at
            while (
                at < n
                and value[at] != _EQUALS
                and value[at] != _SEMICOLON
                and value[at] != _COMMA
            ):
                at += 1
            var name = _lowered(trim_ows(value[name_start:at]))

            if at >= n or value[at] != _EQUALS:
                # A parameter with no value. RFC 8288 allows the form and gives
                # it no meaning, so it is dropped rather than stored empty, which
                # would make `param` report something nobody wrote.
                continue

            at += 1  # step over the equals
            while at < n and is_ows(value[at]):
                at += 1

            var text: String
            if at < n and value[at] == _QUOTE:
                at += 1
                var decoded = List[UInt8]()
                while at < n and value[at] != _QUOTE:
                    # A backslash escapes whatever follows, which is how a quote
                    # gets into a title. Dropping it here is what makes the
                    # closing quote unambiguous.
                    if value[at] == _BACKSLASH and at + 1 < n:
                        at += 1
                    decoded.append(value[at])
                    at += 1
                if at < n:
                    at += 1  # step over the closing quote
                text = _text(Span(decoded))
            else:
                var value_start = at
                while (
                    at < n and value[at] != _SEMICOLON and value[at] != _COMMA
                ):
                    at += 1
                text = _text(trim_ows(value[value_start:at]))

            if name != "":
                link.names.append(name^)
                link.values.append(text^)

        if link.url != "":
            out.append(link^)
        if at < n:
            at += 1  # step over the comma

    return out^
