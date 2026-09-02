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
# copy. docs/async.md says which ones, and why the second copy is generated
# from the sync one rather than typed by hand.

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
