"""The connection pool again, for requests that give their worker back.

Everything this decides is what `httpx._pool.pool` decides, and it decides it
the same way: reuse a connection to the same origin when there is a sound one,
judge a pooled connection by both age and liveness before handing it out, evict
the oldest idle connection when the total limit is in the way, and put a
connection back only if the exchange that used it ended in a state that leaves
it fit to carry another. Those rules are the pool, and duplicating them would
mean two pools that drift apart, so the wording of each one here is deliberately
the wording used there.

What is different is that the waiting is not done by blocking. A request that
has to open a connection runs Happy Eyeballs by giving the worker back between
passes, and a request that has to wait for the socket gives it back there too,
so a client with a hundred requests in flight does not need a hundred threads
asleep in a poll.

## Why a request is a struct, and why the coroutine does not take it

`PoolCall` holds every piece of one request that has to survive a suspension:
the race that is opening a connection, the connection itself, and the answer
being built. All of it lives in the caller's memory, because a coroutine's own
frame has to stay flat in Mojo 1.0.0 and owned memory held across a suspension
either fails to lower or comes back empty at run time with no diagnostic.
`httpx._io.aio` has the full list.

What the coroutine takes is four separate pointers rather than one pointer to
the struct, and that costs an argument list nobody would choose. It is not a
choice. Reaching a field through the struct means the address is computed from a
pointer the frame is holding, in a block that does not dominate the blocks after
the next suspension. The whole thing fails to lower with `Instruction does not
dominate all uses`, naming the field being reached for, and hoisting the
addresses to the top of the coroutine does not help. A pointer that arrived as
an argument has no such problem, which is why every helper below takes the piece
it works on and not the request it belongs to.

So `PoolCall` is where the caller keeps the pieces, and taking them apart is
something the caller does, in synchronous code, on the line that starts the
coroutine.

## Why the connection is concrete rather than optional

A request that has to connect does not have a connection when it starts, and the
obvious way to say that is `Optional[AsyncH1Connection]`. It cannot be done that
way. A coroutine that reads a field through two levels of struct fails to lower,
and a coroutine that makes a `TaskGroup` may not have an `Optional` in its frame
at all, so the shape has to avoid both. `AsyncH1Connection.detached` is the
answer: the slot exists from the start with no descriptor in it, every method
treats it as a closed connection, and `adopt` fills it in from synchronous code
once the race has a winner.

## Why whether to connect is an argument

The connect loop runs for a request that has no connection and is skipped for
one that reused a pooled connection, and what decides that is an `Int` handed in
rather than something asked of the race. A guard standing before a suspending
loop may read a scalar and not much else: a helper that answered the same
question by looking at the length of the address list fails to lower. The caller
knows the answer before the coroutine starts, so it says so.

## How TLS fits into the connect loop

An https request shakes hands in the loop that opened the socket rather than in
a loop of its own, and that is the compiler rather than the design. A coroutine
may have a synchronous step between its first suspending loop and its second and
may not have one between its second and its third, so a third loop here would
have nowhere to put the turn around that already stands between the write and
the read. `_connect_step` therefore runs the race until it has a winner and then
drives `SSL_connect` a step at a time over the same socket, and both halves give
the worker back the same way.

None of the handshake itself is written twice. The steps are `TlsStream`'s, the
same code the synchronous pool hands its sockets to, and
`httpx._stream.aio_stream` says why a non blocking socket BIO is all it needs.

## What is not here yet

Tunnels. Reaching a server through an `http://` or a SOCKS proxy means a
handshake on the socket before the request goes out, which is a third thing for
the connect loop to drive. Refused rather than ignored, because carrying on
would send the request straight to the target.

HTTP/2. This pool speaks HTTP/1.1, so it does not offer h2 in ALPN whatever the
client was configured with, and a server therefore never picks it.
"""

from std.memory import ArcPointer
from std.runtime.asyncrt import TaskGroup, _run

from httpx._exceptions import ErrorKind, is_connect_error, new_error
from httpx._ffi.errno import Op
from httpx._ffi.netdb import SockAddr
from httpx._ffi.openssl import SslCtx
from httpx._io.aio import Outcome, poll_slice, slice_for, yield_now
from httpx._io.aio_connect import RACING, SETTLED, Race, _race_step, start_race
from httpx._io.deadline import NANOS_PER_SECOND, Deadline, Deadlines, now_ns
from httpx._io.dns import Resolver
from httpx._models.headers import Headers
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._models.stream import ByteSource, erase_source
from httpx._pool.limits import Limits
from httpx._pool.origin import Origin, origin_for
from httpx._pool.proxy import Proxy, route_through
from httpx._proto.h1.aio import (
    _DONE,
    _WAIT,
    AsyncH1Connection,
    Exchange,
    HEAD_ONLY,
    WHOLE_BODY,
    _prepare,
    _read_step,
    _settle,
    _start_reading,
    _write_step,
    next_piece,
)
from httpx._proto.h1.head import ResponseHead
from httpx._proto.h1.writer import TargetForm
from httpx._stream.aio_stream import STREAM_AGAIN
from httpx._stream.config import TlsConfig


comptime SharedSslCtx = ArcPointer[SslCtx]
"""A TLS context more than one request can hold.

Shared rather than copied because building one parses the trust store, which
for the default bundle is a hundred and fifty certificates and would be the
most expensive thing in the client if it happened per request. An `SSL_CTX` is
not copyable and every request that is about to connect needs to reach the same
one, so a handle it is.
"""


