"""The HTTP/2 connection, with no socket in it.

Everything the protocol says happens between two peers, expressed as bytes in
and events out. Nothing here reads, writes, waits or knows what a deadline is.
The transport that owns a socket drives this: it hands over each frame it has
read and sends whatever `take_outbound` gives back.

Splitting it this way is not tidiness. An HTTP/2 connection has more rules in it
than the rest of this library put together, and most of them are about sequences
of frames rather than single ones. A settings acknowledgement that never comes, a
header block interrupted by a frame on another stream, a window that goes
negative because the peer lowered the initial size mid transfer: none of those
can be provoked one frame at a time against something that also owns a socket.
Here they are three lines of a test.

The other half of the reason is multiplexing. Requests on one connection do not
take turns, so the code that decides what may be written next cannot live inside
any one request. It lives here, looking at every stream at once.

What this does not do is decide when to wait. A send window that never opens is
a stall, and the answer to a stall is a deadline, which belongs with the socket.
This reports that nothing may be sent and lets the caller decide how long to put
up with it.
"""

from httpx._bytes import Bytes
from httpx._exceptions import ErrorKind, new_error
from httpx._proto.h2.blocks import HeaderBlock
from httpx._proto.h2.frames import (
    FLAG_ACK,
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FrameHeader,
    FrameType,
    Goaway,
    ErrorCode,
    PREFACE,
    check_fixed_length,
    check_frame_length,
    check_on_connection,
    check_on_stream,
    parse_goaway,
    parse_window_update,
    read_uint32,
    strip_padding,
    strip_priority,
    write_frame_header,
    write_uint32,
)
from httpx._proto.h2.hpack import (
    DEFAULT_MAX_HEADER_LIST_SIZE,
    HpackDecoder,
    HpackEncoder,
)
from httpx._proto.h2.settings import (
    UNLIMITED,
    Settings,
    apply_settings,
    check_settings_length,
    write_settings,
)
from httpx._proto.h2.stream import (
    H2Stream,
    ResetTracker,
    StreamIds,
    StreamState,
)
from httpx._proto.h2.table import HeaderField
from httpx._proto.h2.window import ReceiveWindow, SendWindow

comptime PING_SIZE = 8
"""RFC 9113 section 6.7. Eight octets of opaque data, echoed back unchanged."""

comptime RST_STREAM_SIZE = 4
comptime WINDOW_UPDATE_SIZE = 4
comptime PRIORITY_SIZE = 5

comptime GOAWAY_FIXED_SIZE = 8
"""The last stream identifier and the error code. Debug text may follow."""

comptime DEFAULT_MAX_CONCURRENT_STREAMS = 100
"""How many streams we will have open at once before queueing.

Not a bound the RFC sets on us, it is one we set on ourselves. The peer's
`SETTINGS_MAX_CONCURRENT_STREAMS` bounds it further when the peer sends one, and
this is the number used until it does.
"""


def _remote(message: String) -> Error:
    return new_error(ErrorKind.REMOTE_PROTOCOL_ERROR, message)


def _local(message: String) -> Error:
    return new_error(ErrorKind.LOCAL_PROTOCOL_ERROR, message)


struct H2EventKind(Equatable, ImplicitlyCopyable, Movable):
    """What kind of thing came out of a frame."""

    var value: Int

    comptime NOTHING = Self(0)
    """The frame was handled and there is nothing for the caller to do.

    Most frames are this. A settings acknowledgement, a window update, a
    `PRIORITY` frame, a fragment of a header block that is not finished yet: all
    of them change state here and none of them concern whoever is waiting for a
    response.
    """

    comptime SETTINGS_CHANGED = Self(1)
    comptime SETTINGS_ACKED = Self(2)
    comptime PING_ACKED = Self(3)

    comptime HEADERS = Self(4)
    """A complete header block arrived and decoded. `fields` has it."""

    comptime DATA = Self(5)
    comptime STREAM_RESET = Self(6)
    comptime GOAWAY = Self(7)

    def __init__(out self, value: Int):
        self.value = value

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value


