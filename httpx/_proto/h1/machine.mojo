"""One HTTP/1.1 exchange, with the socket taken out of it.

This is the whole of HTTP/1.1 as this library implements it, minus the reading
and the writing. It holds the state of one exchange, decides what the framing
rules mean, and turns bytes into a response, and it never touches a descriptor.
What it does instead is stop and say it needs more bytes, which is what makes it
usable by a driver that blocks for them and by a driver that gives its worker
back for them.

The read side is three steps, and every one of them answers "not yet" rather
than waiting. `poll_head` gives back a head once all of it has arrived,
`poll_chunk` gives back what the buffer can already give of a body, and
`poll_continue` says whether the server answered an expectation. A caller that
gets nothing reads more, hands it over with `fill_from`, and asks again. That is
the entire contract, and it is why there are two drivers over this file rather
than two implementations of HTTP/1.1.

The write side is smaller, because deciding what bytes to send never has to
wait. `start_send` works out the framing headers and hands back the serialized
head, and `body_sent` closes the send phase. Producing the body bytes is in
`httpx._proto.h1.writer` and was already sans I/O before any of this.

The state machine exists to make the illegal orderings impossible rather than
merely unusual. Reading a response before sending a request, or sending a second
request before the first response has been read, are both things a caller can
ask for and neither is something HTTP/1.1 can do. Refusing loudly at the point
of the mistake is better than a hang or, worse, a response matched to the wrong
request.

Nothing here closes anything, because there is nothing here to close. A step
that ends the connection puts the state in `CLOSED` and leaves the descriptor to
the driver, which is the only part that has one.
"""

from httpx._exceptions import ErrorKind, new_error
from httpx._io.buffer import ByteBuffer
from httpx._models.headers import Headers
from httpx._models.request import Request
from httpx._proto.h1.body import BodyReader
from httpx._proto.h1.framing import framing_for
from httpx._proto.h1.head import ResponseHead, parse_head
from httpx._proto.h1.writer import (
    TargetForm,
    framing_headers,
    serialize_head,
)

comptime CONTINUE_WAIT_SECONDS = 1.0
"""How long to wait for a `100 Continue` before sending the body anyway.

RFC 9110 section 10.1.1 says a client should not wait forever, because a server
that does not implement the expectation will simply never answer it. A second is
long enough for any server that was going to answer and short enough that the
request is not visibly slower when none does.
"""

comptime MAX_INFORMATIONAL = 8
"""How many 1xx responses to skip past before giving up.

There is no legitimate reason for a server to send a long run of them, and
without a bound a server that sends nothing else keeps a client reading forever.
"""


struct H1State(Equatable, ImplicitlyCopyable, Movable):
    """Where in one exchange the connection has got to."""

    var value: Int

    comptime IDLE = Self(0)
    """Nothing sent. The only state a new request may start from."""

    comptime SEND_BODY = Self(1)
    comptime WAIT_RESPONSE = Self(2)
    comptime RECV_BODY = Self(3)

    comptime DONE = Self(4)
    """One exchange finished cleanly. Reusable if nothing else objected."""

    comptime CLOSED = Self(5)
    """Not usable again, whether or not the descriptor is still open."""

    def __init__(out self, value: Int):
        self.value = value

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value


def local_error(message: String) -> Error:
    return new_error(ErrorKind.LOCAL_PROTOCOL_ERROR, message)


def remote_error(message: String) -> Error:
    return new_error(ErrorKind.REMOTE_PROTOCOL_ERROR, message)


