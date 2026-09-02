"""The `SETTINGS` frame, and what each parameter is allowed to be.

RFC 9113 section 6.5. Settings are not a negotiation. Each side announces what
it will do, the other acknowledges, and there is no version where one side
proposes and the other counters. What that means in practice is that a value we
send takes effect for the peer when the peer acknowledges it, and a value the
peer sends takes effect for us the moment we read it, so the two directions are
independent and are kept in separate values rather than in one merged view.

Three of the parameters have ranges, and they are refused rather than clamped
for the same reason a dynamic table size update over the limit is: a value we
silently corrected is a value the peer still believes is in force, and every
frame after that is exchanged between two endpoints with different ideas of what
the connection allows.

Unknown identifiers are ignored, per section 6.5.3. That is what makes it
possible to add a setting without every existing implementation refusing the
frame that carries it, and it is the reason a receiver may not treat the
identifier space as closed.
"""

from httpx._bytes import Bytes
from httpx._exceptions import ErrorKind, new_error
from httpx._proto.h2.frames import (
    DEFAULT_MAX_FRAME_SIZE,
    DEFAULT_WINDOW_SIZE,
    FLAG_ACK,
    FrameHeader,
    MAX_MAX_FRAME_SIZE,
    MAX_WINDOW,
    MIN_MAX_FRAME_SIZE,
    read_uint16,
    read_uint32,
    write_uint16,
    write_uint32,
)
from httpx._proto.h2.table import DEFAULT_TABLE_SIZE

comptime SETTING_SIZE = 6
"""Two octets of identifier and four of value, per RFC 9113 section 6.5.1."""

comptime UNLIMITED = -1
"""What a parameter with no default and no announced value means.

`SETTINGS_MAX_CONCURRENT_STREAMS` and `SETTINGS_MAX_HEADER_LIST_SIZE` are the
two the RFC leaves unset rather than giving a number, and treating an absent
value as zero would be the opposite of what it means.
"""

comptime SETTING_HEADER_TABLE_SIZE = UInt32(0x1)
comptime SETTING_ENABLE_PUSH = UInt32(0x2)
comptime SETTING_MAX_CONCURRENT_STREAMS = UInt32(0x3)
comptime SETTING_INITIAL_WINDOW_SIZE = UInt32(0x4)
comptime SETTING_MAX_FRAME_SIZE = UInt32(0x5)
comptime SETTING_MAX_HEADER_LIST_SIZE = UInt32(0x6)


def _remote(message: String) -> Error:
    return new_error(ErrorKind.REMOTE_PROTOCOL_ERROR, message)


