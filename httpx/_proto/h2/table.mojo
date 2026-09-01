"""The HPACK static and dynamic tables.

RFC 7541 sections 2.3, 3.2 and 4. HPACK addresses both tables through one index
space: 1 through 61 are the fixed entries of appendix A, and 62 upwards are the
dynamic ones with 62 always being the most recently added. So an index means
something different after every insertion, which is why encoder and decoder each
keep their own table and why the two only stay in step if every insertion happens
in the same order on both sides.

The dynamic table is the part a peer can grow, so it is the part with the
bounds. Two of them matter and they are different things.

The capacity is what the size accounting in section 4.1 is measured against, and
the peer may change it mid stream with a dynamic table size update. It may not
raise it above what we advertised in `SETTINGS_HEADER_TABLE_SIZE`, and a request
to do so is a connection error rather than something to clamp, because a peer
that ignores a setting it was sent has stopped agreeing with us about what the
indices mean.

The accounting itself is the other bound, and the thirty two bytes an entry costs
on top of its name and value are the whole reason it works. Without that a peer
could fill a four kilobyte table with thousands of empty entries and hand every
one of them an index, so the memory a table actually occupies would have nothing
to do with the number it reports.
"""

from httpx._exceptions import ErrorKind, new_error

comptime DEFAULT_TABLE_SIZE = 4096
"""The `SETTINGS_HEADER_TABLE_SIZE` a peer assumes until told otherwise.

RFC 7540 section 6.5.2. Both sides start here, so a connection where neither
sends the setting still agrees.
"""

comptime ENTRY_OVERHEAD = 32
"""What one dynamic table entry costs beyond its name and its value.

RFC 7541 section 4.1 fixes this at thirty two, and it is deliberately not an
estimate of what any particular implementation spends. It is there so that the
number of entries a table can hold is bounded whatever is in them.
"""

comptime STATIC_COUNT = 61
"""Indices 1 through 61. Index 0 is not a table entry in any representation."""


def _remote(message: String) -> Error:
    return new_error(ErrorKind.REMOTE_PROTOCOL_ERROR, message)


struct HeaderField(Movable):
    """One header field, and whether it may be put in a table.

    `sensitive` is not a property of the header, it is an instruction that
    travels with it. RFC 7541 section 7.1.3 says a field received as never
    indexed has to be forwarded as never indexed, so the flag has to survive
    a decode and be readable by whoever encodes next. Deciding which headers
    deserve it is not HPACK's business and is not decided here.
    """

    var name: String
    var value: String
    var sensitive: Bool

    def __init__(
        out self, var name: String, var value: String, sensitive: Bool = False
    ):
        self.name = name^
        self.value = value^
        self.sensitive = sensitive

    def copy(self) -> Self:
        return Self(self.name.copy(), self.value.copy(), self.sensitive)

    def size(self) -> Int:
        """The RFC 7541 section 4.1 cost of this field in a dynamic table."""
        return (
            self.name.byte_length() + self.value.byte_length() + ENTRY_OVERHEAD
        )


# RFC 7541 appendix A, flattened to name then value. Written out rather than
# generated because the table is sixty one rows that have never changed and
# never will: it is frozen into the specification, and a generator for it would
# be a second copy of the same literal with a script in between.
# fmt: off
comptime _STATIC: InlineArray[StaticString, STATIC_COUNT * 2] = [
    ":authority", "",
    ":method", "GET",
    ":method", "POST",
    ":path", "/",
    ":path", "/index.html",
    ":scheme", "http",
    ":scheme", "https",
    ":status", "200",
    ":status", "204",
    ":status", "206",
    ":status", "304",
    ":status", "400",
    ":status", "404",
    ":status", "500",
    "accept-charset", "",
    "accept-encoding", "gzip, deflate",
    "accept-language", "",
    "accept-ranges", "",
    "accept", "",
    "access-control-allow-origin", "",
    "age", "",
    "allow", "",
    "authorization", "",
    "cache-control", "",
    "content-disposition", "",
    "content-encoding", "",
    "content-language", "",
    "content-length", "",
    "content-location", "",
    "content-range", "",
    "content-type", "",
    "cookie", "",
    "date", "",
    "etag", "",
    "expect", "",
    "expires", "",
    "from", "",
    "host", "",
    "if-match", "",
    "if-modified-since", "",
    "if-none-match", "",
    "if-range", "",
    "if-unmodified-since", "",
    "last-modified", "",
    "link", "",
    "location", "",
    "max-forwards", "",
    "proxy-authenticate", "",
    "proxy-authorization", "",
    "range", "",
    "referer", "",
    "refresh", "",
    "retry-after", "",
    "server", "",
    "set-cookie", "",
    "strict-transport-security", "",
    "transfer-encoding", "",
    "user-agent", "",
    "vary", "",
    "via", "",
    "www-authenticate", "",
]
# fmt: on


