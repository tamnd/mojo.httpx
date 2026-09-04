"""Happy Eyeballs again, without holding a worker while the race runs.

The race in `httpx._io.connect` is already the right algorithm and this does not
change it. What changes is the one line in the middle: the synchronous version
parks the calling thread for a millisecond between passes, and this one hands the
worker back to the scheduler instead. Everything else, the staggered starts, the
attempt delay, the six attempt ceiling, the error that names every address, is
the same code reached through the same helpers.

That matters more here than it does for a read. A connect is the one part of a
request that takes a whole round trip before anything can be sent, and on a host
whose first address does not work it takes several. A client with a hundred
requests to make should not have a hundred threads asleep in a poll for that.

The split is the one the compiler forces everywhere in this library. `Race` owns
everything the attempt list needs and lives in the caller's memory, `_race_step`
is ordinary synchronous code that does one pass over it, and the coroutine is two
lines that decide when to give way. A `List` of half open sockets is exactly the
kind of value that comes back empty from a coroutine's own frame, so it is not in
one. The reasoning is in the docstring of `httpx._io.aio`.

`_race_step` is public in all but name for the same reason `try_read` is: the
connection pool has to run a connect and an exchange in one coroutine, because a
coroutine cannot await another one that suspends in a loop, so the pool needs the
step rather than the loop.
"""

from std.runtime.asyncrt import _run

from httpx._exceptions import ErrorKind, message_of, new_error
from httpx._ffi.netdb import SockAddr
from httpx._io.aio import slice_for, yield_now
from httpx._io.connect import (
    ATTEMPT_DELAY_MS,
    MAX_ATTEMPTS,
    all_failed,
    park_briefly,
    winner_index,
)
from httpx._io.deadline import NANOS_PER_MS, Deadline, now_ns
from httpx._io.dns import Resolver
from httpx._io.socket import PendingConnect, TcpStream, start_connect

comptime RACING = 0
"""Nothing has won yet and nothing has gone wrong. Give way and come back."""

comptime SETTLED = 1
"""There is a winner, or there is a reason there is not. Either way, stop."""


struct Race(Movable):
    """Every attempt in a staggered connect, owned by whoever started it.

    Lives in the caller's memory rather than in the coroutine's frame, which is
    not a preference. Half open sockets are owned memory, and owned memory a
    coroutine holds across a suspension either fails to lower or comes back
    empty at run time. Here the coroutine only ever reaches it through a
    pointer, which works.

    Failure is a field rather than an exception for the other standing reason: a
    coroutine cannot raise. `take_stream` is where the race becomes an ordinary
    raising call again.
    """

    var addresses: List[SockAddr]
    var peer: String
    """What to call the host in a failure message. Built once, before the race
    starts, so that no path inside the coroutine has to make a string."""

    var pending: List[PendingConnect]
    var failures: List[String]

    var next_address: Int
    var next_start_ns: UInt64
    """When the next attempt may start. The stagger, and the whole reason this
    is not a connection storm."""

    var rounds: Int
    """How many passes have been made, which is what decides whether a pass is
    still allowed to be a hot spin. Same counter and same meaning as the one in
    the socket waits."""

    var won: Optional[PendingConnect]
    var problem: Optional[Error]

    def __init__(out self, var addresses: List[SockAddr], var peer: String):
        self.addresses = addresses^
        self.peer = peer^
        self.pending = List[PendingConnect]()
        self.failures = List[String]()
        self.next_address = 0
        self.next_start_ns = now_ns()
        self.rounds = 0
        self.won = None
        self.problem = None

    def failed(self) -> Bool:
        """Whether the race ended with a reason rather than a connection.

        For a caller that wants to know before it asks for the stream, which is
        every caller running several races at once: one that failed should not
        cost the whole batch an exception on the way out.
        """
        return self.problem.__bool__()

    def fail(mut self, var problem: Error):
        """Record why the race is over. The first reason wins.

        Anything after it is the wreckage: once the deadline has passed every
        attempt still in flight will report the same thing, and six copies of
        one timeout is not a better message than one.
        """
        if not self.problem:
            self.problem = Optional[Error](problem^)

    def take_stream(mut self) raises -> TcpStream:
        """The connection that won, or the reason there is not one.

        Called from synchronous code, which is the only place the failure can go
        back to being an exception. The attempts that lost are dropped here
        rather than left to fall out of scope later, so the half open
        connections a race necessarily creates stop taking up room in the
        server's accept queue as soon as they are known to be surplus.
        """
        if self.problem:
            raise self.problem.take()
        if not self.won:
            raise new_error(
                ErrorKind.CONNECT_ERROR,
                String("the race for ", self.peer, " ended with no winner"),
            )
        var winner = self.won.take()
        self.pending.clear()
        return winner.take_stream()


