"""What Mojo's async actually does on the toolchain we pin, measured.

    pixi run probe-async

M6 opens with a go or no go rather than with code, and this is the evidence
behind it. Everything the milestone depends on is exercised here so that a
future toolchain changing one of these answers shows up as a probe that stopped
printing what it used to print, rather than as a redesign discovered halfway
through the milestone.

Some of what M6 ran into cannot be shown from a running program, because the
program does not build. Those are at the bottom as commented out cases with the
message each one produces, so that trying them again later is a matter of
uncommenting rather than of reconstructing them from a changelog.

Read the conclusions in docs/async.md. The short version is that Mojo 1.0.0 has
a task scheduler, which is more than the plan assumed, and no async I/O, which
is what actually constrains the design.
"""

from std.runtime.asyncrt import TaskGroup, _run, create_task, parallelism_level
from std.time import perf_counter_ns, sleep

comptime NAP = 0.25
"""Long enough that scheduling noise does not swamp it, short enough that the
whole probe is a few seconds."""

comptime YIELDS = 100000


async def add(a: Int, b: Int) -> Int:
    return a + b


async def nap() -> Int:
    """Work that blocks its thread, which is what a socket read is today."""
    sleep(NAP)
    return 1


async def nothing() -> Int:
    return 0


async def four_naps() -> Int:
    var a = create_task(nap())
    var b = create_task(nap())
    var c = create_task(nap())
    var d = create_task(nap())
    return await a + await b + await c + await d


async def eight_naps() -> Int:
    var a = create_task(nap())
    var b = create_task(nap())
    var c = create_task(nap())
    var d = create_task(nap())
    var e = create_task(nap())
    var f = create_task(nap())
    var g = create_task(nap())
    var h = create_task(nap())
    return (
        await a
        + await b
        + await c
        + await d
        + await e
        + await f
        + await g
        + await h
    )


async def waits_on_one() -> Int:
    """A coroutine whose whole job is to wait for another one.

    The question this answers is whether awaiting hands the worker back to the
    scheduler or sits on it. If it sits on it, nothing nested can ever run and
    a client built on tasks deadlocks the first time a request waits for a
    connection.
    """
    var inner = create_task(nap())
    return await inner


async def four_waiters() -> Int:
    var a = create_task(waits_on_one())
    var b = create_task(waits_on_one())
    var c = create_task(waits_on_one())
    var d = create_task(waits_on_one())
    return await a + await b + await c + await d


async def quiet_nap():
    """The same nap with no result, which is all a `TaskGroup` will take."""
    sleep(NAP)


async def grouped(count: Int):
    """A number of tasks not known until it runs, which `gather` needs.

    `create_task` cannot do this on its own. `Task` is not `Movable`, so there
    is no list of tasks to hold and no way to await a set of them one by one.
    `TaskGroup` is the way out, and the price is that it only takes coroutines
    returning nothing, so results have to be written somewhere both sides can
    reach rather than returned.
    """
    var group = TaskGroup()
    for _ in range(count):
        group.create_task(quiet_nap())
    await group


struct Flat(ImplicitlyCopyable, Movable):
    """A result with scalar fields and nothing else.

    Everything a coroutine writes from inside a suspending loop has to look like
    this. A field whose type is itself a struct fails to lower, which is case
    three at the bottom. `httpx._io.aio.Outcome` is this shape for that reason.
    """

    var count: Int
    var reason: UInt8

    def __init__(out self, count: Int):
        self.count = count
        self.reason = 0


async def suspends_often[r: MutOrigin](times: Int, result: Pointer[Flat, r]):
    """A coroutine that gives way `times` times and reports through a pointer.

    Two things at once. It suspends inside a loop, which is what `_run` and
    `TaskGroup.create_task` allow and what `await` does not, and it writes its
    answer through a pointer, which is what `TaskGroup.create_task` requires
    since it only takes coroutines that return nothing.
    """
    var done = 0
    result[] = Flat(0)
    while done < times:
        done += 1
        result[] = Flat(done)
        _ = await create_task(nothing())


