"""`Headers`, a case insensitive, order preserving multi map over bytes.

Four properties have to hold at once, and dropping any one of them breaks real
traffic. Lookup ignores case, because a server that sent `Content-Type` and a
caller that asks for `content-type` mean the same field. The casing that was
supplied is kept anyway, because it is what goes back on the wire and there are
still servers that read it. Duplicates are kept in order, because `Set-Cookie`
arrives that way and folding it loses cookies. And a repeated field read as one
value comes back comma joined, which is what RFC 9110 section 5.3 says it means.

Values are held as bytes rather than as text. On the wire a header value is
bytes, the encoding is not stated anywhere in the message, and guessing it early
is how a value comes back mangled with no way to recover the original. Decoding
happens on the way out, against the encoding this instance resolved, and the
bytes stay available for anything that needs them exactly as received.

The side index holds positions rather than references. Holding a reference into
`_list` across a mutation does not compile, since the next append may reallocate,
so the index stores `UInt32` handles and every lookup goes through `_list`.
"""

from std.collections import Dict

from httpx._bytes import Bytes, _quote, equal_ascii_ci, is_ows, to_lower
from httpx._exceptions import ErrorKind, new_error

comptime _HTAB = UInt8(0x09)
comptime _DEL = UInt8(0x7F)
comptime _HIGH = UInt8(0x80)

# RFC 9110 section 5.6.2. Everything outside this set either terminates the name
# on the wire or is not a name at all, so a name containing one cannot be sent.
comptime _TOKEN_EXTRA = StaticString("!#$%&'*+-.^_`|~")

# Fields whose value is credentials or session state. Printing a `Headers` is
# something people do while debugging, often into a log that outlives the
# session, so these show their length instead of their contents.
comptime _SECRET_NAMES = StaticString(
    "authorization proxy-authorization cookie set-cookie"
)


def is_token_byte(byte: UInt8) -> Bool:
    """True for one byte of an RFC 9110 token, which is what a field name is."""
    if byte >= UInt8(ord("0")) and byte <= UInt8(ord("9")):
        return True
    if byte >= UInt8(ord("A")) and byte <= UInt8(ord("Z")):
        return True
    if byte >= UInt8(ord("a")) and byte <= UInt8(ord("z")):
        return True
    var extra = _TOKEN_EXTRA.as_bytes()
    for i in range(extra.__len__()):
        if byte == extra[i]:
            return True
    return False


def check_name[o: ImmOrigin](name: Span[UInt8, o]) raises:
    """Reject anything that is not a field name.

    This is the half of injection defence that people forget. A caller building a
    name from user input can put a colon or a newline in it just as easily as in
    a value, and a name carrying either splits one header into two.
    """
    if name.__len__() == 0:
        raise new_error(
            ErrorKind.INVALID_HEADER, "a header name cannot be empty"
        )
    for i in range(name.__len__()):
        if not is_token_byte(name[i]):
            raise new_error(
                ErrorKind.INVALID_HEADER,
                String(
                    "header name ",
                    _quote(name),
                    " contains a byte that is not allowed in a token",
                ),
            )


def check_value[o: ImmOrigin](value: Span[UInt8, o]) raises:
    """Reject anything that cannot appear in a field value.

    A carriage return or newline in a value ends the header and starts whatever
    the attacker wrote next, which is request splitting, and a NUL truncates the
    value inside anything that later hands it to C. Those three are the attack;
    the remaining controls are rejected with them because RFC 9110 does not allow
    them either and letting them through only widens what has to be reasoned
    about. Bytes at or above 0x80 are obs-text and are allowed, which is why
    values are stored as bytes in the first place.
    """
    for i in range(value.__len__()):
        var byte = value[i]
        if byte < UInt8(0x20) and byte != _HTAB:
            raise new_error(
                ErrorKind.INVALID_HEADER,
                String(
                    "header value ",
                    _quote(value),
                    (
                        " contains a control byte, which would end the header"
                        " early"
                    ),
                ),
            )
        if byte == _DEL:
            raise new_error(
                ErrorKind.INVALID_HEADER,
                String(
                    "header value ", _quote(value), " contains a delete byte"
                ),
            )


