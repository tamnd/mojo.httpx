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

## What is not here yet

https. There is no async TLS handshake, so an https request is refused with a
message that says so rather than being quietly sent in the clear. The handshake
is its own suspending loop, because OpenSSL asks for more socket data by
returning WANT_READ rather than by waiting, and it is the next piece.
"""

from std.memory import ArcPointer
from std.runtime.asyncrt import _run

from httpx._exceptions import ErrorKind, is_connect_error, new_error
from httpx._ffi.netdb import SockAddr
from httpx._io.aio import yield_now
from httpx._io.aio_connect import RACING, Race, _race_step, start_race
from httpx._io.deadline import NANOS_PER_SECOND, Deadline, Deadlines, now_ns
from httpx._io.dns import Resolver
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._pool.limits import Limits
from httpx._pool.origin import Origin, origin_for
from httpx._proto.h1.aio import (
    _DONE,
    _WAIT,
    AsyncH1Connection,
    Exchange,
    _prepare,
    _read_step,
    _settle,
    _start_reading,
    _write_step,
)
from httpx._proto.h1.writer import TargetForm


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
        connecting: Int,
    ):
        self.origin = origin^
        self.form = form
        self.race = race^
        self.conn = conn^
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
        return Self(origin^, form, Race(List[SockAddr](), String()), conn^, 0)

    @staticmethod
    def opening(var origin: Origin, form: TargetForm, var race: Race) -> Self:
        """A request whose connection does not exist yet."""
        return Self(origin^, form, race^, AsyncH1Connection.detached(), 1)

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


async def pooled_exchange[
    r: MutOrigin, c: MutOrigin, q: MutOrigin, x: MutOrigin
](
    race: Pointer[Race, r],
    conn: Pointer[AsyncH1Connection, c],
    request: Pointer[Request, q],
    result: Pointer[Exchange, x],
    connecting: Int,
    connect_at: Deadline,
    write_at: Deadline,
    read_at: Deadline,
    form: TargetForm = TargetForm.ORIGIN,
):
    """Connect if needed, send `request`, and read the whole response.

    Two loops, each of them a wait written out inline rather than a call to
    something that waits. That is forced: a coroutine that suspends inside a
    loop cannot be awaited by another coroutine, so a connect that loops and an
    exchange that loops cannot be two coroutines with this one on top. They are
    two loops in one function, and every step they drive is a synchronous helper
    shared with the standalone async connect and the standalone async driver, so
    there is one implementation of Happy Eyeballs and one of HTTP/1.1 no matter
    which of the three entry points a caller uses.

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
    """
    if connecting == 1:
        while _race_step(race, connect_at) == RACING:
            await yield_now()
        _adopt_winner(race, conn, result)

    _load_request(conn, request, result, form)

    var rounds = 0
    while _exchange_step(conn, result, write_at, read_at, rounds) == _WAIT:
        rounds += 1
        await yield_now()

    _settle(conn, result)


def _adopt_winner[
    r: MutOrigin, c: MutOrigin, x: MutOrigin
](
    race: Pointer[Race, r],
    conn: Pointer[AsyncH1Connection, c],
    result: Pointer[Exchange, x],
):
    """Put the socket the race produced into the detached connection.

    Where a failed connect stops being a field of the race and starts being a
    recorded failure, since the coroutine above cannot catch one. The connection
    is left detached in that case, and every step after this one finds the
    failure on the exchange and passes.
    """
    try:
        var stream = race[].take_stream()
        conn[].adopt(stream^)
    except e:
        result[].fail(e^)


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

    return _read_step(conn, result, read_at, rounds)


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

    var _idle: List[AsyncPooledConnection]
    """Idle connections, oldest first.

    A list rather than a map from origin to connections. The scan is linear in
    the number of idle connections, which the limits cap at a couple of dozen,
    and a linear scan of twenty entries is faster than hashing a string. Oldest
    first is what makes eviction and expiry both a walk from the front.
    """

    var _leased: Int
    """Connections currently carrying a request, so not in `_idle`."""

    def __init__(out self, var limits: Limits, ttl_seconds: Int = 60):
        self.limits = limits^
        self.resolver = Resolver(ttl_seconds)
        self._idle = List[AsyncPooledConnection]()
        self._leased = 0

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

    def open(
        mut self,
        request: Request,
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
        """
        var origin = origin_for(request.url)
        if origin.is_secure():
            raise new_error(
                ErrorKind.INVALID_ARGUMENT,
                String(
                    "the async pool cannot speak https yet, so ",
                    origin,
                    " has to go through the synchronous client for now",
                ),
            )

        var found = self._take_idle(origin)
        if found:
            self._leased += 1
            return PoolCall.reusing(origin, form, found.take())

        self._make_room(origin, deadlines)
        # Resolution blocks, and it is done here rather than inside the
        # coroutine for that reason. `getaddrinfo` has no non blocking form on
        # either platform this library supports, so a coroutine that called it
        # would hold its worker for the whole lookup.
        var race = start_race(self.resolver, origin.host, origin.port)
        self._leased += 1
        return PoolCall.opening(origin, form, race^)

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
that produced it and has to give its connection back when the body ends. The
async streaming source is not written yet, so nothing uses this today, and it is
declared here so that the transport above can be written against the handle
rather than against the pool and not have to change when it arrives.
"""