struct HpackTable(Movable, Sized):
    """The static and dynamic tables, addressed as HPACK addresses them."""

    var _static: InlineArray[StaticString, STATIC_COUNT * 2]

    var _entries: List[HeaderField]
    """The dynamic entries, newest first, so index 62 is `_entries[0]`."""

    var _size: Int
    """The accounted size of everything in `_entries`."""

    var _capacity: Int
    """What `_size` is allowed to reach, which the peer may change."""

    var _limit: Int
    """The largest capacity the peer may ask for, which is what we advertised."""

    def __init__(out self, limit: Int = DEFAULT_TABLE_SIZE):
        # The comptime table has to be brought into a runtime value once. Doing
        # it here rather than at every lookup is why this is a field.
        self._static = materialize[_STATIC]()
        self._entries = List[HeaderField]()
        self._size = 0
        self._capacity = limit
        self._limit = limit

    def __len__(self) -> Int:
        """How many dynamic entries there are.

        The static ones are not counted, because they are not something this
        table holds.
        """
        return len(self._entries)

    def size(self) -> Int:
        return self._size

    def capacity(self) -> Int:
        return self._capacity

    def limit(self) -> Int:
        return self._limit

    def entry(self, index: Int) raises -> HeaderField:
        """The field at `index`, static or dynamic.

        A copy rather than a reference. The caller is building a header list it
        owns, and an entry can be evicted by the very next instruction in the
        same header block, so a reference into the table would be a reference
        into something the decoder is still moving.
        """
        if index < 1:
            raise _remote(
                "the server sent an HPACK index of zero, which addresses"
                " nothing"
            )

        if index <= STATIC_COUNT:
            var at = (index - 1) * 2
            return HeaderField(
                String(self._static[at]), String(self._static[at + 1])
            )

        var into = index - STATIC_COUNT - 1
        if into >= len(self._entries):
            raise _remote(
                String(
                    "the server sent an HPACK index of ",
                    index,
                    " with only ",
                    STATIC_COUNT + len(self._entries),
                    " entries to address",
                )
            )
        return self._entries[into].copy()

    def find(self, name: StringSpan, value: StringSpan) -> Int:
        """The index of an entry matching both, or 0 for none.

        Zero is the miss because zero is not an index in HPACK, so there is no
        value that could be confused with a hit.
        """
        for i in range(STATIC_COUNT):
            if self._static[i * 2] == name and self._static[i * 2 + 1] == value:
                return i + 1
        for i in range(len(self._entries)):
            if (
                self._entries[i].name == name
                and self._entries[i].value == value
            ):
                return STATIC_COUNT + 1 + i
        return 0

    def find_name(self, name: StringSpan) -> Int:
        """The index of the first entry with this name, or 0 for none.

        The static table is searched first and in order, so a name that appears
        more than once there, which `:method`, `:path`, `:scheme` and `:status`
        all do, answers with the lowest index. That is the one that encodes in
        the fewest bytes.
        """
        for i in range(STATIC_COUNT):
            if self._static[i * 2] == name:
                return i + 1
        for i in range(len(self._entries)):
            if self._entries[i].name == name:
                return STATIC_COUNT + 1 + i
        return 0

    def add(mut self, var field: HeaderField):
        """Put `field` at the front of the dynamic table, evicting as needed.

        RFC 7541 section 4.4. An entry too big for the whole table empties the
        table and is not added, and that is not an error: the peer is allowed to
        do it, and both sides end up with the same empty table, which is all
        that matters.
        """
        var cost = field.size()
        self._evict_to(self._capacity - cost)
        if cost > self._capacity:
            return

        self._entries.insert(0, field^)
        self._size += cost

    def set_capacity(mut self, capacity: Int) raises:
        """Apply a dynamic table size update.

        Refusing a capacity above the limit rather than clamping it is
        deliberate. If we clamped, the peer would go on indexing against the
        size it asked for, our table would evict at a different point, and from
        the first eviction onwards every index would name a different header on
        each side. A connection error says so immediately instead of decoding
        somebody else's headers into this request.
        """
        if capacity < 0 or capacity > self._limit:
            raise _remote(
                String(
                    "the server asked for an HPACK table of ",
                    capacity,
                    " bytes, over the ",
                    self._limit,
                    " we advertised",
                )
            )
        self._capacity = capacity
        self._evict_to(capacity)

    def set_limit(mut self, limit: Int):
        """Take a new ceiling, which is what a peer's `SETTINGS_HEADER_TABLE_SIZE`
        is on the encoding side.

        Lowering it lowers the capacity with it, because a capacity above the
        ceiling is one the peer will not honour and indexing against it would
        mean indexing against a table only one side has.
        """
        self._limit = limit
        if self._capacity > limit:
            self._capacity = limit
            self._evict_to(limit)

    def _evict_to(mut self, room: Int):
        """Drop entries from the oldest end until the size is within `room`."""
        while self._size > room and len(self._entries) > 0:
            var oldest = self._entries.pop()
            self._size -= oldest.size()
