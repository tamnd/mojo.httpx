"""Turning a header list into a header block and back.

RFC 7541 section 6. There are five representations and the decoder tells them
apart by the top bits of the first octet, which is why the branches below are in
the order they are: each one has to be ruled out before the next becomes
unambiguous.

    1xxxxxxx   indexed, the whole field is in a table
    01xxxxxx   literal, and add it to the dynamic table
    001xxxxx   dynamic table size update, not a field at all
    0001xxxx   literal, never index this one
    0000xxxx   literal, do not index this one

The decoder is where the bounds are, and there are three that belong here.

The decoded list has a ceiling. This is the HPACK bomb: a header block of a few
hundred bytes can name the same large dynamic table entry over and over, so the
list a decoder produces is not bounded by the block that produced it. RFC 7540
section 6.5.2 gives the accounting, name and value and thirty two per field, and
`SETTINGS_MAX_HEADER_LIST_SIZE` is what we advertised we would take.

An index has to address something. Zero addresses nothing in any representation,
and an index past the end of the dynamic table means the two sides have stopped
agreeing about what the table holds, which is not something to recover from.

A dynamic table size update has to come first. RFC 7541 section 4.2 puts it at
the start of a block, and that is worth enforcing rather than tolerating: an
update in the middle changes what every index after it means, so a decoder that
accepted one there would be decoding the rest of the block against a table the
encoder did not have.

The bound on the size of a block, across however many CONTINUATION frames it
arrived in, is not here. That one is about frames and belongs with the framing.
"""

from httpx._bytes import Bytes
from httpx._exceptions import ErrorKind, new_error
from httpx._proto.h2.primitives import (
    decode_integer,
    decode_string,
    encode_integer,
    encode_string,
)
from httpx._proto.h2.table import (
    DEFAULT_TABLE_SIZE,
    HeaderField,
    HpackTable,
)

comptime DEFAULT_MAX_HEADER_LIST_SIZE = 65536
"""What a decoder will produce before it gives up, unless told otherwise.

Not a limit RFC 7540 sets. It sets the accounting and leaves the number to the
implementation, so this is a choice: large enough that no real header list comes
near it, small enough that a peer cannot spend a small block on a large one.
"""

comptime _INDEXED = UInt8(0x80)
comptime _LITERAL_INDEXED = UInt8(0x40)
comptime _SIZE_UPDATE = UInt8(0x20)
comptime _LITERAL_NEVER = UInt8(0x10)


def _remote(message: String) -> Error:
    return new_error(ErrorKind.REMOTE_PROTOCOL_ERROR, message)


