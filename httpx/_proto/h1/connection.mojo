"""One HTTP/1.1 exchange over one real, blocking connection.

Everything about HTTP/1.1 itself is in `httpx._proto.h1.machine`, which never
touches a descriptor. This file is the socket half: it reads when the machine
says it is short of bytes, writes what the machine hands it, and closes the
descriptor when the machine says the connection is over. That split is what lets
`httpx._proto.h1.aio` be a second driver rather than a second implementation of
HTTP/1.1, and it is why the smuggling defences and the framing rules have one
copy between the two clients.

The loops here are all the same three lines. Ask the machine, and if it says it
needs more bytes, read some and ask again. The async driver's loops are the same
three lines with the read replaced, and nothing else about the two differs.

`H1Connection` is written against `Stream`, which is either a plain socket or a
TLS session over one. Nothing in this file branches on which, and that is the
whole reason the type exists: `http://` and `https://` differ in how the bytes
are carried and in nothing this module cares about.
"""

from httpx._io.deadline import Deadline
from httpx._models.headers import Headers
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._models.stream import ByteStream
from httpx._proto.h1.head import ResponseHead
from httpx._proto.h1.machine import (
    CONTINUE_WAIT_SECONDS,
    H1Machine,
    H1State,
    remote_error,
)
from httpx._proto.h1.writer import TargetForm, chunk, terminal_chunk
from httpx._stream.stream import Stream

comptime READ_SIZE = 8192
"""How much to ask the kernel for at a time.

Matches the buffer's default capacity. Larger reads win nothing once the socket
buffer is the limit, and smaller ones cost a syscall per few hundred bytes.
"""


