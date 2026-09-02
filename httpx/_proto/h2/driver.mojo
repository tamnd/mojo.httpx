"""The half of HTTP/2 that touches a socket.

`H2Connection` decides what the protocol means and this reads and writes for it.
Splitting them was the point of the previous piece, and the split holds here:
everything below is loops, deadlines and buffers, and the only protocol decision
in the file is which stream a frame belongs to.

The surface is the same shape as `H1Connection` deliberately, because the pool
above has to be able to hold either without asking which it has for anything but
the parts that genuinely differ. What genuinely differs is small: a request gets
a stream identifier rather than a turn, and a connection stays reusable while a
response is still being read.

One request at a time, for now. The state machine underneath multiplexes and the
identifiers are already per stream, so nothing here would have to be redesigned
to run several at once, but a synchronous client has no way to be waiting on two
responses, and pretending otherwise would be building a queue that never has two
things in it.

The zero window stall lives here. A peer that advertises a window and never opens
it stops a body forever, and there is nothing in the protocol that says how long
to put up with that, so it is the write deadline that decides, the same as any
other way a peer can go quiet.
"""

from httpx._bytes import Bytes
from httpx._exceptions import ErrorKind, new_error
from httpx._io.buffer import ByteBuffer
from httpx._io.deadline import Deadline
from httpx._models.headers import Headers
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._proto.h1.head import ResponseHead
from httpx._proto.h1.writer import TargetForm, request_target
from httpx._proto.h2.connection import H2Connection, H2Event, H2EventKind
from httpx._proto.h2.frames import (
    FRAME_HEADER_SIZE,
    ErrorCode,
    FrameHeader,
    check_frame_length,
    parse_frame_header,
)
from httpx._proto.h2.table import HeaderField
from httpx._proto.h2.validate import (
    check_field,
    check_field_name,
    check_field_value,
    check_not_connection_specific,
)
from httpx._stream.stream import Stream

comptime READ_SIZE = 16384
"""How much to ask the socket for at once.

The default `SETTINGS_MAX_FRAME_SIZE`, so a full sized frame comes back in one
read rather than two.
"""

comptime HOP_BY_HOP: InlineArray[StaticString, 8] = [
    "connection",
    "keep-alive",
    "proxy-connection",
    "transfer-encoding",
    "upgrade",
    "proxy-authenticate",
    "te",
    "trailer",
]
"""Headers RFC 9113 section 8.2.2 refuses to carry.

They describe a single hop of an HTTP/1.1 connection, and HTTP/2 does all of
what they were for in the framing layer instead. A server that receives one is
required to treat the message as malformed, so sending one on is a request that
fails for a reason the caller cannot see in their own code.

Wider than the five names section 8.2.2 forbids, because this is the sending
side. Refusing to carry `trailer` and `proxy-authenticate` costs a caller
nothing, while refusing a response over either would be refusing a message the
specification allows. `httpx/_proto/h2/validate.mojo` has the receiving list.
"""

comptime MAX_INFORMATIONAL = 8
"""How many 1xx responses to skip before deciding the server is not answering.

The same number and the same reason as the HTTP/1.1 side. There is no legitimate
run of them this long, and without a bound a server that sends nothing else keeps
a client reading until its deadline.
"""


def _remote(message: String) -> Error:
    return new_error(ErrorKind.REMOTE_PROTOCOL_ERROR, message)


def _local(message: String) -> Error:
    return new_error(ErrorKind.LOCAL_PROTOCOL_ERROR, message)