def _trimmed[o: ImmOrigin](value: Span[UInt8, o]) -> Span[UInt8, o]:
    """Drop leading and trailing spaces and tabs.

    Field values carry optional whitespace around them that is not part of the
    value, so trimming here is what makes `Content-Length: 5` and
    `Content-Length:  5 ` parse to the same number.
    """
    var start = 0
    var end = value.__len__()
    while start < end and is_ows(value[start]):
        start += 1
    while end > start and is_ows(value[end - 1]):
        end -= 1
    return value[start:end]


def _named(name: StringSpan, expected: StaticString) -> Bool:
    """Compare a name against a fixed one without building a `String`.

    Comparing a `StringSpan` to a literal builds a `String` for the literal, and
    these comparisons sit on the path every header read takes, so they go through
    the byte comparison instead. Case insensitive because the names being
    compared are field names and charset labels, both of which are.
    """
    return equal_ascii_ci(name.as_bytes(), expected.as_bytes())


def _lowered[o: ImmOrigin](name: Span[UInt8, o]) -> String:
    var out = String()
    for i in range(name.__len__()):
        out += chr(Int(to_lower(name[i])))
    return out^


struct HeaderEntry(Movable):
    """One field line, kept three ways.

    The raw name is what gets written back out, the lowered name is what lookups
    compare, and precomputing the second means a lookup does not lowercase every
    name it walks past.
    """

    var raw_name: Bytes
    var lower_name: String
    var value: Bytes

    def __init__(out self, var raw_name: Bytes, var value: Bytes):
        self.lower_name = _lowered(raw_name.as_span())
        self.raw_name = raw_name^
        self.value = value^

    def copy(self) -> Self:
        return Self(self.raw_name.copy(), self.value.copy())