struct Securing(Movable):
    """What the connect loop needs to put TLS on the socket it just opened.

    Lives in the caller's memory beside the race, for the reason everything else
    a suspension has to survive does: the coroutine reaches it through a pointer
    and cannot hold any of it in its own frame.

    A plain `http://` request has one of these too, with no context in it, and
    the connect loop reads that as nothing to do. A field that is sometimes
    absent is cheaper than a second shape of `PoolCall`.
    """

    var ctx: Optional[SharedSslCtx]
    """The pool's context, or nothing for a request that is not encrypted."""

    var hostname: String
    """The name to send in SNI and to check the certificate against.

    The host the caller asked for, not the address the race won with. A
    certificate is issued for a name, and checking it against whichever of the
    host's addresses answered first would fail on every host with more than one.
    """

    var verify: Bool
    """Whether to check the certificate against the name. See `TlsStream`."""

    var rounds: Int
    """How many times the handshake has given way, which only picks how long a
    pass may sit in a poll. Same counter and same meaning as the one in the race
    and the ones in the socket waits."""

    def __init__(out self):
        """A request with no TLS on it."""
        self.ctx = None
        self.hostname = String()
        self.verify = False
        self.rounds = 0

    @staticmethod
    def over_tls(
        var ctx: SharedSslCtx, var hostname: String, verify: Bool
    ) -> Self:
        var out = Self()
        out.ctx = Optional(ctx^)
        out.hostname = hostname^
        out.verify = verify
        return out^


struct PoolCall(Movable):
    """One request in flight, owned by whoever started it.

    Everything a suspension has to survive is in here, because a coroutine
    cannot hold any of it. A caller running one request keeps a single one of
    these on the stack. A caller running several under one `TaskGroup` keeps a
    list of them and gives each coroutine a pointer to its own entry.

    Nothing here raises while the request is running. `PoolCall` collects the
    reason instead, and `AsyncConnectionPool.finish` is where a recorded failure
    becomes an exception again.

    The coroutine below does not take one of these. It takes the fields, one
    pointer each, for the reason in the module docstring.
    """

    var origin: Origin
    var form: TargetForm

    var race: Race
    """The connect in progress, or an empty race that never runs.

    A request that reused a pooled connection still has this field, because the
    field cannot be conditional. It is left empty and `connecting` is what stops
    the coroutine from ever stepping it.
    """

    var conn: AsyncH1Connection
    """The connection, detached until there is one. See the module docstring."""

    var securing: Securing
    """The TLS to put on the socket once the race has won, if any."""

    var result: Exchange

    var connecting: Int
    """One when the race has to be run, zero when a pooled connection was
    reused. Handed to the coroutine, which reads it in the only `if` it has
    before a loop, and that `if` may read a scalar and little else."""

    def __init__(
        out self,
        var origin: Origin,
        form: TargetForm,
        var race: Race,
        var conn: AsyncH1Connection,
        var securing: Securing,
        connecting: Int,
    ):
        self.origin = origin^
        self.form = form
        self.race = race^
        self.conn = conn^
        self.securing = securing^
        self.result = Exchange()
        self.connecting = connecting

    @staticmethod
    def reusing(
        var origin: Origin, form: TargetForm, var conn: AsyncH1Connection
    ) -> Self:
        """A request that already has its connection.

        The race is built empty and never stepped. Building one anyway costs a
        `now_ns` and two empty lists, and it is what lets the connect loop be
        skipped by a counter rather than by a second shape of this struct.
        """
        return Self(
            origin^,
            form,
            Race(List[SockAddr](), String()),
            conn^,
            Securing(),
            0,
        )

    @staticmethod
    def opening(
        var origin: Origin,
        form: TargetForm,
        var race: Race,
        var securing: Securing,
    ) -> Self:
        """A request whose connection does not exist yet."""
        return Self(
            origin^,
            form,
            race^,
            AsyncH1Connection.detached(),
            securing^,
            1,
        )

    def take_connection(mut self) -> AsyncH1Connection:
        """Hand the connection over, leaving a detached one behind.

        Swapped rather than moved out, because Mojo will not move a field whose
        type has a destructor out of a value that still has to be destroyed, and
        this call happens while the pool is still holding the rest of the
        request. What is left is a connection with no descriptor, so the
        destructor that eventually runs on it has nothing to close.
        """
        var taken = AsyncH1Connection.detached()
        swap(taken, self.conn)
        return taken^

    def take_result(mut self) -> Exchange:
        """Hand the exchange over, leaving an empty one behind.

        For a streaming request, which gives both the connection and the
        exchange to the source that is going to read the body. The exchange goes
        along because it is already holding the name of the peer, and a source
        that failed halfway through a body should word its complaint the same
        way the head would have.
        """
        var taken = Exchange()
        swap(taken, self.result)
        return taken^