struct H2Driver(Movable):
    """One HTTP/2 connection on a socket."""

    var stream: Stream
    var conn: H2Connection
    var buf: ByteBuffer

    var _started: Bool
    """Whether the preface has gone out. Done on the first request rather than
    in the constructor, because writing needs a deadline and a constructor has
    nowhere to get one from."""

    var _stream_id: UInt32
    """The stream the current exchange is on. Zero between exchanges."""

    var _head_seen: Bool
    var _ended: Bool
    var _trailers: Headers

    def __init__(out self, var stream: Stream):
        self.stream = stream^
        self.conn = H2Connection()
        self.buf = ByteBuffer()
        self._started = False
        self._stream_id = 0
        self._head_seen = False
        self._ended = False
        self._trailers = Headers()

    def is_idle(self) -> Bool:
        return self._stream_id == 0

    def is_reusable(self) raises -> Bool:
        """Whether another request may go on this connection.

        Unlike HTTP/1.1 this stays true while a response is still being read,
        because another stream could carry another request alongside it. What
        makes it false is the connection itself ending: a `GOAWAY`, a socket
        that has gone, or identifiers running out.
        """
        if not self.stream.is_open():
            return False
        if not self.conn.is_open():
            return False
        return not self.stream.is_closed_by_peer()

    def close(mut self):
        self.stream.close()

    def take_trailers(mut self) -> Headers:
        var trailers = self._trailers^
        self._trailers = Headers()
        return trailers^

    def exchange(
        mut self,
        mut request: Request,
        write_deadline: Deadline,
        read_deadline: Deadline,
        form: TargetForm = TargetForm.ORIGIN,
    ) raises -> Response:
        """One whole request and response, body and all."""
        self.send_request(request, write_deadline, form)
        var head = self.start_response(read_deadline)

        var content = List[UInt8]()
        while True:
            var chunk = self.read_chunk(read_deadline)
            if len(chunk) == 0:
                break
            content.extend(chunk^)

        return Response(
            head.status_code,
            head.reason_phrase.copy(),
            head.http_version.copy(),
            head.take_headers(),
            content^,
            self.take_trailers(),
        )

    def send_request(
        mut self,
        mut request: Request,
        deadline: Deadline,
        form: TargetForm = TargetForm.ORIGIN,
    ) raises:
        """Open a stream and put the request on it."""
        if self._stream_id != 0:
            raise _local(
                "a request cannot be sent while this connection is busy"
            )

        self._start(deadline)
        self._head_seen = False
        self._ended = False
        self._trailers = Headers()

        var body_follows = request.has_stream() or len(request.content) > 0
        var fields = _request_fields(request, form)
        self._stream_id = self.conn.send_headers(fields^, not body_follows)
        self._flush(deadline)

        if not body_follows:
            return

        if request.has_stream():
            var body = request.take_stream()
            while True:
                var chunk = body.read_chunk()
                if len(chunk) == 0:
                    break
                self._write_body(Span(chunk), deadline)
            self._end_body(deadline)
        else:
            self._write_body(Span(request.content), deadline)
            self._end_body(deadline)

    def start_response(mut self, deadline: Deadline) raises -> ResponseHead:
        """Read until the response head has arrived.

        Informational responses are read and dropped. RFC 9110 section 15.2 asks
        a client to skip any 1xx it did not ask for, and in HTTP/2 they arrive as
        an ordinary header block on the same stream, so the only thing marking
        one as interim is its status code.
        """
        if self._stream_id == 0:
            raise _local("no request has been sent on this connection")

        var interim = 0
        while True:
            var event = self._next_event(deadline)
            if event.kind == H2EventKind.HEADERS:
                var head = self._head_of(event.fields, deadline)
                if head.status_code >= 200:
                    self._head_seen = True
                    if event.end_stream:
                        self._ended = True
                    return head^

                # An interim response that also ends the stream is a server
                # promising more and then stopping, which leaves the caller
                # with no response at all rather than with a 1xx.
                if event.end_stream:
                    raise _remote(
                        String(
                            "the server ended the stream on a ",
                            head.status_code,
                            ", which is not a response",
                        )
                    )
                interim += 1
                if interim > MAX_INFORMATIONAL:
                    raise _remote(
                        "the server sent nothing but informational responses"
                    )
                continue

            if event.kind == H2EventKind.DATA:
                raise _remote(
                    "the server sent body bytes before any response headers"
                )

    def read_chunk(mut self, deadline: Deadline) raises -> List[UInt8]:
        """The next piece of the response body. Empty means the end.

        The connection window is returned as each piece is handed over rather
        than as it arrives, which is what makes the window mean anything: it is
        a promise about how much we are prepared to hold, and returning it
        before the caller has taken the bytes promises room we have not got.
        """
        if self._stream_id == 0:
            return List[UInt8]()
        if self._ended:
            self._finish()
            return List[UInt8]()

        while True:
            var event = self._next_event(deadline)
            if event.kind == H2EventKind.DATA:
                var amount = len(event.data)
                if event.end_stream:
                    self._ended = True
                if amount == 0:
                    if self._ended:
                        self._finish()
                        return List[UInt8]()
                    continue
                self.conn.acknowledge(self._stream_id, amount)
                self._flush(deadline)
                return event.data.take_list()

            if event.kind == H2EventKind.HEADERS:
                # A second header block on a stream that already had one is
                # trailers. RFC 9113 section 8.1 puts them after the body, so
                # this is the end of it whatever the flags happen to say.
                var trailers: Headers
                try:
                    trailers = _trailer_headers(event.fields)
                except e:
                    self._reset(ErrorCode.PROTOCOL_ERROR, deadline)
                    raise e
                self._trailers = trailers^
                self._ended = True
                self._finish()
                return List[UInt8]()

    def _head_of(
        mut self, fields: List[HeaderField], deadline: Deadline
    ) raises -> ResponseHead:
        """One decoded block as a response head, or a reset stream.

        The reset is the point of the wrapper. RFC 9113 section 8.1.1 makes a
        malformed message a stream error rather than a connection error, and
        that is not a technicality: the block was decoded before it was judged,
        so both HPACK tables are still in step and nothing on any other stream
        is in doubt. Dropping the socket would be throwing away work that had
        nothing to do with the bad message.
        """
        try:
            return _response_head(fields)
        except e:
            self._reset(ErrorCode.PROTOCOL_ERROR, deadline)
            raise e

    def _reset(mut self, code: ErrorCode, deadline: Deadline):
        """Abandon the current stream and keep the connection.

        Best effort, like `_fail`, and for the same reason: this runs on a path
        that is already reporting a failure, and a socket that will not take a
        `RST_STREAM` is not the thing worth telling the caller about.
        """
        try:
            self.conn.send_rst_stream(self._stream_id, code)
            self._flush(deadline)
        except:
            pass
        self._finish()

    def _start(mut self, deadline: Deadline) raises:
        if self._started:
            return
        self.conn.start()
        self._flush(deadline)
        self._started = True

    def _flush(mut self, deadline: Deadline) raises:
        var pending = self.conn.take_outbound()
        if len(pending) == 0:
            return
        self.stream.write(pending.as_span(), deadline.renewed())

    def _write_body[
        o: ImmOrigin
    ](mut self, data: Span[UInt8, o], deadline: Deadline) raises:
        """Send all of `data`, waiting for window when there is none.

        The wait is the zero window stall bound. A peer that never opens the
        window would hold this here forever, so what breaks the loop is the
        write deadline, the same thing that breaks any other way a peer can go
        quiet. There is no separate timer for it, because a stall on a window is
        not different in kind from a stall on a socket.
        """
        var at = 0
        while at < len(data):
            var sent = self.conn.send_data(
                self._stream_id, data[at:], end_stream=False
            )
            if sent == 0:
                deadline.check(String("send the request body"))
                # Nothing fits, so the only thing that can change that is a
                # WINDOW_UPDATE, which means reading. One frame and not a wait
                # for something worth returning: a window update is worth
                # nothing to a caller and everything to this loop, so waiting
                # for an interesting frame would be waiting for the wrong thing.
                _ = self._pump(deadline)
                continue
            self._flush(deadline)
            at += sent

    def _end_body(mut self, deadline: Deadline) raises:
        var empty = Bytes()
        _ = self.conn.send_data(
            self._stream_id, empty.as_span(), end_stream=True
        )
        self._flush(deadline)

    def _next_event(mut self, deadline: Deadline) raises -> H2Event:
        """Read until something the caller's own stream cares about arrives.

        Frames for other streams and for the connection are handled and skipped
        rather than returned, so a caller waiting on a response never has to
        know that a `PING` went past.
        """
        while True:
            var event = self._pump(deadline)
            if event.stream_id != self._stream_id:
                continue
            if (
                event.kind != H2EventKind.HEADERS
                and event.kind != H2EventKind.DATA
            ):
                continue
            return event^

    def _pump(mut self, deadline: Deadline) raises -> H2Event:
        """Exactly one frame, read, interpreted and answered.

        Separate from `_next_event` because the two waits are different. A
        caller waiting on a response wants the next frame that means something
        to it, and the body writer waiting on window wants the next frame at
        all, since the one it is hoping for is a `WINDOW_UPDATE` that comes back
        from here as nothing.
        """
        var header = self._read_frame_header(deadline)
        var payload = self._read_payload(header, deadline)

        var event: H2Event
        try:
            event = self.conn.receive_frame(header, Span(payload))
        except e:
            # A connection error is not recoverable and the peer is owed an
            # explanation before the socket goes, since without one it cannot
            # tell a protocol error from a client that crashed.
            self._fail(ErrorCode.PROTOCOL_ERROR, deadline)
            raise e

        # Whatever the frame was, it may have produced something to send: an
        # acknowledgement, a ping answer, a window update. Sending it here
        # rather than at each call site is what keeps the connection answering
        # while a caller is only interested in one stream.
        self._flush(deadline)

        if event.kind == H2EventKind.GOAWAY:
            if event.stream_id < self._stream_id:
                raise _remote(
                    String(
                        "the server is going away and will not answer stream ",
                        self._stream_id,
                    )
                )
            return H2Event(H2EventKind.NOTHING)

        if event.kind == H2EventKind.STREAM_RESET:
            if event.stream_id == self._stream_id:
                self._stream_id = 0
                raise _remote(
                    String(
                        "the server reset the stream with ",
                        event.error_code.name(),
                    )
                )
            return H2Event(H2EventKind.NOTHING)

        return event^

    def _read_frame_header(mut self, deadline: Deadline) raises -> FrameHeader:
        while len(self.buf) < FRAME_HEADER_SIZE:
            self._fill(deadline)
        return parse_frame_header(self.buf.unread(), 0)

    def _read_payload(
        mut self, header: FrameHeader, deadline: Deadline
    ) raises -> List[UInt8]:
        # The length is checked against what we advertised before the payload is
        # waited for. Reading it first and objecting afterwards would be doing
        # exactly what a peer ignoring the setting was asking for.
        check_frame_length(header, self.conn.settings.max_frame_size)

        var whole = FRAME_HEADER_SIZE + header.length
        while len(self.buf) < whole:
            self._fill(deadline)
        self.buf.consume(FRAME_HEADER_SIZE)
        return self.buf.take(header.length)

    def _fill(mut self, deadline: Deadline) raises -> None:
        var chunk = List[UInt8](length=READ_SIZE, fill=0)
        var read = self.stream.read(Span(chunk), deadline.renewed())
        if read == 0:
            raise _remote(
                "the server closed the connection in the middle of a frame"
            )
        self.buf.extend(Span(chunk)[:read])

    def _finish(mut self):
        self._stream_id = 0
        self._head_seen = False
        self._ended = False

    def _fail(mut self, code: ErrorCode, deadline: Deadline):
        """Tell the peer why, on a best effort, and stop.

        Best effort because this runs on a path that is already failing. A
        socket that will not take a `GOAWAY` is a socket that was about to be
        closed anyway, so the failure to send one is not worth reporting over
        the failure that got us here.

        The caller's deadline and not a fresh one. There is no separate budget
        for apologising to a peer, and an expired deadline here is the right
        answer rather than a problem: a request that has already run out of time
        should not spend more of it explaining itself.
        """
        try:
            self.conn.send_goaway(code)
            var pending = self.conn.take_outbound()
            _ = self.stream.write(pending.as_span(), deadline.renewed())
        except:
            pass
        self.stream.close()


