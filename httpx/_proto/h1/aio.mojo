"""One HTTP/1.1 exchange over a connection that gives its worker back.

The second driver over `httpx._proto.h1.machine`. Everything about HTTP/1.1
itself, the framing rules, the head parsing, the smuggling defences, is in that
file and is shared with the synchronous driver in
`httpx._proto.h1.connection`. What is here is the socket half, written so that
waiting for the network hands the worker back instead of holding it.

## Why the whole exchange is one coroutine

It would read better as a request writer that awaits a head reader that awaits a
body reader. Mojo 1.0.0 does not allow it. A coroutine that is awaited may
suspend exactly once and not inside a loop, and every one of those steps wants
to suspend as often as the network makes it, so none of them can be awaited by
another. A coroutine handed to `_run` or `TaskGroup.create_task` has no such
limit, so the whole exchange is one such coroutine with every wait written out
inline. `httpx._io.aio` has the full list of what the toolchain allows and
`tools/probe/async.mojo` has a runnable case for each.

## Why the coroutine is only loops and integers

Everything a step actually does is in a synchronous helper at the bottom of this
file, and `exchange` calls them. That split is not a matter of taste. A
coroutine's own frame has to stay flat, and in this toolchain the ways it can
fail to are quiet ones:

A `List` a coroutine appends to across a suspension either fails to lower or
comes back empty at run time with no diagnostic, which for an HTTP client is a
response body that silently truncates. A `String` returned into the frame, an
`Error` bound by `except`, and a field read through two levels of struct all
fail to lower with `operand #0 does not dominate this use`. And a coroutine that
makes a `TaskGroup` may not have an `Optional` in its frame at all, which is
worth knowing because `write_deadline` takes one, so building a deadline next to
a task group crashes the compiler outright.

So owned memory lives behind a pointer and is mutated in place by synchronous
code: the bytes going out sit in `outbox` on the connection, the read buffer is
a field, the offset written so far is a field because it has to survive a wait,
and the answer is built inside an `Exchange` the caller owns. The frame of
`exchange` itself is an `Int` and two `Deadline`s.

The helpers each carry an inner loop for the same reason from the other
direction. `_write_step` keeps writing while the socket keeps taking, and
`_read_step` keeps parsing while the buffer keeps giving, so the only thing the
coroutine does between waits is decide that a wait is genuinely necessary. A
response that arrives in four packets costs four waits and not eight.

## Failure

A coroutine cannot raise, so a failure is recorded on the `Exchange` and turned
back into an exception by `Exchange.response` on the synchronous side. Both
kinds are recorded: a syscall that failed, which arrives as an `Outcome`, and a
protocol rule that the machine objected to, which arrives as a caught `Error` in
one of the helpers. The first failure wins and the rest of the exchange is
abandoned.
"""

from std.ffi import c_int

from httpx._exceptions import ErrorKind, new_error
from httpx._ffi.errno import Op
from httpx._ffi.openssl import SslCtx
from httpx._io.aio import Outcome, poll_slice, slice_for, yield_now
from httpx._io.deadline import Deadline
from httpx._io.socket import TcpStream
from httpx._models.headers import Headers
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._proto.h1.head import ResponseHead
from httpx._proto.h1.machine import H1Machine, remote_error
from httpx._proto.h1.writer import TargetForm, chunk, terminal_chunk
from httpx._stream.aio_stream import AsyncStream, STREAM_AGAIN, STREAM_BROKEN

comptime READ_SIZE = 8192
"""How much to ask the kernel for at a time. Matches the synchronous driver."""