async def pooled_exchange[
    r: MutOrigin, c: MutOrigin, s: MutOrigin, q: MutOrigin, x: MutOrigin
](
    race: Pointer[Race, r],
    conn: Pointer[AsyncH1Connection, c],
    securing: Pointer[Securing, s],
    request: Pointer[Request, q],
    result: Pointer[Exchange, x],
    connecting: Int,
    connect_at: Deadline,
    write_at: Deadline,
    read_at: Deadline,
    form: TargetForm = TargetForm.ORIGIN,
    mode: Int = WHOLE_BODY,
):
    """Connect if needed, send `request`, and read the response.

    Two loops, each of them a wait written out inline rather than a call to
    something that waits. That is forced: a coroutine that suspends inside a
    loop cannot be awaited by another coroutine, so a connect that loops and an
    exchange that loops cannot be two coroutines with this one on top. They are
    two loops in one function, and every step they drive is a synchronous helper
    shared with the standalone async connect and the standalone async driver, so
    there is one implementation of Happy Eyeballs and one of HTTP/1.1 no matter
    which of the three entry points a caller uses.

    The TLS handshake is inside the connect loop rather than beside it, which
    the module docstring explains: there is no room for a third suspending loop.

    Below the connect loop this is `httpx._proto.h1.aio.exchange` doing the same
    things in the same order, because it is the same exchange. It is copied
    rather than called for the reason in the first paragraph.

    It differs from the driver in two ways, and both of them are the compiler
    rather than the design.

    Sending and receiving are one loop here instead of two. A coroutine may have
    a synchronous step between its first suspending loop and its second, and may
    not have one between its second and its third: put anything at all there,
    even a call that returns nothing, and the compiler dies with a stack dump
    and no diagnostic. Adding a connect loop to the driver's two therefore costs
    the turn around its own place to stand, so it moves inside the step where
    the write finishing and the read starting are one pass.

    And it has a single exit. The driver leaves early on a request that cannot
    be sent, and this cannot: a coroutine that calls the same function on two
    return paths after a suspension makes bytecode the compiler then rejects,
    with `invalid value index`. So a failure here does not leave, it makes every
    step after it do nothing, and the one `_settle` at the bottom closes the
    connection because the exchange failed rather than because a branch said so.

    The request is a separate pointer from the rest for a reason that is not
    about the compiler: it belongs to the caller both before and after. A
    redirect needs the request back to build the next one, and taking it out of
    a call afterwards would need a placeholder request, which needs a URL, which
    is more machinery than a pointer.

    `mode` is `WHOLE_BODY` for an ordinary request and `HEAD_ONLY` for a
    streaming one, which stops as soon as the status line and headers are in and
    leaves the body where it is. It is a parameter rather than a second
    coroutine because the difference is entirely inside the synchronous steps:
    the connect is the same connect, the write is the same write, and a copy of
    this function with one integer changed is a copy that would have to be kept
    in step with this one by hand.
    """
    if connecting == 1:
        while _connect_step(race, conn, securing, result, connect_at) == RACING:
            await yield_now()

    _load_request(conn, request, result, form)

    var rounds = 0
    while (
        _exchange_step(conn, result, write_at, read_at, rounds, mode) == _WAIT
    ):
        rounds += 1
        await yield_now()

    _settle(conn, result, mode)


@no_inline
def _connect_step[
    r: MutOrigin, c: MutOrigin, s: MutOrigin, x: MutOrigin
](
    race: Pointer[Race, r],
    conn: Pointer[AsyncH1Connection, c],
    securing: Pointer[Securing, s],
    result: Pointer[Exchange, x],
    deadline: Deadline,
) -> Int:
    """One pass of getting a usable connection: race, then handshake.

    Both halves in one step, so that the coroutine above has one loop for what
    is really one job. Which half a pass is in comes from the connection rather
    than from a phase kept beside it: a connection with no descriptor is one the
    race has not won yet, and there is no third state, so a separate field would
    be a second copy of something already known.

    `SETTLED` means stop, whether that is because the connection is ready or
    because the reason it is not has been recorded on the exchange.

    `@no_inline` because without it the compiler dies with `invalid value index`
    and no source location while lowering the coroutine above. Adopting the
    winner used to happen after the connect loop rather than inside it, and
    moving it in is what brought this on: it catches, and it builds the strings a
    caught failure is worded with, so inlining it puts a landing pad and its
    cleanup inside a loop body that the coroutine transform then has to split
    across a suspension. The barrier keeps all of that in an ordinary frame. It
    costs one call per pass of a loop that spends its time in `poll`.
    """
    if result[].failed():
        return SETTLED
    if not conn[].is_open():
        if _race_step(race, deadline) == RACING:
            return RACING
        _adopt_winner(race, conn, securing, result)
        if result[].failed():
            return SETTLED
    return _handshake_step(conn, securing, result, deadline)


def _adopt_winner[
    r: MutOrigin, c: MutOrigin, s: MutOrigin, x: MutOrigin
](
    race: Pointer[Race, r],
    conn: Pointer[AsyncH1Connection, c],
    securing: Pointer[Securing, s],
    result: Pointer[Exchange, x],
):
    """Put the socket the race produced into the detached connection.

    Where a failed connect stops being a field of the race and starts being a
    recorded failure, since the coroutine above cannot catch one. The connection
    is left detached in that case, and every step after this one finds the
    failure on the exchange and passes.

    Names the peer here rather than leaving it to `_prepare`, which is where the
    driver does it, because from here on a failure can happen before the request
    is loaded and the wording of one needs the name.

    The TLS session is started and not driven. `start_tls` agrees nothing with
    the far end, so what comes back is a connection that is open and not yet
    usable, which is what `_handshake_step` is for.
    """
    try:
        var stream = race[].take_stream()
        conn[].adopt(stream^)
        result[].naming(conn[].peer())
        if securing[].ctx:
            conn[].start_tls(
                securing[].ctx.value()[],
                securing[].hostname,
                securing[].verify,
            )
    except e:
        result[].fail(e^)