async def race_connect[
    r: MutOrigin
](race: Pointer[Race, r], deadline: Deadline):
    """Run `race` to a winner or a failure, giving way between passes.

    Two lines, because everything a pass does is in `_race_step` and everything
    a pass owns is in `Race`. What is left in the coroutine is the decision to
    give way, which is the only part that has to be a coroutine at all.

    Drive it with `_run` for a single connect, or hand it to
    `TaskGroup.create_task` to open several connections at once. It cannot be
    awaited from another coroutine, because it suspends inside a loop.
    """
    while _race_step(race, deadline) == RACING:
        await yield_now()


def _race_step[r: MutOrigin](race: Pointer[Race, r], deadline: Deadline) -> Int:
    """One pass over the attempts: start what is due, check what is in flight.

    The body is `connect_to_addresses` with the wait taken out and the raises
    turned into a recorded failure. Keeping the two in step matters more than
    sharing the lines would, because the thing being tested by
    tests/unit/test_connect.mojo is the algorithm and not the loop around it.

    Ends with a bounded park rather than returning straight away. The first
    rounds are zero length polls, which notice a connect to a nearby host
    almost at once, and after that the kernel does the waiting on a one
    millisecond slice. Without the park a race against a slow host would spin a
    core for the whole connect timeout.
    """
    try:
        # Checked before anything is started, so a deadline that has already
        # passed reports a timeout rather than getting one attempt in first.
        deadline.check(String("connect to ", race[].peer))

        if (
            race[].next_address < len(race[].addresses)
            and len(race[].pending) < MAX_ATTEMPTS
            and now_ns() >= race[].next_start_ns
        ):
            try:
                race[].pending.append(
                    start_connect(
                        race[].addresses[race[].next_address], race[].peer
                    )
                )
            except e:
                race[].failures.append(message_of(e))
            race[].next_address += 1
            race[].next_start_ns = now_ns() + UInt64(
                ATTEMPT_DELAY_MS * NANOS_PER_MS
            )

        var lost = len(race[].failures)
        var winner = winner_index(race[].pending, race[].failures)
        if winner >= 0:
            race[].won = Optional[PendingConnect](race[].pending.pop(winner))
            return SETTLED

        if len(race[].failures) > lost:
            # RFC 8305 section 5: an attempt that failed does not have to be
            # waited out, or a refused first address still costs the full
            # attempt delay before the second one is tried.
            race[].next_start_ns = now_ns()

        if len(race[].pending) == 0 and race[].next_address >= len(
            race[].addresses
        ):
            race[].fail(all_failed(race[].peer, race[].failures))
            return SETTLED
    except e:
        race[].fail(e^)
        return SETTLED

    park_briefly(deadline, slice_for(race[].rounds))
    race[].rounds += 1
    return RACING


def start_race(
    mut resolver: Resolver, host: StringSpan, port: UInt16
) raises -> Race:
    """Resolve `host` and build the race, without connecting to anything yet.

    Separate from running it because resolution blocks. `getaddrinfo` has no non
    blocking form on either platform this library supports, so a coroutine that
    called it would hold its worker for the whole lookup, and a lookup that has
    to go to the network is the longest block in a request. Doing it here means
    the caller decides where that cost lands, and a caller with a warm resolver
    cache does not pay it at all.
    """
    var addresses = resolver.lookup(host, port)
    if len(addresses) == 0:
        raise new_error(
            ErrorKind.CONNECT_ERROR,
            String("no addresses to try for ", host, ":", port),
        )
    return Race(addresses^, String(host, ":", port))


def race_to_host(
    mut resolver: Resolver,
    host: StringSpan,
    port: UInt16,
    deadline: Deadline,
) raises -> TcpStream:
    """`connect_to_host` for callers that have a runner and no other work.

    Blocks the caller, because `_run` does. What it does not do is block a
    thread per attempt, so this is the right entry point for a synchronous
    caller that wants the async race and the wrong one for a caller that already
    has coroutines in flight. That caller should hold its own `Race` and drive
    `race_connect` in a task group beside its other work.
    """
    var race = start_race(resolver, host, port)
    _run(race_connect(Pointer(to=race), deadline))
    try:
        return race.take_stream()
    except e:
        # Every address failed. On a host that worked before, the likeliest
        # reason is an answer that has gone stale, so the next attempt gets a
        # fresh lookup rather than the same list back.
        resolver.forget(host, port)
        raise e