struct H1Connection(Movable):
    """A connection that can carry one exchange at a time."""

    var stream: Stream
    var machine: H1Machine

    def __init__(out self, var stream: Stream):
        self.stream = stream^
        self.machine = H1Machine()

    def is_idle(self) -> Bool:
        return self.machine.is_idle()

    def is_reusable(self) raises -> Bool:
        """Whether another request may be sent on this connection.

        A connection is reusable only after an exchange that ended the way it
        said it would. Anything else, including a body that ran until the close,
        leaves no way to know that the next byte starts a new message.
        """
        if not self.machine.is_finished():
            return False
        if self.machine.upgraded or not self.stream.is_open():
            return False
        # Data sitting on an idle connection belongs to an exchange that is over,
        # which means the framing was got wrong somewhere and the connection is
        # no longer trustworthy.
        return not self.stream.has_data_waiting()

    def close(mut self):
        self.machine.closed()
        self.stream.close()

    def exchange(
        mut self,
        mut request: Request,
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
        mut request: Request,
        deadline: Deadline,
        form: TargetForm = TargetForm.ORIGIN,
    ) raises:
        """Write the head and, unless the server is being asked first, the body.

        The request is borrowed rather than consumed, so that the caller still
        has it when this returns. A redirect, an auth challenge and a retry all
        need the request that was just sent, and the only thing sending takes
        from it for good is a streaming body, which it takes explicitly.
        """
        var head = self.machine.start_send(request, form)
        self.stream.write(Span(head), deadline.renewed())

        if self.machine.expects_continue(request):
            # The head is out and the body is held back on purpose.
            if not self._wait_for_continue(deadline):
                self.machine.body_held_back()
                return

        self._send_body(request, deadline)

    def read_response(mut self, deadline: Deadline) raises -> Response:
        """Read one response, informational ones skipped, body and all.

        The eager path, which is what a caller who is not streaming wants. It is
        `start_response` followed by `read_chunk` until the body runs out, so
        there is one implementation of the framing rules rather than two.
        """
        var head = self.start_response(deadline)
        var content = List[UInt8]()
        while True:
            var chunk = self.read_chunk(deadline)
            if len(chunk) == 0:
                break
            content.extend(Span(chunk))
        return Response(
            head.status_code,
            head.reason_phrase.copy(),
            head.http_version.copy(),
            head.take_headers(),
            content^,
            self.take_trailers(),
        )

    def start_response(mut self, deadline: Deadline) raises -> ResponseHead:
        """Read the head and leave the body on the wire.

        What the streaming path is built on. The connection is left in
        `RECV_BODY` with a reader set up, and every call to `read_chunk` after
        this takes another piece of the body until there is none left.
        """
        self.machine.check_can_read()
        var head = self._read_final_head(deadline)
        self.machine.head_received(head)
        if self.machine.wants_close():
            self.stream.close()
        return head^

    def read_chunk(mut self, deadline: Deadline) raises -> List[UInt8]:
        """The next piece of the body. Empty means the body is over.

        Empty never means "nothing has arrived yet". A read that has nothing to
        return waits for the socket rather than handing back nothing, because a
        caller that took a pause for an ending would report half a response as
        a whole one.
        """
        var out = List[UInt8]()
        if not self.machine.reading_body():
            return out^
        try:
            while True:
                if self.machine.poll_chunk(out):
                    break
                if self._fill(deadline) == 0:
                    self.machine.at_eof(out)
                    break
        except e:
            self.machine.abandon()
            self.stream.close()
            raise e
        if self.machine.wants_close():
            self.stream.close()
        return out^

    def take_trailers(mut self) -> Headers:
        """The fields the last body carried after it, leaving none behind."""
        return self.machine.take_trailers()

    def _send_body(mut self, mut request: Request, deadline: Deadline) raises:
        # Each write starts the write budget again, because the timeout is on
        # one write and not on the upload. A body large enough to need several
        # writes is not a slow server, and treating it as one would mean the
        # write timeout doubled as a limit on how much can be sent.
        var chunked = "transfer-encoding" in request.headers
        if request.has_stream():
            self._pump(request.take_stream(), chunked, deadline)
        elif chunked:
            if len(request.content) > 0:
                self.stream.write(
                    Span(chunk(Span(request.content))), deadline.renewed()
                )
            self.stream.write(
                Span(terminal_chunk(Headers())), deadline.renewed()
            )
        elif len(request.content) > 0:
            self.stream.write(Span(request.content), deadline.renewed())
        self.machine.body_sent()

    def _pump(
        mut self, var body: ByteStream, chunked: Bool, deadline: Deadline
    ) raises:
        """Write a streaming body a piece at a time, as the pieces arrive.

        A source that raises halfway through leaves the connection closed rather
        than left in `SEND_BODY`, because the server has already been told how
        much to expect and there is no way to take back the part that went out.
        """
        try:
            while True:
                var piece = body.read_chunk()
                if len(piece) == 0:
                    break
                if chunked:
                    self.stream.write(
                        Span(chunk(Span(piece))), deadline.renewed()
                    )
                else:
                    self.stream.write(Span(piece), deadline.renewed())
        except e:
            body.close()
            self.machine.closed()
            self.stream.close()
            raise e
        if chunked:
            self.stream.write(
                Span(terminal_chunk(Headers())), deadline.renewed()
            )
        body.close()

    def _wait_for_continue(mut self, deadline: Deadline) raises -> Bool:
        """Whether to go ahead and send the body.

        True for a `100 Continue` and true for the timeout, which is the
        recovery RFC 9110 asks for: a server that ignored the expectation is
        waiting for a body it never acknowledged. False only when a final
        response arrived, and then the body is never sent at all.
        """
        # Fixed, because this one really is a total budget. It is the wait for a
        # server to say yes or no, and a wait that restarted on every read
        # would never end against a server that says neither slowly.
        var wait = deadline.earlier_of(
            Deadline.after(CONTINUE_WAIT_SECONDS)
        ).fixed()
        while True:
            var answered = self.machine.poll_continue()
            if answered:
                return answered.value()
            try:
                if self._fill(wait) == 0:
                    raise remote_error(
                        "the server closed before answering the expectation"
                    )
            except e:
                if wait.expired():
                    return True
                raise e

    def _read_final_head(mut self, deadline: Deadline) raises -> ResponseHead:
        while True:
            var found = self.machine.poll_head()
            if found:
                return found.take()
            if self._fill(deadline) == 0:
                raise remote_error(
                    "the server closed before sending a complete response"
                )

    def _fill(mut self, deadline: Deadline) raises -> Int:
        """One read into the buffer. Zero means the peer closed.

        The deadline starts again here, which is what makes the read timeout a
        limit on how long the server may go quiet rather than a limit on how
        long the response may take. A ten minute download over a link that
        never stalls stays inside a five second read timeout, and a server that
        stops talking halfway through still fails after five seconds.
        """
        var scratch = List[UInt8](length=READ_SIZE, fill=0)
        var n = self.stream.read(Span(scratch), deadline.renewed())
        if n > 0:
            self.machine.fill_from(Span(scratch)[:n])
        return n
