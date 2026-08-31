"""One HTTP/1.1 exchange over one connection.

Everything below this point is sans I/O: the head parser, the framing rules and
the body reader all work on a buffer and never touch a socket. This file is
where that meets a real connection, and it is deliberately the only place, so
that the parts with the security rules in them can be tested by handing them
bytes rather than by standing up a server.

The state machine exists to make the illegal orderings impossible rather than
merely unusual. Reading a response before sending a request, or sending a second
request before the first response has been read, are both things a caller can
ask for and neither is something HTTP/1.1 can do. Refusing loudly at the point
of the mistake is better than a hang or, worse, a response matched to the wrong
request.

Pipelining is out of scope. It is allowed by the RFC, it wins almost nothing
over a connection pool, and getting it wrong means responses handed to the wrong
caller.

`H1Connection` is written against `TcpStream` rather than against a stream
trait. The trait arrives with the transport layer, which is where TLS gets
layered in, and inventing it here would mean guessing at what that layer needs.
"""

from httpx._exceptions import ErrorKind, new_error
from httpx._io.buffer import ByteBuffer
from httpx._io.deadline import Deadline
from httpx._io.socket import TcpStream
from httpx._models.headers import Headers
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._proto.h1.body import BodyReader
from httpx._proto.h1.framing import BodyMode, Framing, framing_for
from httpx._proto.h1.head import ResponseHead, parse_head
from httpx._proto.h1.writer import (
    TargetForm,
    chunk,
    framing_headers,
    serialize_head,
    terminal_chunk,
)

comptime READ_SIZE = 8192
"""How much to ask the kernel for at a time.

Matches the buffer's default capacity. Larger reads win nothing once the socket
buffer is the limit, and smaller ones cost a syscall per few hundred bytes.
"""

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


def _local(message: String) -> Error:
    return new_error(ErrorKind.LOCAL_PROTOCOL_ERROR, message)


def _remote(message: String) -> Error:
    return new_error(ErrorKind.REMOTE_PROTOCOL_ERROR, message)