struct Exchange(Movable):
    """Where an async exchange puts its answer.

    Owned by the caller and mutated in place through a pointer, because a
    coroutine cannot return anything and cannot hold owned memory in its own
    frame across a suspension.

    Nothing here raises while the exchange is running. `response` is the point
    where a recorded failure becomes an exception again, and it is called from
    synchronous code.
    """

    var head: Optional[ResponseHead]

    var got_head: Bool
    """Whether the head has been parsed, which is not the same as still holding
    it.

    A streaming caller takes the head out as soon as it arrives, because it
    turns it into a `Response` and hands that to the user while the body is
    still coming. What is left behind has to go on saying that the head is
    over, or the next read would start looking for a status line in the middle
    of the body.
    """

    var content: List[UInt8]
    var trailers: Headers
    var peer: String
    var problem: Optional[Error]

    def __init__(out self):
        self.head = None
        self.got_head = False
        self.content = List[UInt8]()
        self.trailers = Headers()
        self.peer = String()
        self.problem = None

    def failed(self) -> Bool:
        return self.problem.__bool__()

    def naming(mut self, var peer: String):
        """Remember who this is talking to, for the wording of any failure.

        Set once before any loop starts, so that no failure path has to build a
        string inside the coroutine.
        """
        self.peer = peer^

    def fail(mut self, var problem: Error):
        """Record a failure. The first one wins.

        Later ones are the wreckage of the first: a read that fails leaves the
        framing unknown, and the complaint about the framing is not the thing
        worth reporting.
        """
        if not self.problem:
            self.problem = Optional[Error](problem^)

    def fail_outcome(mut self, got: Outcome):
        """Record a syscall that failed, worded the way the sync path words it.
        """
        self.fail(
            new_error(got.kind(), got.message(_phrase(got.op(), self.peer)))
        )

    def took_head(mut self, var head: ResponseHead):
        self.head = Optional[ResponseHead](head^)
        self.got_head = True

    def took_bytes(mut self, var piece: List[UInt8]):
        self.content.extend(Span(piece))

    def took_trailers(mut self, var trailers: Headers):
        self.trailers = trailers^

    def take_head(mut self) raises -> ResponseHead:
        """The head, or the failure that stopped it from arriving.

        What a streaming caller wants, since for one of those the head is the
        whole of the answer so far and the body is still on the wire.
        """
        if self.problem:
            raise self.problem.take()
        if not self.head:
            raise remote_error("the exchange finished without a response")
        return self.head.take()

    def take_content(mut self) -> List[UInt8]:
        """The body bytes collected so far, leaving the exchange empty.

        For a streaming caller, which runs the exchange one piece at a time and
        takes each piece before asking for the next. A buffered caller never
        needs this, because `response` hands over the whole thing at once.
        """
        var out = List[UInt8]()
        swap(out, self.content)
        return out^

    def take_trailers(mut self) -> Headers:
        var out = Headers()
        swap(out, self.trailers)
        return out^

    def take_problem(mut self) -> Error:
        """The recorded failure. Only call this having asked `failed` first."""
        return self.problem.take()

    def response(mut self) raises -> Response:
        """The response, or the failure that stopped it from being one.

        The one place an async exchange becomes an ordinary raising call again.
        """
        if self.problem:
            raise self.problem.take()
        if not self.head:
            raise remote_error("the exchange finished without a response")
        var head = self.head.take()
        # Swapped out rather than moved out, because `self` is only borrowed
        # here and the caller may still be holding the exchange.
        var content = List[UInt8]()
        var trailers = Headers()
        swap(content, self.content)
        swap(trailers, self.trailers)
        return Response(
            head.status_code,
            head.reason_phrase.copy(),
            head.http_version.copy(),
            head.take_headers(),
            content^,
            trailers^,
        )


