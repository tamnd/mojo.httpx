"""HTTP/2 frames, from bytes to values and back.

RFC 9113 section 4. Every frame is a nine octet header and then a payload: a
twenty four bit length, an eight bit type, eight bits of flags, and a thirty one
bit stream identifier with one reserved bit above it. Reading that header cannot
fail, because nine octets are nine octets whatever they say, and that is worth
noticing: it means the connection can always find the start of the next frame
even when the current one is nonsense, which is what lets a violation be
reported and the connection closed in an orderly way rather than resynchronised
by guessing.

Everything that can fail is a separate named check. That is not a stylistic
split. RFC 9113 section 7 gives each violation an error code that has to go out
in a `GOAWAY` or a `RST_STREAM`, and the code is not recoverable from the
message afterwards, so the caller that made the check is the thing that knows
which code to send. Each check below says in its docstring which code it belongs
to, and the connection maps them at the call site.

The one bound this layer owns is the frame length. `SETTINGS_MAX_FRAME_SIZE` is
something we advertise, and a peer that ignores it can announce sixteen megabytes
in three octets, so it is checked on receive and not merely sent. Checking it
before the payload is read is the entire point, since the alternative is to
allocate what the attacker asked for and then object.

Unknown frame types are not an error. RFC 9113 section 4.1 requires them to be
ignored and discarded, which is what makes extensions possible, so nothing here
rejects a type it does not recognise. The connection skips the payload by its
announced length and carries on.
"""

from httpx._bytes import Bytes
from httpx._exceptions import ErrorKind, new_error