struct H1Machine(Movable):
    """The state of one exchange, and the rules that move it along."""

    var buf: ByteBuffer
    var state: H1State

    var upgraded: Bool
    """Set when the server answered `101` and the connection stopped being HTTP.

    The raw stream is then the caller's to do what it likes with, which for a
    websocket is the point. Exposed as a flag rather than through the response,
    because the response has nowhere to put a socket until the extensions
    mapping lands with the rest of the model work.
    """

    var _method: String
    """What was asked, kept because framing the answer needs it."""

    var _pending: Optional[ResponseHead]
    """A head read early, waiting for the reader that should have got it.

    Only ever filled by the `Expect: 100-continue` path, where a final response
    can arrive while the body is still being held back. The head is already off
    the wire by then and there is nowhere to put it back, so it is parked here.
    """

    var _reader: Optional[BodyReader]
    """The body reader for the response being read, while one is in progress.

    An optional because the body is read a chunk at a time, which means the
    reader has to survive between calls. Nothing means either that no response
    is being read or that the last one finished, and both answer `poll_chunk`
    the same way.
    """

    var _trailers: Headers
    """What the last body carried after it, waiting to be collected."""

    var _informational: Int
    """How many 1xx heads have been skipped while waiting for the real one.

    A field rather than a local because the loop that used to count them has
    been split in two: `poll_head` gives up its turn every time the buffer runs
    short, so the count has to survive between calls or a server sending one 1xx
    per packet would never reach the limit.
    """

    var _keep_alive: Bool
    """Whether this connection survives the response being read.

    Decided from the head, before a byte of body is read, because that is when
    the framing and the `Connection` field are both in hand. Acting on it is
    deferred to the end of the body, which is the only point at which the
    question can be answered by doing something.
    """

    def __init__(out self):
        self.buf = ByteBuffer()
        self.state = H1State.IDLE
        self.upgraded = False
        self._method = String()
        self._pending = None
        self._reader = None
        self._trailers = Headers()
        self._informational = 0
        self._keep_alive = False

    def is_idle(self) -> Bool:
        return self.state == H1State.IDLE

    def is_finished(self) -> Bool:
        """Whether an exchange ended, cleanly or otherwise."""
        return self.state == H1State.DONE or self.state == H1State.IDLE

    def wants_close(self) -> Bool:
        """Whether the driver should now let go of the descriptor.

        The machine has no socket, so ending a connection is something it says
        rather than something it does. Both drivers ask this after any step that
        can finish a body.
        """
        return self.state == H1State.CLOSED

    def closed(mut self):
        """Record that the connection is gone, however it went."""
        self.state = H1State.CLOSED

    def fill_from[o: ImmOrigin](mut self, bytes: Span[UInt8, o]):
        """Hand bytes that came off the wire to the parser.

        Who did the reading is the caller's business. The synchronous driver
        blocks for these bytes and the async one gives its worker back for them,
        and that difference stops here.
        """
        self.buf.extend(bytes)

    def start_send(
        mut self,
        mut request: Request,
        form: TargetForm = TargetForm.ORIGIN,
    ) raises -> List[UInt8]:
        """Get ready to send, and hand back the head to put on the wire.

        Everything that happens before the first byte goes out: the check that
        this connection is free, the framing headers, and serializing the head.

        The request is mutated, because the framing headers this works out are
        added to it. A caller that sends the same request twice, which a redirect
        or a retry does, gets them worked out again from what is now there rather
        than from what was there originally.
        """
        if self.state == H1State.DONE:
            # A connection that finished one exchange cleanly starts the next
            # one from here. Clearing back to `IDLE` rather than adding a second
            # entry state keeps the rest of the machine unaware that reuse
            # exists, and the leftovers of the previous exchange are cleared
            # with it so nothing from it can be read as part of this one.
            self.state = H1State.IDLE
            self._method = String()
            self._pending = None
            self._reader = None
            self._trailers = Headers()
            self._informational = 0
        if self.state != H1State.IDLE:
            raise local_error(
                "a request cannot be sent while this connection is busy"
            )

        var length: Optional[Int] = None
        var streaming = request.has_stream()
        if (
            not streaming
            and "transfer-encoding" not in request.headers
            and len(request.content) > 0
        ):
            length = Optional[Int](len(request.content))
        var extra = framing_headers(
            request.method, request.headers, length, streaming
        )
        for i in range(len(extra)):
            # Copied out before appending. The spans borrow from `extra`, and
            # `multi_items` would give the lowered names, which would put this
            # library's own headers on the wire in a casing nothing else uses.
            var name = String(StringSpan(from_utf8=extra.raw_name(i)))
            var value = String(StringSpan(from_utf8=extra.raw_value(i)))
            request.headers.append(name, value)

        self._method = request.method.copy()
        self.state = H1State.SEND_BODY
        return serialize_head(request, form)

    def expects_continue(self, request: Request) raises -> Bool:
        """Whether the head asked the server before sending the body.

        The whole value of the expectation is not uploading a gigabyte to a
        server that was going to refuse it on the headers alone, so a driver
        that ignored this would make the header a lie.
        """
        return _expects_continue(request.headers)

    def poll_continue(mut self) raises -> Optional[Bool]:
        """Whether to send the body, if the server has said anything yet.

        Nothing means it has not, and the caller decides how long to keep
        waiting. True is a `100 Continue`. False is a final response arriving
        instead, which means the server decided without the body and the body is
        never sent. That head is already off the wire and cannot go back, so it
        is parked for the reader that should have got it.
        """
        var found = parse_head(self.buf)
        if not found:
            return None
        var head = found.take()
        if head.status_code == 100:
            return Optional[Bool](True)
        self._pending = Optional[ResponseHead](head^)
        return Optional[Bool](False)

    def body_held_back(mut self):
        """The server refused on the head, so the body is never sent."""
        self.state = H1State.WAIT_RESPONSE

    def body_sent(mut self):
        """The whole body is on the wire, so the answer is what comes next."""
        self.state = H1State.WAIT_RESPONSE

    def check_can_read(self) raises:
        """Refuse to read a response that was never asked for."""
        if self.state != H1State.WAIT_RESPONSE:
            raise local_error(
                "there is no response to read on this connection yet"
            )

    def poll_head(mut self) raises -> Optional[ResponseHead]:
        """The first head that is not informational, if all of it has arrived.

        Nothing means the buffer is short, not that the server sent nothing, so
        a caller reads more and asks again.

        A `100 Continue` that arrives after the body was already sent is not an
        error, it is a server that answered slowly, and skipping it is what
        RFC 9110 section 15.2 asks a client to do with any 1xx it did not ask
        for.
        """
        if self._pending:
            return self._pending.take()
        while True:
            var found = parse_head(self.buf)
            if not found:
                return None
            var head = found.take()
            if head.status_code >= 200 or head.status_code == 101:
                return Optional[ResponseHead](head^)
            self._informational += 1
            if self._informational > MAX_INFORMATIONAL:
                raise remote_error(
                    "the server sent nothing but informational responses"
                )

    def head_received(mut self, head: ResponseHead) raises:
        """Set the body reading up from the head that just arrived."""
        var framing = framing_for(self._method, head)
        self._trailers = Headers()

        if head.status_code == 101:
            # The connection stops being HTTP here. Nothing after the head
            # belongs to us, so nothing after the head is read.
            self.upgraded = True
            self.state = H1State.CLOSED
            self._reader = None
            self._keep_alive = False
            return

        self.state = H1State.RECV_BODY
        self._keep_alive = framing.is_self_delimiting() and _keeps_alive(
            head.http_version, head.headers
        )
        self._reader = Optional[BodyReader](BodyReader(framing))

    def reading_body(self) -> Bool:
        """Whether there is a body in progress to take another piece of."""
        return self._reader.__bool__()

    def poll_chunk(mut self, mut out: List[UInt8]) raises -> Bool:
        """Take what the buffer can already give of the body.

        True means `out` is the answer, whether that is a piece of the body or
        the empty list that ends it. False means the buffer ran short and the
        caller should read more and ask again.

        Empty never means "nothing has arrived yet", which is why the caller has
        to tell the two apart by the return value rather than by the length. A
        caller that took a pause for an ending would report half a response as a
        whole one.
        """
        if not self._reader.value().read_from(self.buf, out):
            self._end_body()
            return True
        return len(out) > 0

    def at_eof(mut self, mut out: List[UInt8]) raises:
        """Settle the body when the peer closed instead of finishing it.

        A close is the ending for one framing mode and a truncated body for the
        other two, and `at_eof` on the reader is what knows which.
        """
        self._reader.value().at_eof()
        _ = self._reader.value().read_from(self.buf, out)
        self._end_body()

    def abandon(mut self):
        """Give up on the response being read.

        Whatever went wrong, the framing is now unknown, so there is no way to
        tell where this message ends and the next one starts. Both drivers call
        this, the synchronous one from an `except` and the async one from the
        branch where a read came back as a failed outcome, which is the same
        situation reported the two different ways the two sides are allowed to
        report it.
        """
        self._reader = None
        self.state = H1State.CLOSED

    def take_trailers(mut self) -> Headers:
        """The fields the last body carried after it, leaving none behind."""
        var out = Headers()
        swap(out, self._trailers)
        return out^

    def _end_body(mut self):
        """Settle the connection once the body has been read to the end."""
        var reader = self._reader.take()
        self._trailers = reader.take_trailers()
        if self._keep_alive:
            self.state = H1State.DONE
        else:
            self.state = H1State.CLOSED


def _expects_continue(headers: Headers) raises -> Bool:
    var values = headers.get_list("expect", split_commas=True)
    for i in range(len(values)):
        if values[i].lower() == "100-continue":
            return True
    return False


def _keeps_alive(http_version: String, headers: Headers) raises -> Bool:
    """Whether the server said it would keep the connection open.

    HTTP/1.1 keeps it open unless told otherwise and HTTP/1.0 closes it unless
    told otherwise, which is the one place the version in the status line does
    something rather than being a label.

    Asked of the head rather than of the response, because the answer is needed
    before the body has been read and a streaming response does not exist in
    finished form until after it has.
    """
    var tokens = headers.get_list("connection", split_commas=True)
    var said_close = False
    var said_keep_alive = False
    for i in range(len(tokens)):
        var token = tokens[i].lower()
        if token == "close":
            said_close = True
        elif token == "keep-alive":
            said_keep_alive = True
    if said_close:
        return False
    if http_version == "HTTP/1.0":
        return said_keep_alive
    return True