def _handshake_step[
    c: MutOrigin, s: MutOrigin, x: MutOrigin
](
    conn: Pointer[AsyncH1Connection, c],
    securing: Pointer[Securing, s],
    result: Pointer[Exchange, x],
    deadline: Deadline,
) -> Int:
    """One `SSL_connect`, and the decision about whether to wait for the socket.

    `SETTLED` for a plain connection, which has nothing to agree, and for one
    whose handshake has just finished or just failed. `RACING` means the socket
    has to move before there is any point in asking again, and which way it has
    to move is `want` rather than anything this could work out for itself: a
    handshake sends records in both directions.

    The connect deadline covers this as well as the socket, which is what the
    synchronous path does. A server that accepts a connection and then says
    nothing is a connect that never finished, whatever the kernel thinks of it.
    """
    if not conn[].handshaking():
        return SETTLED
    if deadline.expired():
        result[].fail_outcome(Outcome.from_deadline(deadline, Op.CONNECT))
        return SETTLED
    var step = conn[].try_handshake()
    if step == 1:
        return SETTLED
    if step != STREAM_AGAIN:
        result[].fail(conn[].failure(Op.CONNECT))
        return SETTLED
    var ready = poll_slice(
        conn[].fd(), conn[].want(), deadline, slice_for(securing[].rounds)
    )
    if ready.failed():
        result[].fail_outcome(ready)
        return SETTLED
    securing[].rounds += 1
    return RACING


def _load_request[
    c: MutOrigin, q: MutOrigin, x: MutOrigin
](
    conn: Pointer[AsyncH1Connection, c],
    request: Pointer[Request, q],
    result: Pointer[Exchange, x],
    form: TargetForm,
):
    """Fill the outbox, unless the connect already failed.

    The check `_prepare` does not do, because on the driver's path there is
    nothing before it that could have failed.
    """
    if result[].failed():
        return
    _ = _prepare(conn, request, result, form)


def _exchange_step[
    c: MutOrigin, x: MutOrigin
](
    conn: Pointer[AsyncH1Connection, c],
    result: Pointer[Exchange, x],
    write_at: Deadline,
    read_at: Deadline,
    rounds: Int,
    mode: Int,
) -> Int:
    """One pass of the whole exchange, sending or receiving as appropriate.

    Which of the two it is comes from the connection rather than from a phase
    kept alongside it. A connection that has not sent everything is still
    writing, and there is no third answer, so a separate field would be a second
    copy of something already known and a chance for the two to disagree.

    The turn around happens here, on the pass where the last of the request goes
    out, and that pass goes straight on to the first read rather than giving way
    in between. A server that has already answered is common enough on a fast
    link that the saved round trip is worth having, and the read costs nothing
    when it has not.

    `_DONE` for a request that has already failed, so that the loop above ends
    on the same value it ends on for a request that succeeded. The caller does
    not have to tell them apart, `_settle` does.

    `rounds` is how many times this request has given way, counting both halves.
    It only picks how long a pass may sit in a poll, and a request that has
    already waited a while is one that can afford to wait in longer pieces, so
    carrying the count across the turn around is the behaviour that was wanted
    anyway rather than a thing given up to have one loop.
    """
    if result[].failed():
        return _DONE

    if not conn[].sent_everything():
        var code = _write_step(conn, result, write_at, rounds)
        if code != _DONE:
            return code
        if not _start_reading(conn, result):
            return _DONE

    return _read_step(conn, result, read_at, rounds, mode)


struct Batch(Movable):
    """Several requests that are going to run at the same time.

    Two lists rather than a list of pairs, because `PoolCall` is what the pool
    hands back and `Request` is what the caller brought, and gluing them into a
    third type would mean taking them apart again at every use.

    Both lists are filled before any task starts and neither is resized while
    tasks are running, so a task holding an element by index is not racing a
    reallocation. Each task touches one index and no other, which is what makes
    handing out pointers into a list sound here.
    """

    var calls: List[PoolCall]
    var requests: List[Request]

    def __init__(out self):
        self.calls = List[PoolCall]()
        self.requests = List[Request]()


async def pooled_batch[
    b: MutOrigin
](batch: Pointer[Batch, b], deadlines: Deadlines):
    """Run every request in `batch`, all of them outstanding together.

    This is the whole of the concurrency. One task per request, one group, and
    the group is what waits. The requests interleave because each of them gives
    its worker back at every point it would otherwise block, so the number of
    requests in flight is not bounded by the number of workers.

    The deadlines arrive as an argument rather than being read off anything,
    because a coroutine that makes a `TaskGroup` may not have an `Optional`
    anywhere in its own frame, and building a `Deadlines` is one of the many
    ordinary operations that puts one there. Built by the caller, in synchronous
    code, and handed in.

    Nothing here can fail. Each task records its own outcome on its own
    `Exchange`, and `AsyncConnectionPool.finish` turns those back into responses
    or exceptions afterwards.
    """
    var group = TaskGroup()
    for i in range(batch[].calls.__len__()):
        group.create_task(
            pooled_exchange(
                Pointer(to=batch[].calls[i].race),
                Pointer(to=batch[].calls[i].conn),
                Pointer(to=batch[].calls[i].securing),
                Pointer(to=batch[].requests[i]),
                Pointer(to=batch[].calls[i].result),
                batch[].calls[i].connecting,
                deadlines.connect,
                deadlines.write,
                deadlines.read,
                batch[].calls[i].form,
            )
        )
    await group