def _request_fields(
    request: Request, form: TargetForm
) raises -> List[HeaderField]:
    """The request as HPACK fields, pseudo-headers first.

    RFC 9113 section 8.3 requires the pseudo-headers to come before any ordinary
    one, and every name to be lower case. The lowering is not cosmetic: an upper
    case letter in a field name makes the whole message malformed, so a header
    the caller wrote as `Content-Type` has to go out lowered or the request
    fails at the server for a reason nothing in the caller's code explains.
    """
    var fields = List[HeaderField]()
    fields.append(HeaderField(String(":method"), request.method.copy()))
    fields.append(HeaderField(String(":scheme"), request.url.scheme()))
    fields.append(HeaderField(String(":authority"), request.url.netloc()))
    fields.append(
        HeaderField(String(":path"), request_target(request.url, form))
    )

    var items = request.headers.multi_items()
    for i in range(len(items)):
        var name = items[i][0].lower()
        if _is_hop_by_hop(name):
            continue
        # Host is what :authority is, and sending both invites the two to
        # disagree, which is a request smuggling primitive rather than a
        # redundancy.
        if name == "host":
            continue
        fields.append(HeaderField(name^, items[i][1].copy()))
    return fields^


def _is_hop_by_hop(name: String) -> Bool:
    var known = materialize[HOP_BY_HOP]()
    for i in range(len(known)):
        if name == known[i]:
            return True
    return False