struct H1Connection(Movable):
    """A connection that can carry one exchange at a time."""

    var stream: TcpStream
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

    def __init__(out self, var stream: TcpStream):
        self.stream = stream^
        self.buf = ByteBuffer()
        self.state = H1State.IDLE
        self.upgraded = False
        self._method = String()
        self._pending = None

    def is_idle(self) -> Bool:
        return self.state == H1State.IDLE

    def is_reusable(self) raises -> Bool:
        """Whether another request may be sent on this connection.

        A connection is reusable only after an exchange that ended the way it
        said it would. Anything else, including a body that ran until the close,
        leaves no way to know that the next byte starts a new message.
        """
        if self.state != H1State.DONE and self.state != H1State.IDLE:
            return False
        if self.upgraded or not self.stream.is_open():
            return False
        # Data sitting on an idle connection belongs to an exchange that is over,
        # which means the framing was got wrong somewhere and the connection is
        # no longer trustworthy.
        return not self.stream.has_data_waiting()

    def close(mut self):
        self.state = H1State.CLOSED
        self.stream.close()

    def exchange(
        mut self,
        var request: Request,
        write_at: Deadline,
        read_at: Deadline,
        form: TargetForm = TargetForm.ORIGIN,
    ) raises -> Response:
        """Send `request` and read the whole response.

        Two deadlines because writing and reading fail for different reasons and
        deserve different limits: a slow upload is not the same problem as a
        server that never answers.
        """
        self.send_request(request, write_at, form)
        return self.read_response(read_at)

    def send_request(
        mut self,
        var request: Request,
        deadline: Deadline,
        form: TargetForm = TargetForm.ORIGIN,
    ) raises:
        """Write the head and, unless the server is being asked first, the body.
        """
        if self.state != H1State.IDLE:
            raise _local(
                "a request cannot be sent while this connection is busy"
            )

        var length: Optional[Int] = None
        if (
            "transfer-encoding" not in request.headers
            and len(request.content) > 0
        ):
            length = Optional[Int](len(request.content))
        var extra = framing_headers(request.method, request.headers, length)
        for i in range(len(extra)):
            # Copied out before appending. The spans borrow from `extra`, and
            # `multi_items` would give the lowered names, which would put this
            # library's own headers on the wire in a casing nothing else uses.
            var name = String(StringSpan(from_utf8=extra.raw_name(i)))
            var value = String(StringSpan(from_utf8=extra.raw_value(i)))
            request.headers.append(name, value)

        self._method = request.method.copy()
        self.state = H1State.SEND_BODY

        var head = serialize_head(request, form)
        self.stream.write(Span(head), deadline)

        if _expects_continue(request.headers):
            # The head is out and the body is held back on purpose. The whole
            # value of the expectation is not uploading a gigabyte to a server
            # that was going to refuse it on the headers alone.
            if not self._wait_for_continue(deadline):
                self.state = H1State.WAIT_RESPONSE
                return

        self._send_body(request, deadline)

    def read_response(mut self, deadline: Deadline) raises -> Response:
        """Read one response, informational ones skipped, body and all."""
        if self.state != H1State.WAIT_RESPONSE:
            raise _local("there is no response to read on this connection yet")

        var head = self._read_final_head(deadline)
        var framing = framing_for(self._method, head)

        if head.status_code == 101:
            # The connection stops being HTTP here. Nothing after the head
            # belongs to us, so nothing after the head is read.
            self.upgraded = True
            self.state = H1State.CLOSED
            return Response(
                head.status_code,
                head.reason_phrase.copy(),
                head.http_version.copy(),
                head.take_headers(),
            )

        self.state = H1State.RECV_BODY
        var reader = BodyReader(framing)
        var content = List[UInt8]()
        while not reader.is_complete():
            if not reader.read_from(self.buf, content):
                break
            if self._fill(deadline) == 0:
                reader.at_eof()
                # One last pass, because the bytes that arrived alongside the
                # close are still a valid part of the body.
                _ = reader.read_from(self.buf, content)
                break

        var response = Response(
            head.status_code,
            head.reason_phrase.copy(),
            head.http_version.copy(),
            head.take_headers(),
            content^,
            reader.take_trailers(),
        )

        if not framing.is_self_delimiting() or not _keeps_alive(response):
            self.state = H1State.CLOSED
            self.stream.close()
        else:
            self.state = H1State.DONE
        return response^

    def _send_body(mut self, request: Request, deadline: Deadline) raises:
        if "transfer-encoding" in request.headers:
            if len(request.content) > 0:
                self.stream.write(Span(chunk(Span(request.content))), deadline)
            self.stream.write(Span(terminal_chunk(Headers())), deadline)
        elif len(request.content) > 0:
            self.stream.write(Span(request.content), deadline)
        self.state = H1State.WAIT_RESPONSE

    def _wait_for_continue(mut self, deadline: Deadline) raises -> Bool:
        """Whether to go ahead and send the body.

        True for a `100 Continue` and true for the timeout, which is the
        recovery RFC 9110 asks for: a server that ignored the expectation is
        waiting for a body it never acknowledged. False only when a final
        response arrived, and then the body is never sent at all.
        """
        var wait = deadline.earlier_of(Deadline.after(CONTINUE_WAIT_SECONDS))
        while True:
            var found = parse_head(self.buf)
            if found:
                var head = found.take()
                if head.status_code == 100:
                    return True
                # A final response before the body means the server decided
                # without it, so the body is never sent. The head is already off
                # the wire and cannot go back, so it is parked for the reader.
                self._pending = Optional[ResponseHead](head^)
                return False
            try:
                if self._fill(wait) == 0:
                    raise _remote(
                        "the server closed before answering the expectation"
                    )
            except e:
                if wait.expired():
                    return True
                raise e

    def _read_final_head(mut self, deadline: Deadline) raises -> ResponseHead:
        """The first head that is not informational.

        A `100 Continue` that arrives after the body was already sent is not an
        error, it is a server that answered slowly, and skipping it is what
        RFC 9110 section 15.2 asks a client to do with any 1xx it did not ask
        for.
        """
        if self._pending:
            return self._pending.take()

        var seen = 0
        while True:
            var found = parse_head(self.buf)
            if found:
                var head = found.take()
                if head.status_code >= 200 or head.status_code == 101:
                    return head^
                seen += 1
                if seen > MAX_INFORMATIONAL:
                    raise _remote(
                        "the server sent nothing but informational responses"
                    )
                continue
            if self._fill(deadline) == 0:
                raise _remote(
                    "the server closed before sending a complete response"
                )

    def _fill(mut self, deadline: Deadline) raises -> Int:
        """One read into the buffer. Zero means the peer closed."""
        var scratch = List[UInt8](length=READ_SIZE, fill=0)
        var n = self.stream.read(Span(scratch), deadline)
        if n > 0:
            self.buf.extend(Span(scratch)[:n])
        return n


def _expects_continue(headers: Headers) raises -> Bool:
    var values = headers.get_list("expect", split_commas=True)
    for i in range(len(values)):
        if values[i].lower() == "100-continue":
            return True
    return False


def _keeps_alive(response: Response) raises -> Bool:
    """Whether the server said it would keep the connection open.

    HTTP/1.1 keeps it open unless told otherwise and HTTP/1.0 closes it unless
    told otherwise, which is the one place the version in the status line does
    something rather than being a label.
    """
    var tokens = response.headers.get_list("connection", split_commas=True)
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
    if response.http_version == "HTTP/1.0":
        return said_keep_alive
    return True