comptime PREFACE = StaticString("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
"""The twenty four octets a client sends before anything else.

RFC 9113 section 3.4. It is deliberately something an HTTP/1.1 server cannot
mistake for a request it should answer, which is why it looks like one.
"""

comptime FRAME_HEADER_SIZE = 9

comptime DEFAULT_MAX_FRAME_SIZE = 16384
"""What both sides assume until a `SETTINGS` frame says otherwise."""

comptime MIN_MAX_FRAME_SIZE = 16384
"""The floor `SETTINGS_MAX_FRAME_SIZE` may be set to, RFC 9113 section 6.5.2.

There is a floor at all so that a peer cannot make frames so small that every
header block has to be split across a long run of them, which is work for the
receiver and almost none for whoever asked.
"""

comptime MAX_MAX_FRAME_SIZE = 16777215
"""The ceiling, which is what the twenty four bit length field can express."""

comptime MAX_WINDOW = 0x7FFFFFFF
"""The largest a flow control window may be, per RFC 9113 section 6.9.1."""

comptime DEFAULT_WINDOW_SIZE = 65535
"""Where every window starts, per RFC 9113 section 6.9.2."""


def _remote(message: String) -> Error:
    return new_error(ErrorKind.REMOTE_PROTOCOL_ERROR, message)


struct FrameType(Equatable, ImplicitlyCopyable, Movable):
    """A frame type, which is any octet and not only the ten with names."""

    var value: UInt8

    comptime DATA = Self(0x0)
    comptime HEADERS = Self(0x1)
    comptime PRIORITY = Self(0x2)
    comptime RST_STREAM = Self(0x3)
    comptime SETTINGS = Self(0x4)
    comptime PUSH_PROMISE = Self(0x5)
    comptime PING = Self(0x6)
    comptime GOAWAY = Self(0x7)
    comptime WINDOW_UPDATE = Self(0x8)
    comptime CONTINUATION = Self(0x9)

    def __init__(out self, value: UInt8):
        self.value = value

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value

    def name(self) -> StaticString:
        """The RFC's name for this type, for error messages.

        An unknown type answers with a placeholder rather than raising, because
        the whole point of an unknown type is that it is allowed to arrive.
        """
        if self == Self.DATA:
            return "DATA"
        if self == Self.HEADERS:
            return "HEADERS"
        if self == Self.PRIORITY:
            return "PRIORITY"
        if self == Self.RST_STREAM:
            return "RST_STREAM"
        if self == Self.SETTINGS:
            return "SETTINGS"
        if self == Self.PUSH_PROMISE:
            return "PUSH_PROMISE"
        if self == Self.PING:
            return "PING"
        if self == Self.GOAWAY:
            return "GOAWAY"
        if self == Self.WINDOW_UPDATE:
            return "WINDOW_UPDATE"
        if self == Self.CONTINUATION:
            return "CONTINUATION"
        return "an unknown frame type"


comptime FLAG_END_STREAM = UInt8(0x01)
comptime FLAG_ACK = UInt8(0x01)
"""The same bit as `FLAG_END_STREAM`, and a different thing.

Which of the two it means depends entirely on the frame type, so both names
exist rather than one of them being read for both uses at the call sites.
"""

comptime FLAG_END_HEADERS = UInt8(0x04)
comptime FLAG_PADDED = UInt8(0x08)
comptime FLAG_PRIORITY = UInt8(0x20)


struct ErrorCode(Equatable, ImplicitlyCopyable, Movable):
    """An HTTP/2 error code, as it travels in `GOAWAY` and `RST_STREAM`.

    RFC 9113 section 7. Unknown codes are treated as `INTERNAL_ERROR` on
    receive, so this wraps the whole thirty two bit space rather than only the
    fourteen that are named.
    """

    var value: UInt32

    comptime NO_ERROR = Self(0x0)
    comptime PROTOCOL_ERROR = Self(0x1)
    comptime INTERNAL_ERROR = Self(0x2)
    comptime FLOW_CONTROL_ERROR = Self(0x3)
    comptime SETTINGS_TIMEOUT = Self(0x4)
    comptime STREAM_CLOSED = Self(0x5)
    comptime FRAME_SIZE_ERROR = Self(0x6)
    comptime REFUSED_STREAM = Self(0x7)
    comptime CANCEL = Self(0x8)
    comptime COMPRESSION_ERROR = Self(0x9)
    comptime CONNECT_ERROR = Self(0xA)
    comptime ENHANCE_YOUR_CALM = Self(0xB)
    comptime INADEQUATE_SECURITY = Self(0xC)
    comptime HTTP_1_1_REQUIRED = Self(0xD)

    def __init__(out self, value: UInt32):
        self.value = value

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value

    def name(self) -> StaticString:
        if self == Self.NO_ERROR:
            return "NO_ERROR"
        if self == Self.PROTOCOL_ERROR:
            return "PROTOCOL_ERROR"
        if self == Self.INTERNAL_ERROR:
            return "INTERNAL_ERROR"
        if self == Self.FLOW_CONTROL_ERROR:
            return "FLOW_CONTROL_ERROR"
        if self == Self.SETTINGS_TIMEOUT:
            return "SETTINGS_TIMEOUT"
        if self == Self.STREAM_CLOSED:
            return "STREAM_CLOSED"
        if self == Self.FRAME_SIZE_ERROR:
            return "FRAME_SIZE_ERROR"
        if self == Self.REFUSED_STREAM:
            return "REFUSED_STREAM"
        if self == Self.CANCEL:
            return "CANCEL"
        if self == Self.COMPRESSION_ERROR:
            return "COMPRESSION_ERROR"
        if self == Self.CONNECT_ERROR:
            return "CONNECT_ERROR"
        if self == Self.ENHANCE_YOUR_CALM:
            return "ENHANCE_YOUR_CALM"
        if self == Self.INADEQUATE_SECURITY:
            return "INADEQUATE_SECURITY"
        if self == Self.HTTP_1_1_REQUIRED:
            return "HTTP_1_1_REQUIRED"
        return "an unknown error code"


def read_uint16[o: ImmOrigin](data: Span[UInt8, o], at: Int) -> UInt32:
    return (UInt32(data[at]) << 8) | UInt32(data[at + 1])


def read_uint24[o: ImmOrigin](data: Span[UInt8, o], at: Int) -> UInt32:
    return (
        (UInt32(data[at]) << 16)
        | (UInt32(data[at + 1]) << 8)
        | UInt32(data[at + 2])
    )


def read_uint32[o: ImmOrigin](data: Span[UInt8, o], at: Int) -> UInt32:
    return (UInt32(data[at]) << 24) | read_uint24(data, at + 1)


def write_uint16(value: UInt32, mut out: Bytes):
    out.append(UInt8((value >> 8) & 0xFF))
    out.append(UInt8(value & 0xFF))


def write_uint24(value: UInt32, mut out: Bytes):
    out.append(UInt8((value >> 16) & 0xFF))
    write_uint16(value, out)


def write_uint32(value: UInt32, mut out: Bytes):
    out.append(UInt8((value >> 24) & 0xFF))
    write_uint24(value, out)


struct FrameHeader(ImplicitlyCopyable, Movable):
    """The nine octets in front of every frame."""

    var length: Int
    """How many octets of payload follow. Not yet known to be acceptable."""

    var type: FrameType

    var flags: UInt8

    var stream_id: UInt32
    """Thirty one bits. Zero means the connection rather than a stream."""

    def __init__(
        out self, length: Int, type: FrameType, flags: UInt8, stream_id: UInt32
    ):
        self.length = length
        self.type = type
        self.flags = flags
        self.stream_id = stream_id

    def has(self, flag: UInt8) -> Bool:
        return (self.flags & flag) != 0


def parse_frame_header[
    o: ImmOrigin
](data: Span[UInt8, o], at: Int) -> FrameHeader:
    """Read the nine octets at `at`. The caller has already checked they are there.

    This does not raise and there is nothing it could raise about. The reserved
    bit above the stream identifier is masked off rather than rejected, which
    RFC 9113 section 4.1 requires: a receiver must ignore it, so that it can be
    given a meaning later without every existing implementation refusing.
    """
    return FrameHeader(
        Int(read_uint24(data, at)),
        FrameType(data[at + 3]),
        data[at + 4],
        read_uint32(data, at + 5) & 0x7FFFFFFF,
    )


def write_frame_header(header: FrameHeader, mut out: Bytes):
    write_uint24(UInt32(header.length), out)
    out.append(header.type.value)
    out.append(header.flags)
    write_uint32(header.stream_id, out)


def check_frame_length(header: FrameHeader, max_frame_size: Int) raises:
    """`FRAME_SIZE_ERROR`. RFC 9113 section 4.2.

    Called before the payload is read, which is the only time it is worth
    anything. A peer that ignores the setting can put sixteen megabytes in three
    octets, and a receiver that read the payload first and objected afterwards
    would have already done what it was being asked to do.
    """
    if header.length > max_frame_size:
        raise _remote(
            String(
                "the server sent a ",
                header.type.name(),
                " frame of ",
                header.length,
                " bytes, over the ",
                max_frame_size,
                " we advertised",
            )
        )


def check_fixed_length(header: FrameHeader, expected: Int) raises:
    """`FRAME_SIZE_ERROR`. The types whose payload is one fixed shape.

    `RST_STREAM` is four octets, `PRIORITY` five, `PING` eight,
    `WINDOW_UPDATE` four, and RFC 9113 says anything else is a size error rather
    than a payload to interpret as far as it goes.
    """
    if header.length != expected:
        raise _remote(
            String(
                "the server sent a ",
                header.type.name(),
                " frame of ",
                header.length,
                " bytes, which is not the ",
                expected,
                " that type has",
            )
        )


def check_on_stream(header: FrameHeader) raises:
    """`PROTOCOL_ERROR`. Types that must name a stream, RFC 9113 section 6.

    A `HEADERS` frame on stream zero is not a header block for the connection,
    it is a peer whose idea of the connection has diverged from ours.
    """
    if header.stream_id == 0:
        raise _remote(
            String(
                "the server sent a ",
                header.type.name(),
                (
                    " frame on stream zero, which is the connection and not a"
                    " stream"
                ),
            )
        )


def check_on_connection(header: FrameHeader) raises:
    """`PROTOCOL_ERROR`. Types that must be on stream zero, RFC 9113 section 6.

    `SETTINGS`, `PING` and `GOAWAY` are about the connection. Carrying one on a
    stream would make it ambiguous whether it applied to that stream alone.
    """
    if header.stream_id != 0:
        raise _remote(
            String(
                "the server sent a ",
                header.type.name(),
                " frame on stream ",
                header.stream_id,
                ", and that type belongs to the connection",
            )
        )


def strip_padding[
    o: ImmOrigin
](header: FrameHeader, payload: Span[UInt8, o]) raises -> Span[UInt8, o]:
    """`PROTOCOL_ERROR`. Remove the pad length octet and the padding it counts.

    RFC 9113 section 6.1. The pad length is inside the announced length, so a
    frame can claim more padding than it has room for. That is worth refusing
    rather than clamping: padding exists to hide the size of what it wraps, and
    a receiver that quietly reinterpreted an impossible pad length would be
    reading a different number of body octets than the sender wrote.
    """
    if not header.has(FLAG_PADDED):
        return payload

    if len(payload) < 1:
        raise _remote(
            String(
                "the server sent a padded ",
                header.type.name(),
                " frame with no room for the pad length",
            )
        )

    var padding = Int(payload[0])
    if padding >= len(payload):
        raise _remote(
            String(
                "the server sent a ",
                header.type.name(),
                " frame claiming ",
                padding,
                " bytes of padding in a ",
                len(payload),
                " byte payload",
            )
        )
    return payload[1 : len(payload) - padding]


struct Priority(ImplicitlyCopyable, Movable):
    """The five octet priority block, RFC 9113 section 6.3.

    Parsed because it takes up room in front of a header block and the block
    cannot be found without it. RFC 9113 deprecates the scheme itself, so
    nothing is expected to act on these values.
    """

    var exclusive: Bool
    var depends_on: UInt32
    var weight: UInt8

    def __init__(out self, exclusive: Bool, depends_on: UInt32, weight: UInt8):
        self.exclusive = exclusive
        self.depends_on = depends_on
        self.weight = weight


def parse_priority[o: ImmOrigin](data: Span[UInt8, o], at: Int) -> Priority:
    var word = read_uint32(data, at)
    return Priority((word & 0x80000000) != 0, word & 0x7FFFFFFF, data[at + 4])


def strip_priority[
    o: ImmOrigin
](header: FrameHeader, payload: Span[UInt8, o]) raises -> Span[UInt8, o]:
    """`PROTOCOL_ERROR`. Remove the priority block a `HEADERS` frame may carry.

    Called after `strip_padding`, because RFC 9113 section 6.2 puts the pad
    length first and the padding last, with the priority block between the two.
    """
    if not header.has(FLAG_PRIORITY):
        return payload

    if len(payload) < 5:
        raise _remote(
            "the server sent a HEADERS frame with a priority flag and no room"
            " for the priority block"
        )
    return payload[5:]


def parse_window_update[
    o: ImmOrigin
](header: FrameHeader, payload: Span[UInt8, o]) raises -> Int:
    """`PROTOCOL_ERROR` on a zero increment, RFC 9113 section 6.9.

    A window update of nothing is refused rather than ignored because it is not
    a thing a working peer sends, and a peer that sends a stream of them is
    spending our time to no purpose.
    """
    var increment = Int(read_uint32(payload, 0) & 0x7FFFFFFF)
    if increment == 0:
        raise _remote(
            String(
                "the server sent a window update of zero on stream ",
                header.stream_id,
            )
        )
    return increment


struct Goaway(Movable):
    """The last stream the peer will act on, why it stopped, and any debug text.

    RFC 9113 section 6.8. `debug` is opaque and may be anything, so it is kept
    as bytes and never interpreted.
    """

    var last_stream_id: UInt32
    var error_code: ErrorCode
    var debug: Bytes

    def __init__(
        out self,
        last_stream_id: UInt32,
        error_code: ErrorCode,
        var debug: Bytes,
    ):
        self.last_stream_id = last_stream_id
        self.error_code = error_code
        self.debug = debug^


def parse_goaway[o: ImmOrigin](payload: Span[UInt8, o]) raises -> Goaway:
    """`FRAME_SIZE_ERROR` when there is not room for the two fixed fields."""
    if len(payload) < 8:
        raise _remote(
            String(
                "the server sent a GOAWAY frame of ",
                len(payload),
                " bytes, and the fixed part alone is 8",
            )
        )

    var debug = Bytes()
    debug.extend(payload[8:])
    return Goaway(
        read_uint32(payload, 0) & 0x7FFFFFFF,
        ErrorCode(read_uint32(payload, 4)),
        debug^,
    )