struct Headers(Boolable, Movable, Sized, Writable):
    """The header fields of a request or a response.

    A list rather than a dictionary, because HTTP allows a name to appear more
    than once and the order it appears in is part of the message. Lookups are
    case insensitive both ways, `__getitem__` and `get` answer with the first
    value for a name, and `get_list` answers with all of them, which is what the
    handful of headers that are allowed to repeat need.

    Writing one out redacts `Authorization`, `Proxy-Authorization`, `Cookie` and
    `Set-Cookie`, so a debug print cannot put a credential in a log. Asking for
    the value by name still gives the value.
    """

    var _list: List[HeaderEntry]
    var _index: Dict[String, List[UInt32]]
    var _encoding: Optional[String]

    def __init__(out self):
        self._list = List[HeaderEntry]()
        self._index = Dict[String, List[UInt32]]()
        self._encoding = None

    def __init__(out self, items: List[Tuple[String, String]]) raises:
        """Build from pairs, keeping duplicates and order.

        Every value goes through the same validation the wire path uses, so a
        header assembled in code cannot carry something a header read from a
        socket would have been rejected for.
        """
        self = Self()
        for i in range(len(items)):
            self.append(items[i][0], items[i][1])

    def copy(self) -> Self:
        var out = Self()
        for i in range(len(self._list)):
            out._list.append(self._list[i].copy())
        out._encoding = self._encoding.copy()
        out._reindex()
        return out^

    def _reindex(mut self):
        """Rebuild the position index from `_list`.

        Anything that removes or reorders an entry shifts every position after
        it, so those paths rebuild rather than patch. Rebuilding is linear and
        deletion is rare, while patching positions in place is the kind of code
        that is subtly wrong for a year.
        """
        self._index = Dict[String, List[UInt32]]()
        for i in range(len(self._list)):
            self._record(i)

    def _record(mut self, index: Int):
        var key = self._list[index].lower_name
        try:
            self._index[key].append(UInt32(index))
        except:
            # Absent, which is the common case for the first occurrence of a
            # field. `Dict` has no upsert, so the miss is the branch.
            var positions = List[UInt32]()
            positions.append(UInt32(index))
            self._index[key] = positions^

    def _positions(self, key: StringSpan) -> List[UInt32]:
        var lowered = _lowered(key.as_bytes())
        try:
            return self._index[lowered].copy()
        except:
            return List[UInt32]()

    def __len__(self) -> Int:
        """The number of field lines, counting duplicates separately."""
        return len(self._list)

    def __bool__(self) -> Bool:
        return len(self._list) > 0

    def __contains__(self, key: StringSpan) -> Bool:
        return len(self._positions(key)) > 0

    def append(mut self, key: StringSpan, value: StringSpan) raises:
        """Add a field line without touching any that are already there."""
        self.append_raw(key.as_bytes(), value.as_bytes())

    def append_raw[
        n: ImmOrigin, v: ImmOrigin
    ](mut self, name: Span[UInt8, n], value: Span[UInt8, v]) raises:
        """Add a field line from bytes, as the message parser has them.

        The parser calls this rather than `append` because it has spans into the
        read buffer and no reason to build two strings on the way past.
        """
        check_name(name)
        var trimmed = _trimmed(value)
        check_value(trimmed)
        self._list.append(HeaderEntry(Bytes(name), Bytes(trimmed)))
        self._record(len(self._list) - 1)

    def __setitem__(mut self, key: StringSpan, value: StringSpan) raises:
        """Replace every occurrence of `key` with a single one.

        The replacement takes the position of the first occurrence rather than
        going on the end. Header order is visible to the server, and a few of
        them act on it, so setting a value should not also move the field.
        """
        check_name(key.as_bytes())
        var trimmed = _trimmed(value.as_bytes())
        check_value(trimmed)
        var lowered = _lowered(key.as_bytes())
        var kept = List[HeaderEntry]()
        var placed = False
        for i in range(len(self._list)):
            if self._list[i].lower_name == lowered:
                if not placed:
                    kept.append(
                        HeaderEntry(Bytes(key.as_bytes()), Bytes(trimmed))
                    )
                    placed = True
                continue
            kept.append(self._list[i].copy())
        if not placed:
            kept.append(HeaderEntry(Bytes(key.as_bytes()), Bytes(trimmed)))
        self._list = kept^
        self._reindex()

    def __delitem__(mut self, key: StringSpan) raises:
        """Remove every occurrence of `key`, raising when there were none.

        Raising on a missing key is what makes a typo in a field name show up.
        Callers that do not care use `discard`.
        """
        if not self.discard(key):
            raise new_error(
                ErrorKind.INVALID_HEADER,
                String("no header named ", _quote(key.as_bytes())),
            )

    def discard(mut self, key: StringSpan) -> Bool:
        """Remove every occurrence of `key`. True when something was removed."""
        var lowered = _lowered(key.as_bytes())
        var kept = List[HeaderEntry]()
        var removed = False
        for i in range(len(self._list)):
            if self._list[i].lower_name == lowered:
                removed = True
                continue
            kept.append(self._list[i].copy())
        if removed:
            self._list = kept^
            self._reindex()
        return removed

    def setdefault(mut self, key: StringSpan, value: StringSpan) raises:
        """Add the field only if it is not already there.

        This is how defaults such as `User-Agent` and `Accept` are applied, and
        the whole point is that a caller who set one explicitly keeps it.
        """
        if key not in self:
            self.append(key, value)

    def update(mut self, other: Self) raises:
        """Set every field of `other`, replacing what was here.

        Set rather than append, so applying the same overrides twice gives what
        applying them once gave. A field repeated inside `other` keeps all its
        values, because the repetition there was deliberate.

        The names come out of `other` in the casing they went in with. Going
        through `keys()` instead would put every field a caller set on the wire
        lowercased, which is legal and which nothing else does, so a request
        would be identifiable as coming from this library by its shape alone.
        """
        for name in other.keys():
            _ = self.discard(name)
        for i in range(len(other)):
            self.append(
                StringSpan(from_utf8=other.raw_name(i)),
                StringSpan(from_utf8=other.raw_value(i)),
            )

    def _is_secret(self, lowered: StringSpan) -> Bool:
        for candidate in _SECRET_NAMES.split(" "):
            if equal_ascii_ci(lowered.as_bytes(), candidate.as_bytes()):
                return True
        return False

    def __getitem__(self, key: StringSpan) raises -> String:
        """The value of `key`, comma joined when it appears more than once.

        Raises when the field is absent, and raises for a repeated `Set-Cookie`
        rather than joining it. Cookie `Expires` attributes contain commas, so a
        joined `Set-Cookie` cannot be split back apart, and the reader ends up
        with one corrupt cookie instead of two good ones. Cookie handling reads
        it through `get_list`, which is the only correct way.
        """
        var positions = self._positions(key)
        if len(positions) == 0:
            raise new_error(
                ErrorKind.INVALID_HEADER,
                String("no header named ", _quote(key.as_bytes())),
            )
        var lowered = _lowered(key.as_bytes())
        if len(positions) > 1 and _named(lowered, "set-cookie"):
            raise new_error(
                ErrorKind.INVALID_HEADER,
                (
                    "set-cookie appears more than once and its values cannot be"
                    " joined, because an Expires attribute contains a comma."
                    " Read it with get_list instead."
                ),
            )
        var encoding = self.encoding()
        var out = String()
        for i in range(len(positions)):
            if i > 0:
                out += ", "
            out += _decode(
                self._list[Int(positions[i])].value.as_span(), encoding
            )
        return out^

    def get(self, key: StringSpan, default: StringSpan = "") raises -> String:
        """The value of `key`, or `default` when the field is absent.

        Absence is the only thing this swallows. A repeated `Set-Cookie` still
        raises, because returning the default there would say the header was
        missing when it was in fact present twice.
        """
        if key not in self:
            return String(default)
        return self[key]

    def get_list(
        self, key: StringSpan, split_commas: Bool = False
    ) raises -> List[String]:
        """Every value for `key`, in the order received.

        With `split_commas` each value is also split on commas and trimmed, which
        is how a list valued field such as `Connection` or `Accept-Encoding` is
        meant to be read: a sender may send one line with commas or several
        lines, and both mean the same thing. It is off by default because it is
        wrong for `Set-Cookie` and for `Date`.
        """
        var encoding = self.encoding()
        var positions = self._positions(key)
        var out = List[String]()
        for i in range(len(positions)):
            var text = _decode(
                self._list[Int(positions[i])].value.as_span(), encoding
            )
            if not split_commas:
                out.append(text^)
                continue
            for piece in text.split(","):
                var trimmed = String(
                    StringSpan(from_utf8=_trimmed(piece.as_bytes()))
                )
                out.append(trimmed^)
        return out^

    def get_span(
        ref self, key: StringSpan
    ) -> Optional[Span[UInt8, origin_of(self._list[0].value._data)]]:
        """The first value for `key` as bytes, without allocating.

        This is the internal path. The client reads `content-length`,
        `transfer-encoding` and `connection` on every single message, and none of
        those needs a `String`. The returned span borrows from `self`, so the
        compiler refuses any mutation of the headers while it is alive, which is
        the property that makes handing out an interior view safe here.

        Callers pass an already lowercased literal. Comparison ignores case
        anyway, so a mixed case key still works; passing one just costs the scan
        nothing extra and reads oddly.
        """
        for i in range(len(self._list)):
            if equal_ascii_ci(self._list[i].raw_name.as_span(), key.as_bytes()):
                return self._list[i].value.as_span()
        return None

    def raw_name(
        ref self, index: Int
    ) -> Span[UInt8, origin_of(self._list[0].raw_name._data)]:
        """The name of field line `index`, cased as it was supplied."""
        return self._list[index].raw_name.as_span()

    def raw_value(
        ref self, index: Int
    ) -> Span[UInt8, origin_of(self._list[0].value._data)]:
        """The value of field line `index`, exactly as it was supplied."""
        return self._list[index].value.as_span()

    def keys(self) -> List[String]:
        """Every field name, once each, in the order it first appeared.

        The lowered name, not the supplied one, because two lines that differ
        only in case are one field and returning both would say otherwise.
        """
        var out = List[String]()
        for i in range(len(self._list)):
            var seen = False
            for j in range(len(out)):
                if out[j] == self._list[i].lower_name:
                    seen = True
                    break
            if not seen:
                out.append(self._list[i].lower_name)
        return out^

    def values(self) raises -> List[String]:
        """One value per name, joined the same way `__getitem__` joins."""
        var out = List[String]()
        for name in self.keys():
            out.append(self[name])
        return out^

    def items(self) raises -> List[Tuple[String, String]]:
        """One pair per name, with repeated fields joined."""
        var out = List[Tuple[String, String]]()
        for name in self.keys():
            out.append((name, self[name]))
        return out^

    def multi_items(self) raises -> List[Tuple[String, String]]:
        """Every field line, duplicates included, in order."""
        var encoding = self.encoding()
        var out = List[Tuple[String, String]]()
        for i in range(len(self._list)):
            out.append(
                (
                    self._list[i].lower_name,
                    _decode(self._list[i].value.as_span(), encoding),
                )
            )
        return out^

    def __eq__(self, other: Self) -> Bool:
        """Order insensitive over field lines, multiplicity sensitive.

        Two messages that carry the same fields in a different order are the same
        message, so they compare equal. Two that carry a field a different number
        of times are not, because the receiver can tell.
        """
        if len(self._list) != len(other._list):
            return False
        for i in range(len(self._list)):
            var lowered = self._list[i].lower_name
            var value = self._list[i].value.as_span()
            if self._count(lowered, value) != other._count(lowered, value):
                return False
        return True

    def __ne__(self, other: Self) -> Bool:
        return not (self == other)

    def _count[
        v: ImmOrigin
    ](self, lowered: StringSpan, value: Span[UInt8, v]) -> Int:
        var total = 0
        for i in range(len(self._list)):
            if self._list[i].lower_name != lowered:
                continue
            var candidate = self._list[i].value.as_span()
            if candidate.__len__() != value.__len__():
                continue
            var same = True
            for j in range(value.__len__()):
                if candidate[j] != value[j]:
                    same = False
                    break
            if same:
                total += 1
        return total

    def set_encoding(mut self, encoding: StringSpan) raises:
        """Pin the encoding used to decode values.

        Only three names mean anything here. Anything else is a caller mistake
        that would otherwise show up much later as mojibake in one field.
        """
        if not (
            _named(encoding, "ascii")
            or _named(encoding, "utf-8")
            or _named(encoding, "iso-8859-1")
        ):
            raise new_error(
                ErrorKind.INVALID_HEADER,
                String(
                    "header encoding ",
                    _quote(encoding.as_bytes()),
                    " is not one of ascii, utf-8 or iso-8859-1",
                ),
            )
        self._encoding = String(encoding)

    def encoding(self) -> String:
        """The encoding values decode with, pinned or detected.

        Detection is the same order httpx2 uses. Plain ASCII if every value is,
        UTF-8 if every value is valid UTF-8, and otherwise iso-8859-1, which is
        the default RFC 9110 gives and which cannot fail on any byte sequence.
        Having a fallback that cannot fail is the point: reading a header must
        never raise just because a server sent a byte nobody expected.
        """
        if self._encoding:
            return self._encoding.value()
        var ascii_only = True
        for i in range(len(self._list)):
            var value = self._list[i].value.as_span()
            for j in range(value.__len__()):
                if value[j] >= _HIGH:
                    ascii_only = False
                    break
            if not ascii_only:
                break
        if ascii_only:
            return String("ascii")
        for i in range(len(self._list)):
            try:
                _ = self._list[i].value.to_string()
            except:
                return String("iso-8859-1")
        return String("utf-8")

    def write_to[W: Writer](self, mut writer: W):
        """Debug output, with credentials withheld.

        Printing headers while chasing a bug is normal and the output often ends
        up somewhere it outlives the session, so the fields that carry
        credentials or session state show their length instead of their contents.
        """
        writer.write("Headers([")
        for i in range(len(self._list)):
            if i > 0:
                writer.write(", ")
            writer.write("(", self._list[i].lower_name, ", ")
            if self._is_secret(self._list[i].lower_name):
                writer.write("[secret, ", len(self._list[i].value), " bytes])")
                continue
            try:
                writer.write(self._list[i].value.to_string(), ")")
            except:
                writer.write("[", len(self._list[i].value), " bytes])")
        writer.write("])")


def _decode[
    o: ImmOrigin
](value: Span[UInt8, o], encoding: StringSpan) raises -> String:
    """Turn raw value bytes into text.

    iso-8859-1 is a byte for byte map onto the first 256 code points, so it is
    written out rather than delegated, and it is the branch that cannot fail. The
    other two are both valid UTF-8 by the time detection has chosen them, so they
    share a path.
    """
    if _named(encoding, "iso-8859-1"):
        var out = String()
        for i in range(value.__len__()):
            out += chr(Int(value[i]))
        return out^
    return String(StringSpan(from_utf8=value))