async def many_suspending[o: MutOrigin](outs: Pointer[List[Flat], o], times: Int):
    var group = TaskGroup()
    for i in range(outs[].__len__()):
        group.create_task(suspends_often(times, Pointer(to=outs[][i])))
    await group


async def suspends_once[r: MutOrigin](result: Pointer[Int, r]):
    result[] = 1
    _ = await create_task(nothing())
    result[] = 2


async def awaits_one[r: MutOrigin](result: Pointer[Int, r]):
    """The most a coroutine may await and still work. See case two below."""
    await suspends_once(result)


struct Sink(Movable):
    """Owned memory a coroutine is allowed to fill, because it is not its own.

    A `List` and a `String` are exactly what a coroutine may not hold in its own
    frame across a suspension. Put them behind a pointer and mutate them through
    ordinary synchronous methods and it works, which is the shape
    `httpx._proto.h1.aio` is built out of.
    """

    var bytes: List[UInt8]
    var name: String

    def __init__(out self):
        self.bytes = List[UInt8]()
        self.name = String()

    def took(mut self, value: UInt8):
        self.bytes.append(value)

    def named(mut self, round: Int):
        """Takes the number rather than the text on purpose.

        Building the `String` here means it is allocated in this frame, not in
        the coroutine's. Passing `String("round ", n)` in from the coroutine is
        the same mistake as the local list, one type along.
        """
        self.name = String("round ", round)


async def fills_through_a_pointer[
    o: MutOrigin
](sink: Pointer[Sink, o], times: Int):
    """Two sequential suspending loops, both writing owned memory in place.

    Two loops rather than one because a coroutine that suspends in a loop twice
    over is a thing the driver needs, once to write a request and once to read
    the answer, and it was worth checking rather than assuming.
    """
    var done = 0
    while done < times:
        sink[].took(UInt8(done))
        done += 1
        _ = await create_task(nothing())
    done = 0
    while done < times:
        sink[].named(done)
        done += 1
        _ = await create_task(nothing())


async def nested_suspending_loops[
    o: MutOrigin
](sink: Pointer[Sink, o], outer: Int, inner: Int):
    """A suspending loop inside another loop. Also allowed."""
    var i = 0
    while i < outer:
        var j = 0
        while j < inner:
            sink[].took(UInt8(i * inner + j))
            j += 1
            _ = await create_task(nothing())
        i += 1


async def both_at_once[
    o: MutOrigin
](sinks: Pointer[List[Sink], o], times: Int):
    """Several of the above outstanding together, each on its own element."""
    var group = TaskGroup()
    for i in range(sinks[].__len__()):
        group.create_task(
            fills_through_a_pointer(Pointer(to=sinks[][i]), times)
        )
    await group


async def quiet():
    """A coroutine that returns nothing, so awaiting it leaves nothing behind."""
    pass


async def give_way():
    """Hand the worker back without landing a task handle in the caller's frame.

    Not interchangeable with `_ = await create_task(nothing())`, which is what
    every probe above uses. The discard looks like it throws the handle away and
    it does, but the handle is still a value in the awaiting coroutine's frame,
    and the frame has to stay flat. In the simple shapes above that costs
    nothing. In `three_guarded_stages` below, swapping this for the discard form
    is the difference between a probe that prints its answer and one that fails
    to lower with `Instruction does not dominate all uses`.

    This is `httpx._io.aio.yield_now`, copied rather than imported so that the
    probe still builds against a toolchain the library does not.
    """
    await create_task(quiet())