struct AsyncPooledConnection(Movable):
    """One idle async connection, with what the pool needs to judge it by."""

    var origin: Origin
    var idle_since_ns: UInt64
    """When it last finished an exchange. Age is measured from here rather than
    from when it was opened, because a connection carrying requests back to back
    is not the one a server is about to close."""

    var conn: AsyncH1Connection

    def __init__(out self, var origin: Origin, var conn: AsyncH1Connection):
        self.origin = origin^
        self.idle_since_ns = now_ns()
        self.conn = conn^

    def idle_seconds(self) -> Float64:
        var elapsed = now_ns() - self.idle_since_ns
        return Float64(elapsed) / Float64(NANOS_PER_SECOND)

    def take(mut self) -> AsyncH1Connection:
        """Hand the connection out, leaving a detached one behind.

        The same swap `PoolCall.take_connection` does, and for the same reason.
        """
        var taken = AsyncH1Connection.detached()
        swap(taken, self.conn)
        return taken^

    def is_stale(self, expiry: Optional[Float64]) -> Bool:
        """Whether this connection is too doubtful to hand to a request.

        Two checks, and both of them matter. Age is the cheap one: a connection
        idle for longer than the keepalive expiry is one the server has probably
        already closed, and finding that out by sending a request means the
        request fails for a reason the user cannot act on. Liveness is the
        honest one: a peer that closed cleanly leaves the socket readable at end
        of file, and asking about that costs one non blocking call.

        Neither check can be skipped for being unlikely. On a busy client the
        unlikely case happens continuously.
        """
        if expiry and self.idle_seconds() >= expiry.value():
            return True
        try:
            return not self.conn.is_reusable()
        except:
            # A connection we cannot even ask about is one we cannot trust.
            return True


