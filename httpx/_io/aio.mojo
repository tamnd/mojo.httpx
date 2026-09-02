"""Waiting without holding a worker, which is the whole of the async loop.

Mojo 1.0.0 has a task scheduler and no async I/O. Nothing in
`std.runtime.asyncrt` lets our own code finish a task when a descriptor becomes
readable, so a coroutine waiting on a socket cannot be woken by the socket. It
has to go and look. docs/async.md has the measurements this is built on.

Looking is cheap. A `poll` with a zero timeout and a trip through the scheduler
come to roughly two microseconds together, so a coroutine can look thousands of
times in the time one network round trip takes. That is what makes polling a
workable answer here rather than a confession.

The wait has two phases, because the two costs pull in opposite directions. In
the hot phase the descriptor is checked with a zero timeout and the worker is
handed straight back, which notices a ready socket within microseconds and burns
a core doing it. In the cold phase the check is a `poll` with a one millisecond
timeout, which is the kernel doing the waiting instead of us and costs nothing
measurable. A reply from a fast server arrives inside the hot phase. A wait on a
slow one falls through to the cold phase after about a tenth of a millisecond
and stays there until something happens.

There is no shared reactor and no registration table, which is a deliberate
departure from the design sketched in docs/async.md. One shared poll would learn
about every ready descriptor in a single syscall, but learning is not the slow
part. A waiter still has to be handed a worker before it can act on the news,
and being handed a worker is exactly what the per waiter poll is already waiting
for. The table would buy nothing and would cost a lock, a wake up path, and an
origin parameter threaded through every async type in the library.

What the missing wake up does cost is a rotation. Only `parallelism_level()`
waiters sit inside a cold poll at once, so with more waiters than workers each
one gets its turn periodically rather than continuously, and the delay before a
ready socket is noticed is the number of waiters divided by the number of
workers, times the cold slice. Sixteen waiters on four workers is four
milliseconds. That is the price of the missing wake up, written down here so
that nobody has to rediscover it in a profile.

Four properties of Mojo 1.0.0 coroutines shape everything below, and none of
them is a style choice. `tools/probe/async.mojo` holds a reproducer for each, so
that a later toolchain can be checked against them rather than guessed at.

A coroutine cannot raise. `create_task`, `TaskGroup.create_task` and `_run` all
refuse a `RaisingCoroutine`, and the one shape that would let a non raising
wrapper catch on their behalf, an `await` of a raising coroutine inside a `try`,
fails to compile. So every async function in this library reports failure as a
value, and the conversion back into an exception happens on the synchronous side
of the boundary where a `raise` is allowed again.

Coroutines barely compose. A coroutine that is `await`ed may suspend exactly
once, and not inside a loop. Suspending twice compiles and then hangs forever at
run time, which is worse than a compile error because nothing points at the
cause. Suspending inside a loop is at least loud, and fails to lower with
"cannot guarantee tail call due to mismatched return types". A coroutine handed
to `_run` or to `TaskGroup.create_task` has no such limit and may suspend as
often as it likes, so waiting works and layering waits does not. That is why
every waiting function here is flat: each one contains its own poll loop rather
than awaiting a shared one, and the few lines that get repeated as a result are
the price of the loop existing at all. docs/async.md says what this costs the
client above.

Anything a coroutine writes from inside a suspending loop has to be flat. A
value whose type has a field that is itself a struct, or that owns memory, fails
to lower with "operand #0 does not dominate this use" pointing into the nested
constructor. That is the whole reason `Outcome` stores an unwrapped `UInt32`
rather than an `ErrorKind` and a `UInt8` rather than an `Op`, and the reason
there is one result type instead of a separate one per operation. It is not a
performance argument and it should be deleted the day the compiler stops caring.

A `Span` cannot be resliced in a suspending loop. `data[sent:]` crashes the
compiler outright, which is why `TcpStream.try_write` takes an offset instead.

One more thing is a rule of the runtime rather than a bug: `TaskGroup.create_task`
only accepts a coroutine that returns nothing. A wait that cannot go into a task
group is a wait that cannot run alongside another one, so every coroutine here
returns nothing and reports through a `result` pointer. The pointer also puts
each answer in memory the frame does not own, which is where a flat value is
safest.
"""

from std.ffi import c_int, c_uint
from std.runtime.asyncrt import create_task

from httpx._exceptions import ErrorKind, new_error
from httpx._ffi.c import errno
from httpx._ffi.errno import (
    Op,
    errno_message,
    interrupted,
    kind_for_errno,
)
from httpx._ffi.socket import POLLNVAL, PollFd, poll
from httpx._io.deadline import Deadline, timeout_message