struct AsyncH1Connection(Movable):
    """A connection that can carry one async exchange at a time.

    Holds the sans I/O machine and the socket, the same pair the synchronous
    driver holds. The extra two fields are buffers that would have been locals
    in a function that was allowed to have them.
    """

    var stream: AsyncStream
    var machine: H1Machine

    var outbox: List[UInt8]
    """Bytes waiting to go out, written from by index.

    A field because the write loop suspends, and a `List` that a coroutine holds
    across a suspension is lost.
    """

    var written: Int
    """How much of the outbox has gone out.

    On the connection rather than in the loop for the same reason, one step
    further: the count has to survive a suspension too, and the only place this
    design has that survives one is here.
    """

    var scratch: List[UInt8]
    """The read buffer, made once and reused for the same reason."""

    def __init__(out self, var stream: AsyncStream):
        self.stream = stream^
        self.machine = H1Machine()
        self.outbox = List[UInt8]()
        self.written = 0
        self.scratch = List[UInt8](length=READ_SIZE, fill=0)

    @staticmethod
    def detached() -> Self:
        """A connection with no socket yet, for a caller that has to own the
        field before it owns the connection. See `AsyncStream.detached`."""
        return Self(AsyncStream.detached())

    def adopt(mut self, var inner: TcpStream):
        """Take the socket a connect just produced and start a fresh exchange.

        The machine is rebuilt rather than reused, because a detached connection
        has never spoken to anybody and a recycled one is not what this is for.
        The pool reuses a connection by keeping the whole `AsyncH1Connection`,
        not by putting a new socket into an old one.
        """
        self.stream.adopt(inner^)
        self.machine = H1Machine()
        self.outbox = List[UInt8]()
        self.written = 0

    def start_tls(mut self, ctx: SslCtx, hostname: String, verify: Bool) raises:
        """Put a TLS session on the socket, for the caller to shake hands over.

        Forwarded rather than done here, because the connection has no opinion
        about encryption: it writes bytes and reads bytes, and which of the two
        streams carries them is settled before the first request goes out. See
        `AsyncStream.start_tls`.
        """
        self.stream.start_tls(ctx, hostname, verify)

    def handshaking(self) -> Bool:
        """Whether a TLS session has been started and is not agreed yet."""
        return self.stream.handshaking()

    def try_handshake(mut self) -> Int:
        """One step of the TLS handshake, with no waiting."""
        return self.stream.try_handshake()

    def is_secure(self) -> Bool:
        return self.stream.is_secure()

    def is_open(self) -> Bool:
        """Whether there is a socket here at all.

        What tells a detached connection from one the connect has filled in,
        which is how the pool's connect loop knows whether the race is still to
        run. A closed connection answers the same as a detached one, and the
        pool never asks about one of those.
        """
        return self.stream.is_open()

    def want(self) -> Int16:
        """Which way the socket has to move, after a step said to wait."""
        return self.stream.want()

    def failure(self, op: Op) -> Error:
        """The reason the last step gave up, worded. See `AsyncStream.failure`.
        """
        return self.stream.failure(op)

    def fd(self) -> c_int:
        return self.stream.fd()

    def peer(self) -> String:
        return self.stream.peer()

    def is_reusable(self) raises -> Bool:
        """Whether another request may be sent on this connection."""
        if not self.machine.is_finished():
            return False
        if self.machine.upgraded or not self.stream.is_open():
            return False
        return not self.stream.has_data_waiting()

    def close(mut self):
        self.machine.closed()
        self.stream.close()

    def load_request(mut self, mut request: Request, form: TargetForm) raises:
        """Put the whole request, head and body, in the outbox.

        Both at once rather than a write between them, because the one case that
        needs the head to land on its own is `Expect: 100-continue` and this
        driver refuses that. One outbox means one write loop, and a write loop
        is a dozen lines that cannot be shared with anything.

        The body is one already in memory, which is every body this driver takes
        today. A streaming body is a second loop pulling from the source between
        writes, and it is not here yet.
        """
        self.outbox = self.machine.start_send(request, form)
        self.written = 0
        var chunked = "transfer-encoding" in request.headers
        if chunked:
            if len(request.content) > 0:
                self.outbox.extend(Span(chunk(Span(request.content))))
            self.outbox.extend(Span(terminal_chunk(Headers())))
        elif len(request.content) > 0:
            self.outbox.extend(Span(request.content))

    def sent_everything(self) -> Bool:
        return self.written >= len(self.outbox)

    def write_some(mut self) -> Int:
        """One `send` of what is left of the outbox, with no waiting.

        The codes are `AsyncStream`'s: a count, `STREAM_AGAIN` to wait for
        `want`, or `STREAM_BROKEN` for a failure `failure` will word.

        Counts what went out itself, because the caller that would otherwise
        hold the offset is a coroutine and would lose it at the next wait.
        """
        var n = self.stream.try_write(Span(self.outbox), self.written)
        if n > 0:
            self.written += n
        return n

    def read_some(mut self) -> Int:
        """One `recv` into the machine, with no waiting.

        Zero is the end of the stream. The negative codes are the ones
        `write_some` reports.
        """
        var n = self.stream.try_read(Span(self.scratch))
        if n > 0:
            self.machine.fill_from(Span(self.scratch)[:n])
        return n

    def body_sent(mut self):
        """Tell the machine the request is fully on the wire."""
        self.machine.body_sent()

    def give_up(mut self):
        """Close down after a failure, so nothing goes back to the pool."""
        self.machine.abandon()
        self.stream.close()

    @no_inline
    def finish(mut self):
        """Close the socket if the exchange ended the connection.

        Not inlined, and that is the compiler rather than a judgement about
        size. Inlined into the tail of a coroutine, the load of `machine` is
        sunk into the branch that closes the stream and the module then fails to
        lower with `operand #0 does not dominate this use`. Keeping the call a
        call keeps the load where it was written.
        """
        if self.machine.wants_close():
            self.stream.close()


