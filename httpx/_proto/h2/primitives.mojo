"""The two things HPACK is built out of: integers and string literals.

RFC 7541 sections 5.1 and 5.2. Everything else in HPACK, the indexed field, the
literal with and without indexing, the dynamic table size update, is a handful of
flag bits followed by one of these two.

Both are variable length and both are read from bytes a peer chose, so both are
places where a decoder can be made to misbehave. The integer coding continues
across as many octets as the sender likes, and the string coding announces its
own length. Neither has a bound in the specification, so the bounds are here.

For integers the bound is the number of continuation octets. Refusing on the
value alone is not enough, because an octet of `0x80` adds nothing to the value
while extending the encoding, so a sender can keep a decoder reading forever
with the value pinned at zero. Five continuation octets carry more than a thirty
two bit value can hold, and everything HPACK counts is an index or a length, so
anything longer is refused whatever it decodes to.

For strings the bound is the length of the result, and the caller supplies it.
There is no variant of `decode_string` without one, because the caller always
knows what it is reading into and what size the peer has already agreed to.
"""

from httpx._bytes import Bytes
from httpx._exceptions import ErrorKind, new_error
from httpx._proto.h2.huffman import (
    huffman_decode,
    huffman_encode,
    huffman_encoded_length,
)

comptime MAX_INTEGER = 0x7FFFFFFF
"""The largest value an HPACK integer may decode to.

Every integer in HPACK is an index into a table, a length in bytes, or a
settings value, and none of those is ever near this. The limit is here so that
the decoder has a definite answer rather than whatever the machine word does.
"""

comptime _MAX_SHIFT = 28
"""Five continuation octets, which is all a value up to `MAX_INTEGER` needs."""

comptime _HUFFMAN_FLAG = UInt8(0x80)


def _remote(message: String) -> Error:
    return new_error(ErrorKind.REMOTE_PROTOCOL_ERROR, message)


def _local(message: String) -> Error:
    return new_error(ErrorKind.LOCAL_PROTOCOL_ERROR, message)


struct IntegerField(ImplicitlyCopyable, Movable):
    """A decoded integer, and where reading it stopped."""

    var value: Int

    var after: Int
    """The index just past the last octet consumed."""

    def __init__(out self, value: Int, after: Int):
        self.value = value
        self.after = after


struct StringField(Movable):
    """A decoded string literal, and where reading it stopped."""

    var value: Bytes

    var after: Int
    """The index just past the last octet consumed."""

    def __init__(out self, var value: Bytes, after: Int):
        self.value = value^
        self.after = after


def encode_integer(
    value: Int, prefix_bits: Int, flags: UInt8, mut out: Bytes
) raises:
    """Append `value` in a `prefix_bits` wide prefix, under `flags`.

    `flags` are the bits above the prefix, already in position: `0x80` for an
    indexed field, `0x40` for a literal that gets indexed, and so on. They are
    passed in rather than stitched on afterwards because the prefix octet is one
    octet and building it in one place is the only way to be sure the two halves
    never overlap.
    """
    if prefix_bits < 1 or prefix_bits > 8:
        raise _local(
            String(
                "an HPACK integer prefix of ",
                prefix_bits,
                " bits is not 1 to 8",
            )
        )
    if value < 0:
        raise _local("an HPACK integer cannot be negative")

    var ceiling = (1 << prefix_bits) - 1
    if value < ceiling:
        out.append(flags | UInt8(value))
        return

    out.append(flags | UInt8(ceiling))
    var left = value - ceiling
    while left >= 128:
        out.append(UInt8((left & 0x7F) | 0x80))
        left >>= 7
    out.append(UInt8(left))


def decode_integer[
    o: ImmOrigin
](data: Span[UInt8, o], at: Int, prefix_bits: Int) raises -> IntegerField:
    """Read the integer starting at `at`, using a `prefix_bits` wide prefix.

    The flag bits above the prefix are the caller's business and are ignored
    here, because the same prefix octet carries both and only the caller knows
    which pattern it was looking for.
    """
    if prefix_bits < 1 or prefix_bits > 8:
        raise _local(
            String(
                "an HPACK integer prefix of ",
                prefix_bits,
                " bits is not 1 to 8",
            )
        )
    if at >= len(data):
        raise _remote("the server sent a truncated HPACK integer")

    var ceiling = (1 << prefix_bits) - 1
    var value = Int(data[at]) & ceiling
    var next = at + 1
    if value < ceiling:
        return IntegerField(value, next)

    var shift = 0
    while True:
        if next >= len(data):
            raise _remote("the server sent a truncated HPACK integer")
        if shift > _MAX_SHIFT:
            raise _remote(
                "the server sent an HPACK integer spread over more octets than"
                " a value can need"
            )
        var byte = data[next]
        next += 1
        value += Int(byte & 0x7F) << shift
        if value > MAX_INTEGER:
            raise _remote(
                String(
                    "the server sent an HPACK integer larger than ", MAX_INTEGER
                )
            )
        if byte & 0x80 == 0:
            return IntegerField(value, next)
        shift += 7


def encode_string[o: ImmOrigin](data: Span[UInt8, o], mut out: Bytes) raises:
    """Append `data` as a string literal, Huffman coded when that is smaller.

    The choice is made by measuring rather than by guessing from the content.
    Huffman is a win on the header text that shaped the code and a loss on
    anything else, and the only way to know which one a given value is, is to
    add up the code lengths.

    A tie goes to the coded form. The two are the same size on the wire, length
    octet included, so nothing is being traded away, and it is what the encoder
    behind the RFC 7541 appendix C examples does, which keeps those usable as
    test vectors for this one. The empty string is the one tie that does not,
    because there is no code to send and `00` is what the flag being clear is
    for.
    """
    var coded = huffman_encoded_length(data)
    if coded > 0 and coded <= len(data):
        encode_integer(coded, 7, _HUFFMAN_FLAG, out)
        huffman_encode(data, out)
        return

    encode_integer(len(data), 7, 0, out)
    out.extend(data)


def decode_string[
    o: ImmOrigin
](data: Span[UInt8, o], at: Int, limit: Int) raises -> StringField:
    """Read the string literal starting at `at`, refusing to exceed `limit`.

    `limit` applies to the decoded result, not to what is on the wire. That is
    the distinction that matters: a Huffman string is a compression, so a short
    run of octets can expand a long way, and a decoder that only checked the
    announced length would have already been talked into the allocation by the
    time it looked.
    """
    if at >= len(data):
        raise _remote("the server sent a truncated HPACK string")

    var huffman = (data[at] & _HUFFMAN_FLAG) != 0
    var header = decode_integer(data, at, 7)
    var length = header.value
    var start = header.after
    if length > len(data) - start:
        raise _remote(
            String(
                "the server sent an HPACK string of ",
                length,
                " bytes with only ",
                len(data) - start,
                " left to read",
            )
        )

    var end = start + length
    if huffman:
        return StringField(huffman_decode(data[start:end], limit), end)

    if length > limit:
        raise _remote(
            String(
                "the server sent an HPACK string of ",
                length,
                " bytes, over the ",
                limit,
                " byte limit",
            )
        )
    return StringField(Bytes(data[start:end]), end)