comptime HOT_ROUNDS = 64
"""How many times a waiter looks before it starts letting the kernel wait.

Sixty four rounds is about a tenth of a millisecond of looking, which covers a
loopback server and a warm connection to a nearby host, and is short enough that
a wait on anything slower stops burning a core almost at once.
"""

comptime COLD_SLICE_MS = 1
"""How long one cold `poll` may block the worker it is running on.

Every millisecond spent here is a millisecond another waiter cannot have, so
this is the rotation quantum and not a latency target. One millisecond keeps the
rotation tolerable up to a few hundred concurrent waits while costing at most a
few thousand wakeups a second across the whole pool, which does not show up in a
profile.
"""


struct Outcome(ImplicitlyCopyable, Movable):
    """What an async wait or transfer came back with, in registers only.

    One flat type for every async result, and not because a readiness, a byte
    count and an error would have been hard to write separately. A struct with a
    struct shaped field in it fails to lower when a coroutine writes it from
    inside a loop that suspends, so an outcome has scalar fields and nothing
    else, which rules out holding an `ErrorKind`, an `Op` or a `String`, and
    rules out one result type holding another. `tools/probe/async.mojo` has the
    reproducer. Everything richer is built on the synchronous side of the
    boundary by `check` and `message`.

    Not holding a `String` also means the wait path allocates nothing, which is
    a real benefit, but it is not the reason.
    """

    var count: Int
    """Bytes moved, or one from a wait that found its descriptor ready.

    Zero from a read is end of stream and not a failure. Whether that is a
    complete message depends on the framing and the HTTP layer is what knows,
    which is why it comes back as a count. `TcpStream.read` reports it the same
    way.

    A wait has nothing to count, so it says yes with a one and no with a zero,
    and `is_ready` reads this rather than there being a field of its own. A
    second field would be a struct with two ways to say the same thing, and it
    would have to agree with the first.
    """

    var reason: UInt8
    """Why it failed, or `NONE`. See the constants below."""

    var kind_value: UInt32
    """The `ErrorKind` to raise, unwrapped. `kind` puts it back together."""

    var code: Int32
    """The errno, or zero when the failure did not come from a syscall."""

    var op_value: UInt8
    """The `Op` that failed, unwrapped. `op` puts it back together."""

    comptime NONE = UInt8(0)
    """Nothing went wrong.

    A reason of its own rather than a reserved `kind_value`, because
    `ErrorKind.UNKNOWN` is a kind a genuine failure can carry and reusing it
    would make one real error indistinguishable from success.
    """

    comptime ERRNO = UInt8(1)
    comptime TIMEOUT = UInt8(2)
    comptime NOT_OPEN = UInt8(3)

    def __init__(out self, count: Int):
        """A wait or a transfer that went fine, having moved `count` bytes."""
        self.count = count
        self.reason = Self.NONE
        self.kind_value = ErrorKind.UNKNOWN.value
        self.code = Int32(0)
        self.op_value = Op.POLL.value

    def __init__(out self, reason: UInt8, kind: ErrorKind, code: c_int, op: Op):
        self.count = 0
        self.reason = reason
        self.kind_value = kind.value
        self.code = Int32(code)
        self.op_value = op.value

    @staticmethod
    def ready() -> Self:
        """A wait that found the descriptor ready."""
        return Self(1)

    @staticmethod
    def waiting() -> Self:
        """A wait that found nothing yet, which is not a failure."""
        return Self(0)

    @staticmethod
    def from_errno(code: c_int, op: Op) -> Self:
        """A failed syscall, worded later by `errno_message`.

        Goes through the same function the synchronous path raises from, so the
        same failure reads identically whichever client hit it.
        """
        return Self(Self.ERRNO, kind_for_errno(code, op), code, op)

    @staticmethod
    def from_deadline(deadline: Deadline, op: Op) -> Self:
        """The timeout `Deadline.check` would have raised, as a value."""
        return Self(Self.TIMEOUT, deadline.kind, c_int(0), op)

    @staticmethod
    def not_open(op: Op) -> Self:
        """A poll of a descriptor this process does not have open."""
        return Self(Self.NOT_OPEN, ErrorKind.READ_ERROR, c_int(0), op)

    def failed(self) -> Bool:
        """Whether there is anything here to report.

        A method rather than a field because the answer is already in `reason`,
        and a second copy of it is a thing that can disagree with the first.
        """
        return self.reason != Self.NONE

    def is_ready(self) -> Bool:
        """Whether a wait found what it was waiting for. See `count`."""
        return self.count > 0

    def kind(self) -> ErrorKind:
        return ErrorKind(self.kind_value)

    def op(self) -> Op:
        return Op(self.op_value)

    def message(self, what: StringSpan) -> String:
        """The wording of the failure, assembled where a `String` is safe.

        `what` is the operation in the caller's terms, like `read from
        example.com:443`. The coroutine would only have been carrying a copy of
        something the caller already has, so it does not carry one.

        Both wordings come from the functions the synchronous path raises
        through, so a failure reads the same whichever client hit it.
        """
        if self.reason == Self.ERRNO:
            return errno_message(c_int(self.code), self.op(), what)
        if self.reason == Self.TIMEOUT:
            return timeout_message(what)
        if self.reason == Self.NOT_OPEN:
            return String("polled a descriptor that is not open: ", what)
        return String("no failure: ", what)

    def check(self, what: StringSpan) raises -> Int:
        """The count, raising instead if this outcome is a failure.

        Called from synchronous code, which is the only place a `raise` is
        allowed once a coroutine is involved. This is the boundary the whole
        design is built around: numbers on the async side, exceptions on the
        other.
        """
        if self.failed():
            raise new_error(self.kind(), self.message(what))
        return self.count