def _response_head(fields: List[HeaderField]) raises -> ResponseHead:
    """Turn a decoded response block into the head the rest of the library uses.

    There is no reason phrase in HTTP/2. It was dropped from the protocol, so
    what goes here is empty rather than a phrase invented from the status code,
    which would be putting words in a server's mouth.
    """
    var status = 0
    var seen_status = False
    var headers = Headers()

    for i in range(len(fields)):
        var name = fields[i].name
        # Before the field is classified, because `:Status` is not a spelling of
        # `:status` that a receiver is allowed to accept, and a name that breaks
        # the octet rules should be reported as that rather than as an unknown
        # pseudo-header.
        check_field_name(name)

        if name.startswith(":"):
            if name != ":status":
                raise _remote(
                    String(
                        "the server sent an unknown pseudo-header ",
                        name,
                        " in a response",
                    )
                )
            if seen_status:
                raise _remote("the server sent two :status pseudo-headers")
            status = _status_code(fields[i].value)
            seen_status = True
            continue

        if seen_status:
            # The name is already done, above. The rest of RFC 9113 section 8.2
            # only applies to ordinary fields: a pseudo-header has no value rules
            # beyond the ones its own name implies, and none of them is `te`.
            check_field_value(name, fields[i].value)
            check_not_connection_specific(name, fields[i].value)
            headers.append(name, fields[i].value)
            continue

        # RFC 9113 section 8.3. A pseudo-header after an ordinary one is
        # malformed, and the reason it matters is that an intermediary joining
        # the two halves back into HTTP/1.1 would produce a different message
        # from the one a receiver that ignored the order saw.
        raise _remote(
            String(
                "the server sent the header ",
                name,
                " before the :status pseudo-header",
            )
        )

    if not seen_status:
        raise _remote("the server sent a response with no :status")
    return ResponseHead(status, String(), String("HTTP/2"), headers^)


def _trailer_headers(fields: List[HeaderField]) raises -> Headers:
    """Trailers, which are ordinary fields and nothing else.

    No pseudo-headers, because those describe a message and the message is
    already over by the time trailers arrive. Everything else that applies to a
    response field applies here too, which is why a set of trailers cannot smuggle
    in the `transfer-encoding` the head was not allowed to carry.
    """
    var headers = Headers()
    for i in range(len(fields)):
        if fields[i].name.startswith(":"):
            raise _remote(
                String(
                    "the server sent the pseudo-header ",
                    fields[i].name,
                    " in a set of trailers",
                )
            )
        check_field(fields[i].name, fields[i].value)
        headers.append(fields[i].name, fields[i].value)
    return headers^


def _status_code(value: String) raises -> Int:
    if value.byte_length() != 3:
        raise _remote(
            String(
                "the server sent a :status of ",
                value,
                ", which is not three digits",
            )
        )
    var bytes = value.as_bytes()
    var code = 0
    for i in range(3):
        var digit = bytes[i]
        if digit < 0x30 or digit > 0x39:
            raise _remote(
                String(
                    "the server sent a :status of ",
                    value,
                    ", which is not three digits",
                )
            )
        code = code * 10 + Int(digit - 0x30)
    return code