struct Stages(Movable):
    """A sink whose progress can be asked about without touching its memory.

    `stage` counts the passes of the loop running now and `abandoned` is the
    only thing the guards between loops look at. Both are scalars sitting beside
    the list rather than being derived from it, and that is the whole
    workaround: a guard that reads `len(self.bytes)` instead does not lower.
    """

    var bytes: List[UInt8]
    var stage: Int
    var abandoned: Int

    def __init__(out self):
        self.bytes = List[UInt8]()
        self.stage = 0
        self.abandoned = 0

    def took(mut self, value: UInt8):
        self.bytes.append(value)


def stage_step[
    o: MutOrigin
](work: Pointer[Stages, o], value: UInt8, times: Int) -> Int:
    """One pass of a stage. Zero while there is more to do, one at the end."""
    if work[].stage >= times:
        work[].stage = 0
        return 1
    work[].took(value)
    work[].stage += 1
    return 0


def under_budget[o: MutOrigin](work: Pointer[Stages, o]) -> Bool:
    """A guard reading a scalar field, which is the form that survives.

    Written as `len(work[].bytes) < 100` it fails to lower instead, and moved
    inline into the coroutine it crashes the compiler outright with no message.
    Case seven at the bottom has both.
    """
    return work[].abandoned == 0


async def three_guarded_stages[
    o: MutOrigin
](work: Pointer[Stages, o], times: Int):
    """Three suspending loops with a guarded return before each.

    The exact shape the connection pool needs, which is why it is a probe rather
    than something taken on faith: a connect that may not be necessary, then a
    write, then a read, with a chance to give up between each pair.
    """
    if not under_budget(work):
        return
    while stage_step(work, UInt8(1), times) == 0:
        await give_way()
    if not under_budget(work):
        return
    while stage_step(work, UInt8(2), times) == 0:
        await give_way()
    if not under_budget(work):
        return
    while stage_step(work, UInt8(3), times) == 0:
        await give_way()


async def skips_the_first_loop[
    o: MutOrigin
](work: Pointer[Stages, o], times: Int, connect: Bool):
    """A suspending loop that an `if` may skip, followed by another.

    Also what the pool needs, because a request served from an idle connection
    does no connecting at all and must not pay a scheduler round trip to find
    that out.
    """
    if connect:
        while stage_step(work, UInt8(1), times) == 0:
            await give_way()
    while stage_step(work, UInt8(2), times) == 0:
        await give_way()


async def spin(times: Int) -> Int:
    """Round trips through the scheduler and nothing else.

    This is the price of a coroutine giving way and being picked up again,
    which is the price of every poll in a reactor that has no way to be woken.
    """
    var total = 0
    for _ in range(times):
        total += await create_task(nothing())
    return total


def _ms(started: Int) -> Int:
    return (perf_counter_ns() - started) // 1000000