comptime _NEED_BYTES = 0
"""The machine has used every byte in hand and wants more from the socket."""

comptime _MOVED = 1
"""Something moved without a read, so ask again before waiting on anything."""

comptime _WAIT = 4
"""Nothing can move until the socket is ready, so give the worker back."""

comptime _DONE = 2
"""This half of the exchange is over."""

comptime _FAILED = 3
"""Something went wrong and the reason is already on the exchange."""


comptime WHOLE_BODY = 0
"""Read until the body ends. What a buffered request wants."""

comptime HEAD_ONLY = 1
"""Stop the moment the head is complete, leaving the body on the wire.

The first half of a streaming request. The connection is deliberately left
open and unsettled, because the caller is about to take it away and read the
body from it at its own pace.
"""

comptime ONE_PIECE = 2
"""Stop after a single piece of body, or at the end of it.

The second half of a streaming request, and the reason the reading can be
driven a chunk at a time: each call is its own coroutine, started and run to
completion by the source, so nothing about a body in progress ever has to be
stored in a coroutine's frame between chunks.
"""


async def exchange[
    c: MutOrigin, q: MutOrigin, x: MutOrigin
](
    conn: Pointer[AsyncH1Connection, c],
    request: Pointer[Request, q],
    result: Pointer[Exchange, x],
    write_at: Deadline,
    read_at: Deadline,
    form: TargetForm = TargetForm.ORIGIN,
):
    """Send one request and read the whole response, waiting by giving way.

    The async twin of `H1Connection.exchange`, and the same two deadlines for
    the same reason: a slow upload is not the same problem as a server that
    never answers.

    Two loops, one that writes and one that reads, both written out here rather
    than called, because a coroutine that suspends inside a loop cannot be
    awaited by another one.

    Everything else is a call to a synchronous helper below, and that is not
    tidiness. This function's frame is an `Int` and two `Deadline`s and nothing
    else, because a coroutine's frame has to stay flat: a `String` coming back
    from a call, an `Error` bound by `except`, and in this toolchain even a
    field read through two levels of struct, all fail to lower or come back
    wrong. So the helpers do the syscalls, the parsing and the failure wording,
    and all this function decides is when to give the worker back.

    A streaming request body and `Expect: 100-continue` are refused up front
    rather than half handled. Both need a second source driven between writes,
    which is another suspending loop, and neither is written yet. Refusing is
    the honest answer, because sending framing headers for a body that never
    arrives leaves the server waiting on a request that will not finish.
    """
    if not _prepare(conn, request, result, form):
        _abandon(conn)
        return

    var rounds = 0
    while _write_step(conn, result, write_at, rounds) == _WAIT:
        rounds += 1
        await yield_now()

    if not _start_reading(conn, result):
        _abandon(conn)
        return

    rounds = 0
    while _read_step(conn, result, read_at, rounds, WHOLE_BODY) == _WAIT:
        rounds += 1
        await yield_now()

    _settle(conn, result, WHOLE_BODY)


async def next_piece[
    c: MutOrigin, x: MutOrigin
](
    conn: Pointer[AsyncH1Connection, c],
    result: Pointer[Exchange, x],
    read_at: Deadline,
):
    """Read one more piece of a body that is already in progress.

    The whole of async streaming, and it is small because of where it sits. A
    streaming source cannot hold a coroutine, since a `Coroutine` cannot be
    stored in a field, so it holds the connection instead and starts one of
    these for every chunk the caller asks for. The state that has to survive
    between chunks is on the connection and on the exchange, both of which the
    source owns, and this frame is an `Int` and a `Deadline` the same as every
    other coroutine here.

    Nothing is settled at the end. The connection belongs to the source until
    the body runs out, and what happens to it then is the pool's decision rather
    than this one's.
    """
    var rounds = 0
    while _read_step(conn, result, read_at, rounds, ONE_PIECE) == _WAIT:
        rounds += 1
        await yield_now()


