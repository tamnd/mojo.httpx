"""What Mojo's async actually does on the toolchain we pin, measured.

    pixi run probe-async

M6 opens with a go or no go rather than with code, and this is the evidence
behind it. Everything the milestone depends on is exercised here so that a
future toolchain changing one of these answers shows up as a probe that stopped
printing what it used to print, rather than as a redesign discovered halfway
through the milestone.

The one thing that cannot be shown from a running program is the thing that
does not compile. `Coroutine` does not conform to `Deinitable`, so a coroutine
cannot be dropped, stored in a struct field or put in a `List`, and a file that
tries fails to build rather than failing at runtime. There is a commented out
case at the bottom for anyone who wants to see the message.

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