struct AsyncConnectionPool(Movable):
    """Async connections to reuse, keyed by origin, with limits kept honestly.

    There is no lock, for the reason there is none on `ConnectionPool`: the
    library is single threaded today and a lock that nothing contends is a lie
    about what has been thought through. The place a lock will go is where
    `_leased` is adjusted, and that is deliberately the only mutable count here.

    Split into `open`, the coroutine, and `finish` rather than one call, because
    the middle is the only part that is a coroutine and a caller running several
    requests at once needs to start them all before driving any of them. The one
    call version is `handle_request`, which is what a synchronous caller wants.
    """

    var limits: Limits
    var resolver: Resolver

    var tls: TlsConfig
    """How to shake hands with an https server.

    Held as configuration rather than as a built context, because building one
    parses the trust store and a client that never makes an https request should
    not pay for that. `_tls_context` builds it on the first one and every
    connection after that shares it.
    """

    var _ssl_ctx: Optional[SharedSslCtx]
    """The context, once something has needed it.

    Shared rather than owned outright, because a request that is still shaking
    hands is holding one and the pool is allowed to be closed underneath it.
    """

    var proxy: Optional[Proxy]
    """The proxy every request from this pool goes through, if there is one.

    Fixed for the life of the pool, for the reason the synchronous pool fixes
    it: a pool keys its connections by origin, and a pool that proxied some
    requests and not others would be filing the proxy and the server under keys
    that do not tell them apart.
    """

    var _idle: List[AsyncPooledConnection]
    """Idle connections, oldest first.

    A list rather than a map from origin to connections. The scan is linear in
    the number of idle connections, which the limits cap at a couple of dozen,
    and a linear scan of twenty entries is faster than hashing a string. Oldest
    first is what makes eviction and expiry both a walk from the front.
    """

    var _leased: Int
    """Connections currently carrying a request, so not in `_idle`."""

    def __init__(
        out self,
        var limits: Limits,
        ttl_seconds: Int = 60,
        var tls: TlsConfig = TlsConfig(),
        var proxy: Optional[Proxy] = None,
    ):
        self.limits = limits^
        self.resolver = Resolver(ttl_seconds)
        self.tls = tls^
        # This pool speaks HTTP/1.1 and nothing else, so it must not offer h2 in
        # ALPN whatever the client was configured with. Advertising a protocol
        # and then not speaking it is worse than not having it: the server picks
        # h2, sends a settings frame, and gets a request line back.
        self.tls.http2 = False
        self._ssl_ctx = None
        self.proxy = proxy^
        self._idle = List[AsyncPooledConnection]()
        self._leased = 0

    def _tls_context(mut self) raises -> SharedSslCtx:
        """The context every https connection from this pool is cut from.

        Built on the first one that needs it and shared by all of them after
        that. `Ssl` takes its own reference through `SSL_new`, so a handshake in
        flight keeps the context alive on the OpenSSL side as well.
        """
        if not self._ssl_ctx:
            self._ssl_ctx = Optional(SharedSslCtx(self.tls.build()))
        return self._ssl_ctx.value().copy()

    def idle_count(self) -> Int:
        return len(self._idle)

    def leased_count(self) -> Int:
        return self._leased

    def total_count(self) -> Int:
        return len(self._idle) + self._leased

    def close(mut self):
        """Close every idle connection.

        Says nothing about leased ones, because they are not here to close. A
        connection in the middle of a request is closed by whoever is running
        it, when it ends.
        """
        while len(self._idle) > 0:
            self._evict_oldest()

    def handle_request(
        mut self,
        var request: Request,
        deadlines: Deadlines,
        form: TargetForm = TargetForm.ORIGIN,
    ) raises -> Response:
        """Send `request` and read the answer, blocking this thread meanwhile.

        Blocks because `_run` does. What it does not do is hold a thread per
        connect attempt or per socket wait, so this is the right entry point for
        a synchronous caller that wants the async machinery underneath and the
        wrong one for a caller that already has coroutines in flight. That
        caller wants `open`, `pooled_exchange` in its own task group, and
        `finish`.
        """
        var call = self.open(request, deadlines, form)
        _run(
            pooled_exchange(
                Pointer(to=call.race),
                Pointer(to=call.conn),
                Pointer(to=call.securing),
                Pointer(to=request),
                Pointer(to=call.result),
                call.connecting,
                deadlines.connect,
                deadlines.write,
                deadlines.read,
                call.form,
            )
        )
        var response = self.finish(call)
        response.set_request(request^)
        return response^

    def handle_many(
        mut self,
        var requests: List[Request],
        deadlines: Deadlines,
        form: TargetForm = TargetForm.ORIGIN,
    ) raises -> List[Response]:
        """Send all of `requests` at once and read all of the answers.

        The point of the async pool. Every request is opened first, then all of
        them run under one task group, then all of them are finished, so a batch
        of ten requests to ten origins costs about what the slowest one costs
        rather than the sum.

        Blocks this thread until the last of them is done, for the reason
        `handle_request` does. A caller that already has coroutines of its own
        wants `open`, `pooled_exchange` and `finish` directly.

        The first failure is raised and the rest of the responses are dropped,
        which is what `asyncio.gather` does by default and what a caller sending
        a batch it needs all of nearly always wants. Every request is still run
        to the end and every connection still put back or closed before the
        raise, because leaking a lease is worse than losing a response. A
        variant that hands back failures alongside successes is worth having and
        is not here yet.

        Responses come back in the order the requests went in, which is not the
        order they finished in. Anything else would make the caller match them up
        by hand.
        """
        var batch = Batch()
        try:
            for i in range(len(requests)):
                batch.calls.append(self.open(requests[i], deadlines, form))
        except e:
            # Some of them were opened and are holding leases that nothing is
            # ever going to finish. Give those back before leaving, or the pool
            # spends the rest of the program believing it is fuller than it is.
            while len(batch.calls) > 0:
                var abandoned = batch.calls.pop()
                self._abandon(abandoned)
            raise e

        batch.requests = requests^
        _run(pooled_batch(Pointer(to=batch), deadlines))

        var responses = List[Response]()
        var reasons = List[Error]()
        for i in range(len(batch.calls)):
            try:
                responses.append(self.finish(batch.calls[i]))
            except e:
                if len(reasons) == 0:
                    reasons.append(e^)
        if len(reasons) > 0:
            raise reasons.pop()

        for i in range(len(responses)):
            responses[i].set_request(batch.requests.pop(0))
        return responses^

    def open(
        mut self,
        mut request: Request,
        deadlines: Deadlines,
        form: TargetForm = TargetForm.ORIGIN,
    ) raises -> PoolCall:
        """Everything that has to happen before the request can start.

        Raises rather than recording, because none of this is inside a
        coroutine yet. A pool that is full, a name that does not resolve and a
        scheme that cannot be spoken are all decided here, where they can still
        be an ordinary exception with a sentence in it.

        The lease is taken here and given back by `finish`, so a request that
        was opened and never driven still counts against the limit until it is
        finished. That is the honest accounting: the pool cannot tell a request
        that is about to run from one that has been abandoned.

        `request` is taken mutably because a proxy adds its headers to it here.
        Nothing else in this method changes it.
        """
        var route = route_through(self.proxy, request, form)
        if route.connect_via:
            # A tunnel of either kind is a handshake on the socket before the
            # request goes out, and the socket here is not opened until the
            # coroutine runs. Refused rather than ignored: carrying on would
            # connect straight to the target and send the request without the
            # proxy, which is a request going somewhere the caller told it not
            # to go.
            raise new_error(
                ErrorKind.INVALID_ARGUMENT,
                String(
                    "the async pool cannot open a tunnel yet, so reaching ",
                    route.origin,
                    " through ",
                    route.connect_via.value(),
                    " has to go through the synchronous client for now",
                ),
            )
        var origin = route.origin
        var wire = route.form

        var found = self._take_idle(origin)
        if found:
            self._leased += 1
            return PoolCall.reusing(origin, wire, found.take())

        self._make_room(origin, deadlines)
        # Resolution blocks, and it is done here rather than inside the
        # coroutine for that reason. `getaddrinfo` has no non blocking form on
        # either platform this library supports, so a coroutine that called it
        # would hold its worker for the whole lookup.
        var race = start_race(self.resolver, origin.host, origin.port)
        # Built here for the same reason: the first one parses the trust store,
        # and a coroutine that did that would hold its worker for all of it.
        var securing = Securing()
        if origin.is_secure():
            securing = Securing.over_tls(
                self._tls_context(), origin.host.copy(), self.tls.verify.enabled
            )
        self._leased += 1
        return PoolCall.opening(origin, wire, race^, securing^)

    def finish(mut self, mut call: PoolCall) raises -> Response:
        """The response, or the failure that stopped it from being one.

        Gives the lease back before anything else, so that a request which ends
        in an exception still frees its slot. Getting that order wrong is how a
        pool ends up reporting itself full when it is empty.

        A connect that failed also costs the resolver answer. On a host that
        worked before, the likeliest reason every address refused is a record
        that has gone stale, so the next attempt gets a fresh lookup rather than
        the same list back. A connect that timed out is left alone, because a
        slow network says nothing about whether the addresses are right.

        Which failure it was is read off the error rather than tracked in a
        field. The race hands its reason over to the exchange and does not keep
        a copy, and a flag that survived the coroutine would have to be another
        pointer in an argument list that is long enough.
        """
        self._leased -= 1

        var conn = call.take_connection()
        var response: Response
        try:
            response = call.result.response()
        except e:
            conn.close()
            if is_connect_error(e):
                self.resolver.forget(call.origin.host, call.origin.port)
            raise e

        self._release(call.origin, conn^)
        return response^

    def _abandon(mut self, mut call: PoolCall):
        """Give back the lease of a request that is never going to run.

        Not `finish`, because there is nothing to finish. The exchange never
        started, so there is no response to build and no state machine to ask
        whether the connection is fit to reuse. The connection, if the race had
        already produced one, is closed rather than pooled for the same reason.
        """
        self._leased -= 1
        var conn = call.take_connection()
        conn.close()

    def _take_idle(mut self, origin: Origin) -> Optional[AsyncH1Connection]:
        """The oldest sound idle connection to `origin`, closing any that are
        not.

        The candidate leaves the list before it is judged. Judging it in place
        and then removing it would mean two passes over the same entry, and the
        entry is a socket rather than a number, so the shorter path is the one
        with fewer chances to leave a descriptor behind.
        """
        var i = 0
        while i < len(self._idle):
            if self._idle[i].origin != origin:
                i += 1
                continue
            var candidate = self._idle.pop(i)
            var stale = candidate.is_stale(self.limits.keepalive_expiry)
            var conn = candidate.take()
            if stale:
                conn.close()
                continue
            return Optional[AsyncH1Connection](conn^)
        return None

    def _make_room(mut self, origin: Origin, deadlines: Deadlines) raises:
        """Get under the total limit, or explain why that is not possible.

        Evicting an idle connection to some other origin is the right trade when
        the pool is full: the connection being evicted is doing nothing, and the
        request being served is real. Only when every connection is leased is
        there nothing to give up, and then the wait is on the program itself
        rather than on the network, which is what `PoolTimeout` says.
        """
        if not self.limits.max_connections:
            return
        var allowed = self.limits.max_connections.value()
        while self.total_count() >= allowed and len(self._idle) > 0:
            self._evict_oldest()
        if self.total_count() >= allowed:
            raise new_error(
                ErrorKind.POOL_TIMEOUT,
                String(
                    "all ",
                    allowed,
                    (
                        " connections are in use and none can be freed, so"
                        " there is"
                    ),
                    " no way to reach ",
                    origin,
                ),
            )
        # Only reached when a slot was found, so the pool wait is over. Checked
        # afterwards rather than before because a deadline that passed while
        # nothing was being waited for is not a pool timeout.
        deadlines.pool.check(String("get a connection to ", origin))

    def _release(mut self, var origin: Origin, var conn: AsyncH1Connection):
        """Put a finished connection back, or close it.

        A connection only goes back if it says it can carry another request. The
        question is asked of the connection rather than answered here, because
        the state machine that ran the exchange is the only thing that knows how
        it ended.
        """
        var reusable: Bool
        try:
            reusable = conn.is_reusable()
        except:
            reusable = False
        if not reusable:
            conn.close()
            return

        var allowance = self.limits.keepalive_allowance()
        if allowance == 0:
            conn.close()
            return

        self._idle.append(AsyncPooledConnection(origin^, conn^))
        while allowance > 0 and len(self._idle) > allowance:
            # The oldest idle connection is the one closest to being closed by
            # the server anyway, so it is the one worth the least.
            self._evict_oldest()

    def _evict_oldest(mut self):
        var oldest = self._idle.pop(0)
        var conn = oldest.take()
        conn.close()