struct HpackDecoder(Movable):
    """Reads header blocks a peer sent, against a table it and we both keep."""

    var table: HpackTable

    var max_header_list_size: Int
    """The ceiling on what one block may decode to, in RFC 7540 accounting."""

    def __init__(
        out self,
        table_size: Int = DEFAULT_TABLE_SIZE,
        max_header_list_size: Int = DEFAULT_MAX_HEADER_LIST_SIZE,
    ):
        self.table = HpackTable(table_size)
        self.max_header_list_size = max_header_list_size

    def decode[
        o: ImmOrigin
    ](mut self, data: Span[UInt8, o]) raises -> List[HeaderField]:
        """Decode one complete header block.

        One block and not a piece of one. A field can straddle a CONTINUATION
        frame boundary, so the frame layer joins them before calling here, and
        the alternative, keeping half a field in the decoder between calls, would
        mean the decoder holds state that is only valid inside a block while also
        holding the table, which is state that outlives every block.
        """
        var out = List[HeaderField]()
        var total = 0
        var at = 0
        var started = False

        while at < len(data):
            var lead = data[at]

            if lead & _INDEXED:
                var read = decode_integer(data, at, 7)
                at = read.after
                var field = self.table.entry(read.value)
                total = self._account(total, field)
                out.append(field^)
                started = True
                continue

            if lead & _LITERAL_INDEXED:
                var field = self._literal(data, at, 6, False)
                total = self._account(total, field)
                self.table.add(field.copy())
                out.append(field^)
                started = True
                continue

            if lead & _SIZE_UPDATE:
                if started:
                    raise _remote(
                        "the server sent an HPACK table size update in the"
                        " middle of a header block"
                    )
                var read = decode_integer(data, at, 5)
                at = read.after
                self.table.set_capacity(read.value)
                continue

            var never = (lead & _LITERAL_NEVER) != 0
            var field = self._literal(data, at, 4, never)
            total = self._account(total, field)
            out.append(field^)
            started = True

        return out^

    def _account(self, total: Int, field: HeaderField) raises -> Int:
        var grown = total + field.size()
        if grown > self.max_header_list_size:
            raise _remote(
                String(
                    "the server sent a header list of over ",
                    self.max_header_list_size,
                    " bytes",
                )
            )
        return grown

    def _literal[
        o: ImmOrigin
    ](
        mut self,
        data: Span[UInt8, o],
        mut at: Int,
        prefix_bits: Int,
        sensitive: Bool,
    ) raises -> HeaderField:
        """The three literal forms, which differ only in prefix width and what
        happens to the result afterwards.

        `at` is moved past what was read. A tuple would say the same thing, but
        a header field cannot be copied out of one, so the cursor comes back
        through the argument instead.
        """
        var read = decode_integer(data, at, prefix_bits)
        var cursor = read.after

        var name: String
        if read.value == 0:
            # A new name, spelled out. Bounded the same way a value is, because
            # nothing says a name has to be short and a peer choosing one is a
            # peer choosing how much we allocate.
            var literal = decode_string(data, cursor, self.max_header_list_size)
            cursor = literal.after
            name = literal.value.to_string()
        else:
            var found = self.table.entry(read.value)
            name = found.name.copy()

        var value = decode_string(data, cursor, self.max_header_list_size)
        at = value.after
        return HeaderField(name^, value.value.to_string(), sensitive)


struct HpackEncoder(Movable):
    """Writes header blocks, against a table the peer keeps in step with ours.

    The policy is the obvious one and it is the same one every implementation
    uses: send an index when the table already holds the whole field, otherwise
    send a literal and add it, reusing the name's index when there is one.

    Sensitive fields are the exception and they are never added. RFC 7541
    section 7.1.3: a field whose value is a secret must not go into a table,
    because a table is a place where the length of a compressed block leaks
    whether a guess matched. Which fields those are is not decided here, it
    arrives on the field.
    """

    var table: HpackTable

    var _pending_size: Int
    """A table size to announce at the start of the next block, or -1."""

    def __init__(out self, table_size: Int = DEFAULT_TABLE_SIZE):
        self.table = HpackTable(table_size)
        self._pending_size = -1

    def set_table_size(mut self, size: Int):
        """Take the peer's `SETTINGS_HEADER_TABLE_SIZE`.

        The change is not applied here and then forgotten. RFC 7541 section 4.2
        makes the encoder responsible for telling the decoder, so the new size
        is remembered and goes out as a dynamic table size update at the start
        of the next block. A table quietly resized on one side only is two
        tables that disagree from the next eviction onwards.
        """
        self.table.set_limit(size)
        self._pending_size = size

    def encode(mut self, fields: List[HeaderField], mut out: Bytes) raises:
        if self._pending_size >= 0:
            var size = self._pending_size
            self._pending_size = -1
            self.table.set_capacity(size)
            encode_integer(size, 5, _SIZE_UPDATE, out)

        for i in range(len(fields)):
            self._one(fields[i], out)

    def _one(mut self, field: HeaderField, mut out: Bytes) raises:
        if field.sensitive:
            var named = self.table.find_name(field.name)
            encode_integer(named, 4, _LITERAL_NEVER, out)
            if named == 0:
                encode_string(field.name.as_bytes(), out)
            encode_string(field.value.as_bytes(), out)
            return

        var whole = self.table.find(field.name, field.value)
        if whole != 0:
            encode_integer(whole, 7, _INDEXED, out)
            return

        var named = self.table.find_name(field.name)
        encode_integer(named, 6, _LITERAL_INDEXED, out)
        if named == 0:
            encode_string(field.name.as_bytes(), out)
        encode_string(field.value.as_bytes(), out)
        self.table.add(field.copy())