async def _nothing():
    """A coroutine with no body, so that there is something to await."""
    pass


async def yield_now():
    """Hand the worker back to the scheduler and ask for it again.

    `create_task` puts the empty coroutine on the run queue and the `await`
    parks this one behind it, so every other runnable coroutine gets a turn
    first. Mojo 1.0.0 has no `yield` and nothing in `asyncrt` that parks a
    coroutine on its own, so this is the only way to give way.
    """
    await create_task(_nothing())


def slice_for(rounds: Int) -> Int:
    """How long the `rounds`th look at a descriptor may block for.

    Zero while the wait is still hot, one millisecond once it is not. A function
    rather than a line at each call site because every waiter has to switch over
    at the same point for the rotation cost above to hold.
    """
    return 0 if rounds < HOT_ROUNDS else COLD_SLICE_MS


async def wait_ready[
    r: MutOrigin
](fd: c_int, events: Int16, deadline: Deadline, result: Pointer[Outcome, r],):
    """Wait for `fd` to be ready for `events`, giving way while waiting.

    The synchronous twin of this is `TcpStream._wait`, and the loops that call
    the two are otherwise identical. That is the whole shape of the async
    client: the same code, waiting differently.

    Nothing in the library awaits this, because nothing can. It suspends inside a
    loop, so it may only be driven by `_run` or `TaskGroup.create_task`, and the
    socket methods that need the same wait carry their own copy of the loop. It
    stays here as the one place the shape is written down and tested, and as the
    primitive for code that holds a bare descriptor and its own runner.

    The answer goes through `result` for the compiler reason in the module
    docstring. It is set to the timeout answer before the loop starts, so the
    only paths that have to write are the ones that found something.

    Takes no description of what is being waited for. The caller supplies that
    when it turns the answer back into an exception, which keeps the wait itself
    free of anything that owns memory.
    """
    var rounds = 0
    result[] = Outcome.waiting()
    while True:
        if deadline.expired():
            break
        var got = poll_slice(fd, events, deadline, slice_for(rounds))
        if got.is_ready() or got.failed():
            result[] = got^
            break
        rounds += 1
        await yield_now()


def poll_slice(
    fd: c_int, events: Int16, deadline: Deadline, slice_ms: Int
) -> Outcome:
    """One `poll`, for at most `slice_ms` and never beyond the deadline.

    Synchronous on purpose. This is the call that does the waiting, and it holds
    its worker while it waits, which is the point: the kernel is a cheaper place
    to wait than a loop of ours. The bound is what keeps the worker available to
    everybody else soon enough to matter.
    """
    var ms = deadline.remaining_ms()
    if ms > slice_ms:
        ms = slice_ms
    var fds = PollFd(fd, events, Int16(0))
    # One descriptor, so the address of the local is the whole array `poll`
    # expects, and it stays alive across the call.
    var rc = poll(Pointer(to=fds), c_uint(1), c_int(ms))
    if rc < 0:
        var code = errno()
        if interrupted(code):
            return Outcome.waiting()
        return Outcome.from_errno(code, Op.POLL)
    if rc == 0:
        return Outcome.waiting()
    if (fds.revents & POLLNVAL) != 0:
        return Outcome.not_open(Op.POLL)
    return Outcome.ready()