comptime SharedAsyncPool = ArcPointer[AsyncConnectionPool]
"""An async pool that more than one thing can hold.

Here for the same reason `SharedPool` is: a streaming response outlives the call
that produced it and has to give its connection back when the body ends, so the
source carries a handle rather than a reference and the pool stays alive as long
as anything is still reading from one of its connections.
"""


struct AsyncPooledSource(ByteSource, Movable):
    """A response body still on an async connection, with the connection to give
    back.

    The async twin of `httpx._pool.pool.PooledSource`, and it makes the same two
    promises: the connection goes back to the pool if the body ended the way it
    said it would and is closed if anything else happened, and either way the
    lease is given back so that a caller who walks away from a response halfway
    through does not leave the pool believing it is fuller than it is.

    ## Why this can exist when a stored coroutine cannot

    A streamed body is read at the caller's pace, which sounds like it needs a
    coroutine parked between chunks, and Mojo 1.0.0 has nowhere to park one: a
    `Coroutine` is linear and cannot be a field. What is stored here instead is
    the connection and the exchange, both ordinary values, and every call to
    `read_chunk` starts a fresh coroutine over them and runs it to the end. The
    machine that knows where the body has got to is `H1Machine` on the
    connection, which was never in a coroutine's frame in the first place.

    So the suspension happens inside one chunk rather than between two. A chunk
    that is not there yet gives the worker back and waits for the socket, and a
    caller sitting on a half read body holds a connection and no worker at all.
    What is not bought is reading several bodies at once: each `read_chunk`
    blocks the thread that called it, the same way `handle_request` does, and
    there is no `gather` for streams. `docs/async.md` says so.
    """

    var _pool: SharedAsyncPool
    var _origin: Origin
    var _conn: AsyncH1Connection
    var _live: Bool
    """Whether the connection is still here.

    A flag beside a detached connection rather than an `Optional` around a real
    one, for the reason `PoolCall` gives: `AsyncH1Connection.detached` is the
    shape this codebase uses for a slot that may or may not have a socket in it,
    and it keeps `Pointer(to=self._conn)` an ordinary address to hand a
    coroutine.
    """

    var _result: Exchange
    """Where each chunk lands, and where a failure is recorded.

    Carried over from the exchange that read the head, so the peer name is
    already in it.
    """

    var _deadline: Deadline
    """The read deadline, applied to each chunk rather than to the whole body,
    which is what lets a download that keeps making progress run as long as it
    likes while a server that goes quiet mid body still fails."""

    var _trailers: Headers

    def __init__(
        out self,
        var pool: SharedAsyncPool,
        origin: Origin,
        var conn: AsyncH1Connection,
        var result: Exchange,
        deadline: Deadline,
    ):
        self._pool = pool^
        self._origin = origin
        self._conn = conn^
        self._live = True
        self._result = result^
        self._deadline = deadline
        self._trailers = Headers()

    def read_chunk(mut self) raises -> List[UInt8]:
        if not self._live:
            return List[UInt8]()
        # Both fields belong to this source and nothing else can reach them.
        # `_run` does not return until the coroutine holding these addresses has
        # finished, so neither pointer outlives the call that made it, and no
        # second coroutine is ever looking at the same connection.
        _run(
            next_piece(
                Pointer(to=self._conn),
                Pointer(to=self._result),
                self._deadline,
            )
        )
        if self._result.failed():
            # The reason was recorded rather than raised, because a coroutine
            # cannot raise. Here is where it becomes an exception again, and the
            # connection goes rather than back to the pool, since a body that
            # stopped partway leaves the wire in an unknown place.
            self._drop()
            raise self._result.take_problem()
        var piece = self._result.take_content()
        if len(piece) == 0:
            self._give_back()
        return piece^

    def close(mut self):
        """Give up whatever is left of the body and release the connection.

        Always a close rather than a return to the pool, for the reason
        `PooledSource.close` gives: whatever is left of the body is still on the
        wire, and a connection whose next byte is the middle of somebody else's
        response is not one to hand to the next request.
        """
        self._drop()

    def trailers(self) -> Headers:
        return self._trailers.copy()

    def __deinit__(deinit self):
        """A response dropped without being read still gives its lease back."""
        if self._live:
            self._conn.close()
            self._pool[]._leased -= 1

    def _give_back(mut self):
        """The body ended where it said it would, so the connection may go back.
        """
        self._live = False
        self._trailers = self._result.take_trailers()
        var conn = self._take()
        # The close the buffered path does in `_settle`, which a streaming
        # exchange could not do at the time because the body had not been read
        # yet. A connection the server said it was going to close goes now, and
        # `_release` asks the machine whether what is left is fit to reuse.
        conn.finish()
        self._pool[]._leased -= 1
        self._pool[]._release(self._origin, conn^)

    def _drop(mut self):
        if not self._live:
            return
        self._live = False
        var conn = self._take()
        conn.close()
        self._pool[]._leased -= 1

    def _take(mut self) -> AsyncH1Connection:
        """The same swap `PoolCall.take_connection` does, and for the same
        reason."""
        var taken = AsyncH1Connection.detached()
        swap(taken, self._conn)
        return taken^