def main() raises:
    print("=== the toolchain")
    print("    parallelism_level:", parallelism_level())
    print()

    print("=== a coroutine runs to completion")
    var sum = _run(add(1, 2))
    if sum != 3:
        raise Error(String("await add(1, 2) gave ", sum))
    print("    _run(add(1, 2)) is", sum)
    print()

    print("=== tasks run at the same time")
    var started = perf_counter_ns()
    var four = _run(four_naps())
    var four_ms = _ms(started)
    print("    four", NAP, "second naps returned", four, "in", four_ms, "ms")

    started = perf_counter_ns()
    var eight = _run(eight_naps())
    var eight_ms = _ms(started)
    print("    eight of them returned", eight, "in", eight_ms, "ms")
    print(
        "    if the second is about twice the first, blocking work is capped at"
    )
    print("    parallelism_level and the pool is a CPU pool, not an I/O pool")
    print()

    print("=== awaiting hands the worker back")
    started = perf_counter_ns()
    var nested = _run(four_waiters())
    var nested_ms = _ms(started)
    print("    four coroutines each awaiting one nap:", nested, "in", nested_ms, "ms")
    print("    one nap's worth means the waiters did not hold their workers")
    print()

    print("=== a count that is not known until it runs")
    started = perf_counter_ns()
    _run(grouped(8))
    print("    eight through a TaskGroup in", _ms(started), "ms")
    print("    same shape as the eight above, so a group schedules the same way")
    print()

    print("=== a coroutine may suspend as often as it likes under a group")
    var outs = List[Flat]()
    for _ in range(12):
        outs.append(Flat(0))
    _run(many_suspending(Pointer(to=outs), 50))
    var short = 0
    for i in range(12):
        if outs[i].count != 50:
            short += 1
    print("    twelve tasks suspending fifty times each, on", parallelism_level(), "workers")
    print("   ", short, "of them came up short, and it has to be zero")
    print("    this is the only concurrency shape that works, so the loop uses it")
    print()

    print("=== a coroutine that is awaited may suspend once, and only once")
    var once = 0
    _run(awaits_one(Pointer(to=once)))
    print("    one suspension through an await gave", once, "and should give 2")
    print("    two suspensions compiles and hangs forever, which is case two")
    print()

    print("=== owned memory, as long as it is not the coroutine's own")
    var sink = Sink()
    _run(fills_through_a_pointer(Pointer(to=sink), 4))
    print("    bytes:", len(sink.bytes), "and it has to be 4")
    print("    name:", sink.name, "and it has to be round 3")
    print("    the same list as a local comes back empty and says nothing, case five")
    print()

    print("=== a suspending loop inside another one")
    var nested_sink = Sink()
    _run(nested_suspending_loops(Pointer(to=nested_sink), 3, 4))
    print("    bytes:", len(nested_sink.bytes), "and it has to be 12")
    print()

    print("=== several of those at once")
    var sinks = List[Sink]()
    for _ in range(6):
        sinks.append(Sink())
    _run(both_at_once(Pointer(to=sinks), 4))
    var wrong = 0
    for i in range(6):
        if len(sinks[i].bytes) != 4:
            wrong += 1
    print("    six of them on", parallelism_level(), "workers,", wrong, "came up short")
    print()

    print("=== three suspending loops with a guarded return before each")
    var staged = Stages()
    _run(three_guarded_stages(Pointer(to=staged), 4))
    print("    bytes:", len(staged.bytes), "and it has to be 12")
    print("    the same guard reading len() instead of a counter does not lower")
    print()

    print("=== a suspending loop an `if` may skip, followed by another")
    var skipped = Stages()
    _run(skips_the_first_loop(Pointer(to=skipped), 4, False))
    print("    skipping the first gave", len(skipped.bytes), "and it has to be 4")
    var both = Stages()
    _run(skips_the_first_loop(Pointer(to=both), 4, True))
    print("    taking it gave", len(both.bytes), "and it has to be 8")
    print()

    print("=== what a scheduler round trip costs")
    started = perf_counter_ns()
    var spun = _run(spin(YIELDS))
    var took = perf_counter_ns() - started
    print("   ", YIELDS, "yields gave", spun, "in", took // 1000000, "ms")
    print("    which is", took // YIELDS, "ns each")


# What does not compile, and why the milestone was written as a maybe:
#
#     def main() raises:
#         var c = add(1, 2)     # never awaited
#
#     error: 'c' abandoned without being explicitly destroyed: type 'Coroutine'
#     does not conform to 'Deinitable' and must be explicitly destroyed
#
# A coroutine is linear. It cannot be dropped, so it cannot be stored anywhere
# that might drop it, which rules out a field, a List and every hand written
# queue. `create_task` is the only way to park one, and it is the scheduler's.
#
# The other thing that does not compile, and the one that decides how much code
# M6 has to touch. Function colours are strict in both directions:
#
#     trait Reader:
#         def read(mut self) -> Int: ...
#
#     struct Async(Reader):
#         async def read(mut self) -> Int: ...
#
#     note: no 'read' candidates have type 'def(mut self: Async) thin -> Int'
#
# and declaring the trait method `async def` instead rejects the plain `def`
# with the same message the other way round. So one `ByteStream` trait cannot
# cover both a socket and an async socket, and the driving loops get a second
# copy. docs/async.md says which ones, and why that second copy is written by
# hand over a shared sans-io machine rather than generated from the first.

# Case two. Coroutines barely compose, and the two ways of getting it wrong fail
# very differently.
#
#     async def twice[r: MutOrigin](result: Pointer[Int, r]):
#         await create_task(nothing())
#         result[] = 1
#         await create_task(nothing())
#         result[] = 2
#
#     async def outer[r: MutOrigin](result: Pointer[Int, r]):
#         await twice(result)
#
# compiles cleanly and then never terminates. Nothing prints, no worker is
# busy, and there is nothing to attach a debugger to. It is the reason no
# waiting function in httpx._io awaits another one.
#
# The same thing with the suspension inside a loop is at least loud:
#
#     async def looping[r: MutOrigin](n: Int, result: Pointer[Int, r]):
#         var i = 0
#         while i < n:
#             i += 1
#             result[] = i
#             await create_task(nothing())
#
#     async def outer[r: MutOrigin](result: Pointer[Int, r]):
#         await looping(3, result)
#
#     cannot guarantee tail call due to mismatched return types
#       musttail call void %0(ptr %1)
#     error: failed to lower module to LLVM IR for archive compilation
#
# Both are fine when driven by `_run` or `TaskGroup.create_task` rather than by
# `await`, which is what the probe above demonstrates.
#
# Case three. A value written from inside a suspending loop has to be flat.
#
#     struct Inner(ImplicitlyCopyable, Movable):
#         var v: UInt8
#
#     struct Outer(ImplicitlyCopyable, Movable):
#         var count: Int
#         var inner: Inner            # a field that is itself a struct
#
#     async def spin[r: MutOrigin](n: Int, result: Pointer[Outer, r]):
#         var i = 0
#         while True:
#             if i >= n:
#                 result[] = Outer(i)
#                 break
#             if i == 99:
#                 result[] = Outer(-1)
#                 break
#             i += 1
#             await create_task(nothing())
#
#     error: operand #0 does not dominate this use
#             self.v = v
#     note: operand defined here (op in a child region)
#             self.inner = Inner(0)
#
# One write site survives it and two do not, which is what made this look like
# five unrelated bugs before it was reduced. A `String` anywhere in the value
# fails the same way. `httpx._io.aio.Outcome` stores an unwrapped `UInt32` and
# `UInt8` instead of an `ErrorKind` and an `Op` for exactly this reason.
#
# Case four. A `Span` cannot be resliced in a suspending loop.
#
#     async def slicer[d: ImmOrigin, r: MutOrigin](
#         data: Span[UInt8, d], result: Pointer[Int, r]
#     ):
#         var sent = 0
#         while sent < data.__len__():
#             var rest = data[sent:]      # crashes the compiler
#             sent += rest.__len__()
#             result[] = sent
#             await create_task(nothing())
#
# There is no error message, only a stack dump from the compiler itself. It is
# why `TcpStream.try_write` takes an offset rather than a caller sliced span.
#
# Case five. A coroutine cannot raise, and cannot catch one either.
#
#     async def fails() raises:
#         raise Error("no")
#
#     _run(fails())
#
#     note: no '_run' candidates match, argument has type 'RaisingCoroutine'
#
# and wrapping it does not help, because an `await` inside a `try` fails to
# lower. Synchronous raising code called from inside a coroutine is fine, as
# long as no `await` sits in the `try`, which is what `finish_connect` relies
# on. All of it is why httpx._io.aio reports failure as an `Outcome` and turns
# it back into an exception on the synchronous side.

# Case five. A coroutine's own frame has to stay flat, and the loud half of that
# is the nested struct above. The quiet half is owned memory, which is worse:
#
#     async def collects[r: MutOrigin](result: Pointer[Int, r], times: Int):
#         var bytes = List[UInt8]()
#         var done = 0
#         while done < times:
#             bytes.append(UInt8(done))
#             done += 1
#             await give_way()
#         result[] = len(bytes)
#
# Sometimes this fails to lower with "'pop.store' op failed to verify that
# pointer element type". Sometimes it compiles and `result[]` comes back zero.
# Four appends, zero bytes, no diagnostic. In a response body reader that is a
# download that silently truncates, which is the reason this probe exists at all
# and the reason the driver keeps every buffer behind a pointer.
#
# A `String` returned into the frame and an `Error` bound by `except` fail the
# same way, with "operand #0 does not dominate this use". So does a field read
# through two levels of struct, `conn[].fd()` where `fd` forwards to an inner
# stream, which is why the driver hoists nothing and calls a synchronous helper
# for every step instead.

# Case six, and the one that cost the most to find because it says nothing at
# all. A coroutine that makes a `TaskGroup` may not have an `Optional` anywhere
# in its own frame:
#
#     async def _one[o: MutOrigin](p: Pointer[Int, o]):
#         var v = Optional[Int](5)
#         _ = v
#         var group = TaskGroup()
#         group.create_task(_fake(p))
#         await group
#
# That is the whole reproducer. The `Optional` is dead before the group is made
# and is never mentioned again, and the compiler still goes down with a stack
# dump and no message. Drop the group and the same `Optional` is fine. Drop the
# `Optional` and the same group is fine.
#
# It is easy to hit without ever typing `Optional`, because the conversion for an
# `Optional` parameter happens in the caller's frame. `write_deadline(5.0)` takes
# `Optional[Float64]`, so writing
#
#     group.create_task(exchange(conn, request, result, write_deadline(5.0), ...))
#
# crashes, and building the deadline in synchronous code and passing it in as an
# argument does not. Every test that drives more than one exchange takes its
# deadlines as arguments for this reason and no other.

# Case seven. A guard between two suspending loops may only read a scalar.
# `three_guarded_stages` above is the shape that works. These two are what it
# was reduced from, and both of them start out looking like a compiler that has
# stopped liking `if`.
#
# Reading the length of a list the coroutine does not even own is enough:
#
#     def under_budget[o: MutOrigin](work: Pointer[Stages, o]) -> Bool:
#         return len(work[].bytes) < 100
#
#     std/collections/list.mojo:767:20: error: operand #0 does not dominate
#     this use
#     note: called from  len(work[].bytes) < 100
#
# and moving the same test inline into the coroutine, which reads like the
# obvious simplification, takes the compiler down with a stack dump and nothing
# else:
#
#     async def staged[o: MutOrigin](work: Pointer[Stages, o], times: Int):
#         while stage_step(work, UInt8(1), times) == 0:
#             await give_way()
#         if work[].abandoned != 0:      # crashes, even though the field is a scalar
#             return
#         while stage_step(work, UInt8(2), times) == 0:
#             await give_way()
#
# So the rule has two halves. The dereference belongs in a synchronous helper
# the coroutine calls, never in the coroutine itself, and what the helper reads
# has to be a scalar field rather than anything derived from owned memory. A
# count kept beside a list satisfies both, which is why `Stages` has one, and it
# is why `pooled_exchange` is told whether it has to connect rather than working
# it out from the race it was handed.
#
# The suspension form matters here too. Every probe above gives way with
# `_ = await create_task(nothing())` and it makes no difference to them, but in
# this shape the discarded task handle is one more value in the frame and it
# fails to lower with `Instruction does not dominate all uses`. `give_way` keeps
# the handle in its own frame instead. That is why `httpx._io.aio.yield_now`
# exists as a function rather than as a line repeated at each call site.
#
# The next four came out of the connection pool, which is the longest coroutine
# in the library and the first one that wanted three loops. All four are things
# that work in a shorter coroutine and stop working in that one, so none of them
# would have been found by making the probes above bigger.
#
# Case eight. A coroutine may call a given function once after a suspension and
# not twice. The pool's exchange started out shaped like the driver's, leaving
# early on each thing that could go wrong:
#
#     async def pooled[...](...):
#         while _race_step(race, connect_at) == RACING:
#             await give_way()
#         if not _adopt_winner(race, conn, result):
#             _abandon(conn)
#             return
#         if not _prepare(conn, request, result, form):
#             _abandon(conn)
#             return
#         ...
#
#     -:0:0: error: invalid value index: 75
#     -:0:0: note: in bytecode version 6 produced by: MLIR24.0.0git
#
# Either `_abandon` on its own compiles and runs. Two different functions in
# those same two places compile and run. It is the second call to the same one
# that does it, and only when both are after a suspension, which is why the
# driver in `httpx/_proto/h1/aio.mojo` has two `_abandon` calls and is fine: its
# first one is before the first loop. The pool has one exit instead, and a
# failure there makes every later step do nothing rather than leaving.
#
# Case nine. Nothing may stand between a second suspending loop and a third.
# Three loops in a row are fine, which is case seven. Three loops with one call
# in the second gap are not:
#
#     while _race_step(race, connect_at) == RACING:
#         await give_way()
#     _load_request(conn, request, result, form)   # this gap is fine
#     while _write_call(conn, result, write_at, rounds) == _WAIT:
#         await give_way()
#     _turn_around(conn, result)                   # this one crashes
#     while _read_call(conn, result, read_at, rounds) == _WAIT:
#         await give_way()
#
# A stack dump and no message. It is not what the call does: a call taking
# nothing but pointers already in the frame and returning nothing is enough, and
# the same call moved up into the first gap is fine. So `pooled_exchange` has
# two loops rather than three, and sending and receiving are one step that knows
# from the connection which of the two it is doing.
#
# Case ten. A value a coroutine throws away is still a value in its frame:
#
#     while _write_call(conn, result, write_at, rounds) == _WAIT:
#         await give_way()
#     _ = _start_reading(conn, result)   # crashes
#     _settle(conn, result)              # returns nothing, and is fine
#
# Same position, same arguments, and the difference is that one of them has an
# answer nobody wants. The discard has to happen inside a helper's frame. This
# is case seven's discarded task handle again, and it earns its own case because
# `_ =` looks like nothing at all.
#
# Case eleven, and the only one of the four that is about a caller rather than
# about a coroutine's own shape. Two `create_task` calls in a row have to be
# inside loop bodies:
#
#     var group = TaskGroup()
#     group.create_task(pooled_exchange(...))       # on its own, fine
#     group.create_task(_answer_one(work, ...))     # the pair crashes
#     await group
#
# A stack dump and no message again. Hoisting the arguments into locals first
# does not help. Wrapping each call in a `for` of one iteration does, which is
# what `tests/unit/test_aio_pool.mojo` does to start one request and the one
# server that answers it. The test in the same file that starts a request per
# worker writes real loops and never hit this, which is what pointed at the loop
# rather than at anything in the arguments.

# Not a case, because it is a runtime that does not offer something rather than
# a compiler that refuses something it should accept. A `TaskGroup` cannot be
# cancelled:
#
#     var group = TaskGroup()
#     group.create_task(_nothing())
#     group.cancel()
#
#     error: 'TaskGroup' value has no attribute 'cancel'
#
# Nor `shutdown`, `stop`, `abort`, `join` or `is_cancelled`, all tried the same
# way. The stdlib ships compiled, so there is no source to read and the only way
# to ask what a type has is to name a method and see what the compiler says.
# Together with a `Task` not being `Movable` and a `Coroutine` being linear,
# that is why the library has no cancel: nothing that stands for a request in
# flight can be handed out, and a group that has started cannot be told to stop.
# `docs/async.md` writes down what stops a request instead.