struct H2Event(Movable):
    """One thing that happened, for a caller that is waiting on a stream.

    One struct with every field rather than a variant per kind. The fields that
    do not apply to a kind are empty, which is a real cost in tidiness, and the
    thing bought with it is that a caller can look at `kind` and then at what it
    needs without any unwrapping in between.
    """

    var kind: H2EventKind
    var stream_id: UInt32

    var end_stream: Bool
    """Set on `HEADERS` and `DATA` when this was the last of the response."""

    var fields: List[HeaderField]
    var data: Bytes
    var error_code: ErrorCode

    def __init__(out self, kind: H2EventKind, stream_id: UInt32 = 0):
        self.kind = kind
        self.stream_id = stream_id
        self.end_stream = False
        self.fields = List[HeaderField]()
        self.data = Bytes()
        self.error_code = ErrorCode.NO_ERROR


struct H2Connection(Movable):
    """One HTTP/2 connection: its settings, its streams and its two windows."""

    var settings: Settings
    """What we advertised. The peer is held to these on everything it sends."""

    var peer_settings: Settings
    """What the peer advertised. We are held to these on everything we send."""

    var encoder: HpackEncoder
    var decoder: HpackDecoder

    var send_window: SendWindow
    """The connection window, which is separate from every stream's.

    A `DATA` frame is charged to both, so a stream with room to spare still
    cannot send when the connection window is empty. Keeping them separate is
    what stops one large download from starving every other stream on the
    connection.
    """

    var recv_window: ReceiveWindow

    var block: HeaderBlock
    var ids: StreamIds
    var resets: ResetTracker

    var streams: List[H2Stream]
    """The streams that are still live. Closed ones are dropped.

    Dropping them is a bound, not housekeeping. A connection that kept a record
    of every stream it had ever opened would grow for as long as it stayed up,
    and a peer that wanted it to grow faster only has to make requests.
    """

    var outbound: Bytes
    """Bytes waiting for the transport to write."""

    var _block_end_stream: Bool
    """Whether the `HEADERS` that opened the current block ended the stream.

    A `CONTINUATION` carries no flags of its own but `END_HEADERS`, so the
    decision made by the frame that started the block has to be carried until
    the block finishes.
    """

    var settings_acked: Bool
    var goaway: Optional[Goaway]

    def __init__(
        out self,
        var settings: Settings = Settings(),
        max_concurrent_streams: Int = DEFAULT_MAX_CONCURRENT_STREAMS,
    ):
        # Push is refused here and not later. RFC 9113 section 8.4 lets a server
        # open streams towards us, and a client with no way to surface a pushed
        # response has nothing to do with one but pay for it, so the setting goes
        # out as zero in the very first frame we send and any PUSH_PROMISE after
        # that is a protocol error rather than something to decline politely.
        settings.enable_push = False
        settings.max_concurrent_streams = max_concurrent_streams

        # An unset SETTINGS_MAX_HEADER_LIST_SIZE is what the RFC defaults to and
        # it is the HPACK bomb with the safety off: a compressed block of a few
        # hundred octets decodes to as much as the peer likes, and a decoder with
        # no ceiling will build all of it. So a number is always advertised, and
        # the same number bounds our decoder, which is what makes it a promise
        # rather than a hint.
        if settings.max_header_list_size == UNLIMITED:
            settings.max_header_list_size = DEFAULT_MAX_HEADER_LIST_SIZE

        self.encoder = HpackEncoder()
        self.decoder = HpackDecoder(
            settings.header_table_size, settings.max_header_list_size
        )
        self.send_window = SendWindow()
        self.recv_window = ReceiveWindow(settings.initial_window_size)
        self.block = HeaderBlock()
        self.ids = StreamIds()
        self.resets = ResetTracker()
        self.streams = List[H2Stream]()
        self.outbound = Bytes()
        self._block_end_stream = False
        self.settings_acked = False
        self.goaway = None
        self.peer_settings = Settings()
        self.settings = settings^

    def start(mut self):
        """Queue the preface and our opening `SETTINGS`.

        RFC 9113 section 3.4. The two go out together and before anything else,
        including before the server has said anything, because HTTP/2 has no
        round trip to agree on: a client that waited for the server's settings
        before sending its own would be waiting for a server that is doing the
        same thing.
        """
        self.outbound.extend(PREFACE.as_bytes())
        self._write_settings()

    def take_outbound(mut self) -> Bytes:
        """Everything queued so far, and reset."""
        var pending = self.outbound^
        self.outbound = Bytes()
        return pending^

    def is_open(self) -> Bool:
        """False once the peer has said it is going away or we are out of ids.
        """
        return not self.goaway and not self.ids.exhausted()

    def concurrency(self) -> Int:
        """How many more streams may be opened right now.

        The peer's limit when it has sent one, ours otherwise. `UNLIMITED` from
        the peer means it has no opinion, not that we have none.
        """
        var limit = self.settings.max_concurrent_streams
        var theirs = self.peer_settings.max_concurrent_streams
        if theirs != UNLIMITED and theirs < limit:
            limit = theirs
        var live = len(self.streams)
        return limit - live if limit > live else 0

    def receive_frame[
        o: ImmOrigin
    ](mut self, header: FrameHeader, payload: Span[UInt8, o]) raises -> H2Event:
        """Take one frame and say what it meant.

        The length is checked again here even though a reader that has already
        got the payload must have checked it to know how much to read. It costs
        nothing and it means this is safe to call from a test that has not.
        """
        check_frame_length(header, self.settings.max_frame_size)

        # Section 6.10 before anything else. While a header block is open the
        # only frame that may arrive at all is a CONTINUATION on the same
        # stream, so asking what type this is before asking whether it is
        # allowed would be interpreting a frame that has no business existing.
        self.block.check_allows(header)

        if header.type == FrameType.DATA:
            return self._data(header, payload)
        if header.type == FrameType.HEADERS:
            return self._headers(header, payload)
        if header.type == FrameType.CONTINUATION:
            return self._continuation(header, payload)
        if header.type == FrameType.SETTINGS:
            return self._settings(header, payload)
        if header.type == FrameType.PING:
            return self._ping(header, payload)
        if header.type == FrameType.GOAWAY:
            return self._goaway(header, payload)
        if header.type == FrameType.WINDOW_UPDATE:
            return self._window_update(header, payload)
        if header.type == FrameType.RST_STREAM:
            return self._rst_stream(header, payload)
        if header.type == FrameType.PRIORITY:
            return self._priority(header)
        if header.type == FrameType.PUSH_PROMISE:
            raise _remote(
                "the server sent a PUSH_PROMISE after we turned push off"
            )

        # RFC 9113 section 4.1 requires an unknown type to be discarded rather
        # than refused, which is what lets a later specification add one without
        # every existing implementation being the reason it cannot be used.
        return H2Event(H2EventKind.NOTHING)

    def send_headers(
        mut self, var fields: List[HeaderField], end_stream: Bool
    ) raises -> UInt32:
        """Open a stream with a request head. Returns its identifier."""
        if self.goaway:
            raise _local(
                "tried to open a stream on a connection the server is closing"
            )
        if self.concurrency() == 0:
            raise _local(
                String(
                    "tried to open a stream with ",
                    len(self.streams),
                    " already open and no room for another",
                )
            )

        var id = self.ids.take()
        var stream = H2Stream(
            id,
            send_window=self.peer_settings.initial_window_size,
            recv_window=self.settings.initial_window_size,
        )
        stream.send_headers(end_stream)
        self.streams.append(stream^)

        var encoded = Bytes()
        self.encoder.encode(fields, encoded)
        self._write_block(id, encoded, end_stream)
        return id

    def send_data[
        o: ImmOrigin
    ](
        mut self, stream_id: UInt32, data: Span[UInt8, o], end_stream: Bool
    ) raises -> Int:
        """Send what fits of `data` and say how much that was.

        Zero is a normal answer and not a failure. It means a window is shut,
        and the caller's business is then to wait for a `WINDOW_UPDATE` rather
        than to give up. Only the caller knows how long that is worth waiting
        for, which is why the deadline is not here.

        `end_stream` is only honoured when the whole of `data` went out, since a
        stream cannot be ended halfway through the body it was carrying.
        """
        var index = self._find(stream_id)
        if index < 0:
            raise _local(
                String(
                    "tried to send a body on stream ",
                    stream_id,
                    ", which is not open",
                )
            )

        var wanted = len(data)
        var room = self.send_window.allows(wanted)
        room = self.streams[index].send.allows(room)
        room = min(room, self.peer_settings.max_frame_size)

        # An empty frame carrying nothing but END_STREAM is the one case where
        # no room is not a reason to send nothing. Flow control counts octets
        # and there are none, so a shut window has no say in it, and it is the
        # only way to end a stream whose body has run out.
        var ending_empty = end_stream and wanted == 0
        if room == 0 and not ending_empty:
            return 0

        var last = end_stream and room == wanted
        self.send_window.consume(room)
        self.streams[index].send_data(room, last)

        var flags = FLAG_END_STREAM if last else UInt8(0)
        write_frame_header(
            FrameHeader(room, FrameType.DATA, flags, stream_id), self.outbound
        )
        self.outbound.extend(data[:room])

        if last:
            self._reap(stream_id)
        return room

    def acknowledge(mut self, stream_id: UInt32, amount: Int) raises:
        """Say that `amount` octets have been consumed, and return the window.

        Not done when the octets arrive, which would be simpler and would defeat
        the point. A receive window is a promise about how much we are prepared
        to hold, so returning it the moment bytes land advertises room we have
        not got back yet and turns the window into a number that only goes round
        in a circle.
        """
        var giving = self.recv_window.restore(amount)
        if giving > 0:
            self._write_window_update(0, giving)

        var index = self._find(stream_id)
        if index < 0:
            # The stream finished while its last bytes were still being read.
            # Returning stream window to a stream that has gone is not an error
            # and there is nothing to return it to; the connection window above
            # is the part that still matters.
            return
        var stream_giving = self.streams[index].recv.restore(amount)
        if stream_giving > 0:
            self._write_window_update(stream_id, stream_giving)

    def send_rst_stream(mut self, stream_id: UInt32, code: ErrorCode):
        """Give up on one stream without touching the rest of the connection."""
        var index = self._find(stream_id)
        if index >= 0:
            self.streams[index].reset()

        write_frame_header(
            FrameHeader(
                RST_STREAM_SIZE, FrameType.RST_STREAM, UInt8(0), stream_id
            ),
            self.outbound,
        )
        write_uint32(code.value, self.outbound)
        self._reap(stream_id)

    def send_goaway(mut self, code: ErrorCode):
        """Tell the peer we are finished and what the last stream we acted on was.
        """
        write_frame_header(
            FrameHeader(GOAWAY_FIXED_SIZE, FrameType.GOAWAY, UInt8(0), 0),
            self.outbound,
        )
        write_uint32(self.ids.highest(), self.outbound)
        write_uint32(code.value, self.outbound)

    def send_ping(mut self, data: SIMD[DType.uint8, 8]):
        write_frame_header(
            FrameHeader(PING_SIZE, FrameType.PING, UInt8(0), 0), self.outbound
        )
        for i in range(PING_SIZE):
            self.outbound.append(data[i])

    def stream_state(self, stream_id: UInt32) -> StreamState:
        """Where one stream has got to, or closed if we no longer hold it."""
        var index = self._find(stream_id)
        if index < 0:
            return StreamState.CLOSED
        return self.streams[index].state

    def _data[
        o: ImmOrigin
    ](mut self, header: FrameHeader, payload: Span[UInt8, o]) raises -> H2Event:
        check_on_stream(header)

        # The connection window is charged with the whole frame, padding and
        # pad length octet included, and before the stream is even looked up.
        # RFC 9113 section 6.9.1 is explicit that flow control is on the frame
        # and not on its contents, and a receiver that charged only what it kept
        # would drift a little further from the sender with every padded frame
        # until one side thought there was window and the other did not.
        self.recv_window.record(header.length)

        var content = strip_padding(header, payload)
        var end_stream = header.has(FLAG_END_STREAM)

        var index = self._find(header.stream_id)
        if index < 0:
            self.ids.check_named(header.stream_id)
            # A known identifier we no longer hold is a stream that finished,
            # and DATA on it crossed with our own end. The connection window is
            # already charged above, which is the part that has to happen; the
            # octets themselves have nowhere to go.
            return H2Event(H2EventKind.NOTHING)

        self.streams[index].recv_data(header.length, end_stream)

        var event = H2Event(H2EventKind.DATA, header.stream_id)
        event.end_stream = end_stream
        event.data.extend(content)
        if end_stream:
            self.resets.record_success()
            self._reap(header.stream_id)
        return event^

    def _headers[
        o: ImmOrigin
    ](mut self, header: FrameHeader, payload: Span[UInt8, o]) raises -> H2Event:
        check_on_stream(header)
        self.ids.check_named(header.stream_id)

        var content = strip_priority(header, strip_padding(header, payload))
        self._block_end_stream = header.has(FLAG_END_STREAM)

        if not self.block.begin(header, content):
            return H2Event(H2EventKind.NOTHING)
        return self._finish_block(header.stream_id)

    def _continuation[
        o: ImmOrigin
    ](mut self, header: FrameHeader, payload: Span[UInt8, o]) raises -> H2Event:
        if not self.block.extend(header, payload):
            return H2Event(H2EventKind.NOTHING)
        return self._finish_block(header.stream_id)

    def _finish_block(mut self, stream_id: UInt32) raises -> H2Event:
        var end_stream = self._block_end_stream
        var block = self.block.take()

        # The block is decoded whatever else is wrong, and that ordering is not
        # optional. HPACK keeps a table that both sides update as they go, so a
        # block skipped here leaves our table one entry behind the peer's and
        # every header after it decodes to something else. Refusing the stream
        # is cheap; refusing the block would poison the connection.
        var fields = self.decoder.decode(block.as_span())

        var index = self._find(stream_id)
        if index < 0:
            return H2Event(H2EventKind.NOTHING)

        self.streams[index].recv_headers(end_stream)

        var event = H2Event(H2EventKind.HEADERS, stream_id)
        event.end_stream = end_stream
        event.fields = fields^
        if end_stream:
            self.resets.record_success()
            self._reap(stream_id)
        return event^

    def _settings[
        o: ImmOrigin
    ](mut self, header: FrameHeader, payload: Span[UInt8, o]) raises -> H2Event:
        check_on_connection(header)
        check_settings_length(header)

        if header.has(FLAG_ACK):
            self.settings_acked = True
            return H2Event(H2EventKind.SETTINGS_ACKED)

        var before = self.peer_settings.initial_window_size
        apply_settings(self.peer_settings, payload)

        # Only stream windows move, and by the difference rather than to the new
        # value. RFC 9113 section 6.9.2. The connection window is untouched by
        # this setting, which is the detail that produces a client that oversends
        # or stalls only against servers that change it mid connection.
        var delta = self.peer_settings.initial_window_size - before
        if delta != 0:
            for i in range(len(self.streams)):
                self.streams[i].send.resize(delta)

        self.encoder.set_table_size(self.peer_settings.header_table_size)

        # The acknowledgement goes out before the caller has seen the event, so
        # a caller that stops reading has still answered. RFC 9113 section 6.5.3
        # requires it promptly and a server that does not get one is entitled to
        # treat the connection as broken.
        write_frame_header(
            FrameHeader(0, FrameType.SETTINGS, FLAG_ACK, 0), self.outbound
        )
        return H2Event(H2EventKind.SETTINGS_CHANGED)

    def _ping[
        o: ImmOrigin
    ](mut self, header: FrameHeader, payload: Span[UInt8, o]) raises -> H2Event:
        check_on_connection(header)
        check_fixed_length(header, PING_SIZE)

        if header.has(FLAG_ACK):
            return H2Event(H2EventKind.PING_ACKED)

        write_frame_header(
            FrameHeader(PING_SIZE, FrameType.PING, FLAG_ACK, 0), self.outbound
        )
        self.outbound.extend(payload)
        return H2Event(H2EventKind.NOTHING)

    def _goaway[
        o: ImmOrigin
    ](mut self, header: FrameHeader, payload: Span[UInt8, o]) raises -> H2Event:
        check_on_connection(header)
        var parsed = parse_goaway(payload)

        var event = H2Event(H2EventKind.GOAWAY)
        event.stream_id = parsed.last_stream_id
        event.error_code = parsed.error_code
        self.goaway = parsed^
        return event^

    def _window_update[
        o: ImmOrigin
    ](mut self, header: FrameHeader, payload: Span[UInt8, o]) raises -> H2Event:
        check_fixed_length(header, WINDOW_UPDATE_SIZE)
        var increment = parse_window_update(header, payload)

        if header.stream_id == 0:
            self.send_window.increase(increment)
            return H2Event(H2EventKind.NOTHING)

        self.ids.check_named(header.stream_id)
        var index = self._find(header.stream_id)
        if index >= 0:
            self.streams[index].send.increase(increment)

        # An update on a stream we no longer hold is discarded. RFC 9113 section
        # 6.9 expects one to arrive shortly after a stream ends, because the peer
        # had it in flight before it knew, and refusing it would make ending a
        # stream a race that the peer loses.
        return H2Event(H2EventKind.NOTHING)

    def _rst_stream[
        o: ImmOrigin
    ](mut self, header: FrameHeader, payload: Span[UInt8, o]) raises -> H2Event:
        check_on_stream(header)
        check_fixed_length(header, RST_STREAM_SIZE)
        self.ids.check_named(header.stream_id)

        var event = H2Event(H2EventKind.STREAM_RESET, header.stream_id)
        event.error_code = ErrorCode(read_uint32(payload, 0))
        event.end_stream = True

        var index = self._find(header.stream_id)
        if index >= 0:
            self.streams[index].reset()
        self._reap(header.stream_id)

        # Counted whether or not the stream was one we still held, since a
        # server resetting streams it has already reset is the same loop by
        # another name.
        self.resets.record_reset()
        return event^

    def _priority(mut self, header: FrameHeader) raises -> H2Event:
        check_on_stream(header)
        check_fixed_length(header, PRIORITY_SIZE)

        # Parsed for its length and then dropped. RFC 9113 section 5.3.1
        # deprecates the scheme, so acting on the values would be implementing
        # something the specification has withdrawn, but the frame still has to
        # be accepted because peers still send it.
        return H2Event(H2EventKind.NOTHING)

    def _write_settings(mut self):
        var payload = Bytes()
        write_settings(self.settings, payload)
        write_frame_header(
            FrameHeader(len(payload), FrameType.SETTINGS, UInt8(0), 0),
            self.outbound,
        )
        self.outbound.extend(payload.as_span())

    def _write_window_update(mut self, stream_id: UInt32, increment: Int):
        write_frame_header(
            FrameHeader(
                WINDOW_UPDATE_SIZE,
                FrameType.WINDOW_UPDATE,
                UInt8(0),
                stream_id,
            ),
            self.outbound,
        )
        write_uint32(UInt32(increment), self.outbound)

    def _write_block(
        mut self, stream_id: UInt32, block: Bytes, end_stream: Bool
    ):
        """Frame one encoded header block, splitting it if it does not fit.

        The peer's `SETTINGS_MAX_FRAME_SIZE` is the limit, not ours. Ours bounds
        what it may send us and has nothing to say about what it will accept.
        """
        var limit = self.peer_settings.max_frame_size
        var total = len(block)
        var first = min(total, limit)

        var flags = FLAG_END_STREAM if end_stream else UInt8(0)
        if first == total:
            flags |= FLAG_END_HEADERS
        write_frame_header(
            FrameHeader(first, FrameType.HEADERS, flags, stream_id),
            self.outbound,
        )
        self.outbound.extend(block.as_span()[:first])

        var at = first
        while at < total:
            var upto = min(at + limit, total)
            var more = FLAG_END_HEADERS if upto == total else UInt8(0)
            write_frame_header(
                FrameHeader(upto - at, FrameType.CONTINUATION, more, stream_id),
                self.outbound,
            )
            self.outbound.extend(block.as_span()[at:upto])
            at = upto

    def _find(self, stream_id: UInt32) -> Int:
        for i in range(len(self.streams)):
            if self.streams[i].id == stream_id:
                return i
        return -1

    def _reap(mut self, stream_id: UInt32):
        """Drop a stream once it is closed at both ends.

        Called wherever a stream might have finished rather than swept
        periodically, because a sweep is a decision about how often, and there
        is no answer to that which is right for both a connection carrying one
        request and one carrying thousands.
        """
        var index = self._find(stream_id)
        if index < 0:
            return
        if self.streams[index].state != StreamState.CLOSED:
            return
        _ = self.streams.pop(index)