def stream_request(
    var pool: SharedAsyncPool,
    var request: Request,
    deadlines: Deadlines,
    form: TargetForm = TargetForm.ORIGIN,
) raises -> Response:
    """Send `request` and return as soon as the head has been read.

    The async twin of `httpx._pool.pool.stream_request`, and the same promise:
    the body stays on the connection and comes out through the response's
    iterators, and the connection goes back to the pool when the body ends or is
    closed when the response is closed or dropped, without the caller doing
    anything for either.

    Blocks this thread until the head is in, for the reason `handle_request`
    does. The connect still races addresses without holding a worker and the
    wait for the head still gives the worker back.
    """
    var call = pool[].open(request, deadlines, form)
    _run(
        pooled_exchange(
            Pointer(to=call.race),
            Pointer(to=call.conn),
            Pointer(to=call.securing),
            Pointer(to=request),
            Pointer(to=call.result),
            call.connecting,
            deadlines.connect,
            deadlines.write,
            deadlines.read,
            call.form,
            HEAD_ONLY,
        )
    )

    var conn = call.take_connection()
    var result = call.take_result()
    var head: ResponseHead
    try:
        head = result.take_head()
    except e:
        # The lease is given back here and not by `finish`, which is never
        # called for a streaming request: from the moment the head is in, the
        # lease belongs to the source and is given back when the body ends.
        conn.close()
        pool[]._leased -= 1
        if is_connect_error(e):
            pool[].resolver.forget(call.origin.host, call.origin.port)
        raise e

    var source = AsyncPooledSource(
        pool^, call.origin, conn^, result^, deadlines.read
    )
    var response = Response.streaming(
        head.status_code,
        erase_source(source^),
        head.reason_phrase.copy(),
        head.http_version.copy(),
        head.take_headers(),
    )
    response.set_request(request^)
    return response^