def _prepare[
    c: MutOrigin, q: MutOrigin, x: MutOrigin
](
    conn: Pointer[AsyncH1Connection, c],
    request: Pointer[Request, q],
    result: Pointer[Exchange, x],
    form: TargetForm,
) -> Bool:
    """Everything that happens before the first byte goes out.

    Names the peer for the wording of any later failure, refuses the two request
    shapes this driver does not carry yet, and fills the outbox. False means the
    reason is already on the exchange and there is nothing to drive.
    """
    try:
        result[].naming(conn[].peer())
        if request[].has_stream():
            raise new_error(
                ErrorKind.INVALID_ARGUMENT,
                "the async driver cannot send a streaming request body yet",
            )
        if conn[].machine.expects_continue(request[]):
            raise new_error(
                ErrorKind.INVALID_ARGUMENT,
                (
                    "the async driver cannot send a request that expects 100"
                    " Continue yet"
                ),
            )
        conn[].load_request(request[], form)
    except e:
        result[].fail(e^)
        return False
    return True


def _write_step[
    c: MutOrigin, x: MutOrigin
](
    conn: Pointer[AsyncH1Connection, c],
    result: Pointer[Exchange, x],
    deadline: Deadline,
    rounds: Int,
) -> Int:
    """Push out as much of the outbox as the socket will take right now.

    Returns `_WAIT` only when there is genuinely nothing else to do until the
    socket is writable again, so a body that goes out in several short writes
    costs no scheduler round trips at all. A short write is normal rather than
    an error, which is why the loop keeps going: treating the return value as
    all or nothing is how a large request body gets silently truncated.

    `rounds` is how many times the caller has already given way, and it only
    picks the length of the poll slice.
    """
    while not conn[].sent_everything():
        if deadline.expired():
            result[].fail_outcome(Outcome.from_deadline(deadline, Op.WRITE))
            return _FAILED
        var n = conn[].write_some()
        if n > 0:
            continue
        if n != STREAM_AGAIN:
            result[].fail(conn[].failure(Op.WRITE))
            return _FAILED
        var writable = poll_slice(
            conn[].fd(), conn[].want(), deadline, slice_for(rounds)
        )
        if writable.failed():
            result[].fail_outcome(writable)
            return _FAILED
        return _WAIT
    return _DONE


def _start_reading[
    c: MutOrigin, x: MutOrigin
](conn: Pointer[AsyncH1Connection, c], result: Pointer[Exchange, x]) -> Bool:
    """Turn the connection round from sending to reading.

    False when the write loop already failed, so that what the caller sees is
    why the write failed rather than a complaint about reading a response that
    was never asked for.
    """
    if result[].failed():
        return False
    try:
        conn[].body_sent()
        conn[].machine.check_can_read()
    except e:
        result[].fail(e^)
        return False
    return True


def _read_step[
    c: MutOrigin, x: MutOrigin
](
    conn: Pointer[AsyncH1Connection, c],
    result: Pointer[Exchange, x],
    deadline: Deadline,
    rounds: Int,
    mode: Int,
) -> Int:
    """Take the response as far as the socket allows without waiting.

    The same shape as `_write_step`, and the same reason for the inner loop: a
    response that arrives in four packets should cost four waits, not four waits
    and four parses interleaved with pointless trips through the scheduler.

    `mode` is how far this is meant to get: the whole body, the head alone, or
    one piece of body. It is an argument rather than three functions because
    what changes between them is a single decision inside `_advance` and
    everything around it, the deadline, the poll, the end of stream handling, is
    the same work three times over.
    """
    while True:
        var step = _advance(conn, result, mode)
        if step == _MOVED:
            continue
        if step != _NEED_BYTES:
            return step
        if deadline.expired():
            result[].fail_outcome(Outcome.from_deadline(deadline, Op.READ))
            return _FAILED
        var n = conn[].read_some()
        if n > 0:
            continue
        if n == 0:
            _settle_at_eof(conn, result)
            return _FAILED if result[].failed() else _DONE
        if n != STREAM_AGAIN:
            result[].fail(conn[].failure(Op.READ))
            return _FAILED
        var readable = poll_slice(
            conn[].fd(), conn[].want(), deadline, slice_for(rounds)
        )
        if readable.failed():
            result[].fail_outcome(readable)
            return _FAILED
        return _WAIT