struct Settings(ImplicitlyCopyable, Movable):
    """One side's parameters, starting at the defaults RFC 9113 gives."""

    var header_table_size: Int
    var enable_push: Bool
    var max_concurrent_streams: Int
    var initial_window_size: Int
    var max_frame_size: Int
    var max_header_list_size: Int

    def __init__(out self):
        self.header_table_size = DEFAULT_TABLE_SIZE
        self.enable_push = True
        self.max_concurrent_streams = UNLIMITED
        self.initial_window_size = DEFAULT_WINDOW_SIZE
        self.max_frame_size = DEFAULT_MAX_FRAME_SIZE
        self.max_header_list_size = UNLIMITED

    def apply(mut self, identifier: UInt32, value: UInt32) raises:
        """Take one identifier and value pair, checking the ones with ranges.

        The ranges are RFC 9113 section 6.5.2. `ENABLE_PUSH` and
        `MAX_FRAME_SIZE` are `PROTOCOL_ERROR` when out of range and
        `INITIAL_WINDOW_SIZE` is `FLOW_CONTROL_ERROR`, which is the one place in
        this file where the code is not the same for every failure.
        """
        if identifier == SETTING_HEADER_TABLE_SIZE:
            self.header_table_size = Int(value)
            return

        if identifier == SETTING_ENABLE_PUSH:
            # `PROTOCOL_ERROR`. Anything but a flag here means the peer and we
            # disagree about whether pushed streams may arrive at all, and the
            # cost of guessing wrong is accepting streams we never asked for.
            if value > 1:
                raise _remote(
                    String(
                        "the server set SETTINGS_ENABLE_PUSH to ",
                        value,
                        ", and it is a flag",
                    )
                )
            self.enable_push = value == 1
            return

        if identifier == SETTING_MAX_CONCURRENT_STREAMS:
            self.max_concurrent_streams = Int(value)
            return

        if identifier == SETTING_INITIAL_WINDOW_SIZE:
            # `FLOW_CONTROL_ERROR`. A window is a signed thirty one bit count,
            # and a starting value above that is one no arithmetic on it can
            # stay inside.
            if Int(value) > MAX_WINDOW:
                raise _remote(
                    String(
                        "the server set SETTINGS_INITIAL_WINDOW_SIZE to ",
                        value,
                        ", over the ",
                        MAX_WINDOW,
                        " a window can hold",
                    )
                )
            self.initial_window_size = Int(value)
            return

        if identifier == SETTING_MAX_FRAME_SIZE:
            # `PROTOCOL_ERROR`. The floor matters as much as the ceiling: a peer
            # that set this to a handful of octets would force every header
            # block into a long run of CONTINUATION frames, which costs us to
            # reassemble and costs it almost nothing to ask for.
            var size = Int(value)
            if size < MIN_MAX_FRAME_SIZE or size > MAX_MAX_FRAME_SIZE:
                raise _remote(
                    String(
                        "the server set SETTINGS_MAX_FRAME_SIZE to ",
                        value,
                        ", outside the ",
                        MIN_MAX_FRAME_SIZE,
                        " to ",
                        MAX_MAX_FRAME_SIZE,
                        " it may be",
                    )
                )
            self.max_frame_size = size
            return

        if identifier == SETTING_MAX_HEADER_LIST_SIZE:
            self.max_header_list_size = Int(value)
            return

        # Anything else is a setting from a later specification or an extension,
        # and RFC 9113 section 6.5.3 requires it to be ignored rather than
        # refused. Refusing would make this implementation the reason a peer
        # could not adopt one.


def check_settings_length(header: FrameHeader) raises:
    """`FRAME_SIZE_ERROR`. RFC 9113 section 6.5.

    An acknowledgement carries nothing, and anything else has to divide into
    whole six octet pairs. A payload that does not is not a frame with a
    trailing fragment to ignore, it is a frame whose every pair may be
    misaligned.
    """
    if header.has(FLAG_ACK):
        if header.length != 0:
            raise _remote(
                String(
                    "the server sent a SETTINGS acknowledgement carrying ",
                    header.length,
                    " bytes",
                )
            )
        return

    if header.length % SETTING_SIZE != 0:
        raise _remote(
            String(
                "the server sent a SETTINGS frame of ",
                header.length,
                " bytes, which is not a whole number of settings",
            )
        )


def apply_settings[
    o: ImmOrigin
](mut settings: Settings, payload: Span[UInt8, o]) raises:
    """Apply every pair in a `SETTINGS` payload, in the order they were sent.

    In order, and not by gathering them first. RFC 9113 section 6.5 lets a frame
    carry the same identifier more than once and says the last one wins, so
    anything that deduplicated ahead of time would have to reimplement that
    rule instead of getting it for free.
    """
    for at in range(0, len(payload), SETTING_SIZE):
        settings.apply(read_uint16(payload, at), read_uint32(payload, at + 2))


def write_settings(settings: Settings, mut out: Bytes):
    """Append the payload announcing what a client has an opinion about.

    `SETTINGS_MAX_CONCURRENT_STREAMS` is not among them. It bounds the streams
    the peer may open towards us, and with push disabled there are none, so
    sending a number would be describing a limit on something that cannot
    happen.
    """
    _pair(SETTING_HEADER_TABLE_SIZE, UInt32(settings.header_table_size), out)
    _pair(
        SETTING_ENABLE_PUSH,
        UInt32(1) if settings.enable_push else UInt32(0),
        out,
    )
    _pair(
        SETTING_INITIAL_WINDOW_SIZE, UInt32(settings.initial_window_size), out
    )
    _pair(SETTING_MAX_FRAME_SIZE, UInt32(settings.max_frame_size), out)
    if settings.max_header_list_size != UNLIMITED:
        _pair(
            SETTING_MAX_HEADER_LIST_SIZE,
            UInt32(settings.max_header_list_size),
            out,
        )


def _pair(identifier: UInt32, value: UInt32, mut out: Bytes):
    write_uint16(identifier, out)
    write_uint32(value, out)