def _advance[
    c: MutOrigin, x: MutOrigin
](
    conn: Pointer[AsyncH1Connection, c],
    result: Pointer[Exchange, x],
    mode: Int,
) -> Int:
    """Move the response along as far as the bytes already in hand allow.

    Answers with one of the codes rather than raising, because the only thing
    above it that can act on a failure is a coroutine, and a coroutine can
    neither raise nor catch.

    `mode` decides where "as far as" stops. A head only pass is finished the
    moment the head is parsed and does not look at the body at all, and a one
    piece pass hands back the first piece it gets rather than going round for
    the next. A body that has already ended is the end in every mode, because
    there is no bytes left to be partway through.
    """
    try:
        if not result[].got_head:
            var found = conn[].machine.poll_head()
            if not found:
                return _NEED_BYTES
            conn[].machine.head_received(found.value())
            result[].took_head(found.take())
            return _DONE if mode == HEAD_ONLY else _MOVED
        if mode == HEAD_ONLY:
            return _DONE
        if not conn[].machine.reading_body():
            # The body ended on an earlier call, which takes the reader away.
            # Asking for another chunk here is what aborts rather than raises.
            result[].took_trailers(conn[].machine.take_trailers())
            return _DONE
        var piece = List[UInt8]()
        if not conn[].machine.poll_chunk(piece):
            return _NEED_BYTES
        if len(piece) == 0:
            result[].took_trailers(conn[].machine.take_trailers())
            return _DONE
        result[].took_bytes(piece^)
        return _DONE if mode == ONE_PIECE else _MOVED
    except e:
        result[].fail(e^)
        return _FAILED


def _settle_at_eof[
    c: MutOrigin, x: MutOrigin
](conn: Pointer[AsyncH1Connection, c], result: Pointer[Exchange, x]):
    """Finish the response, or fail it, now that the peer has closed.

    A close is the ending for one framing mode and a truncated message for the
    other two, and the machine is what knows which. A close before the head is
    complete is never an ending.
    """
    try:
        if not result[].got_head:
            result[].fail(
                remote_error(
                    "the server closed before sending a complete response"
                )
            )
            return
        if conn[].machine.reading_body():
            var piece = List[UInt8]()
            conn[].machine.at_eof(piece)
            if len(piece) > 0:
                result[].took_bytes(piece^)
        result[].took_trailers(conn[].machine.take_trailers())
    except e:
        result[].fail(e^)


def _abandon[c: MutOrigin](conn: Pointer[AsyncH1Connection, c]):
    """Close a connection that must not go back to the pool."""
    conn[].give_up()


def _settle[
    c: MutOrigin, x: MutOrigin
](
    conn: Pointer[AsyncH1Connection, c],
    result: Pointer[Exchange, x],
    mode: Int,
):
    """Close the connection, unless the exchange ended in a state that leaves it
    fit to carry another one.

    A head only pass that went well settles nothing, because it has not ended:
    the body is still on the wire and the connection is about to be handed to a
    streaming source that reads it. A head only pass that failed is settled the
    same as any other, since there is nothing to hand anybody.
    """
    if result[].failed():
        conn[].give_up()
    elif mode != HEAD_ONLY:
        conn[].finish()


def _phrase(op: Op, peer: String) -> String:
    """What a failed syscall was trying to do, worded as the sync path words it.

    Built here rather than in the coroutine, because the peer name is already on
    the exchange and a `String` has no business being in a coroutine's frame.
    """
    if op == Op.WRITE:
        return String("write to ", peer)
    if op == Op.CONNECT:
        return String("connect to ", peer)
    return String("read from ", peer)
