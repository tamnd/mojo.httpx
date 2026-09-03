"""Tests for the staggered connect race run on coroutines.

The algorithm is the same one `tests/unit/test_connect.mojo` covers and is not
retested here in full. What is tested is the part that is genuinely different:
that the race gives the same answers when the waiting is done by giving the
worker back, that a failure comes out of `take_stream` as an exception rather
than out of a coroutine as a raise, and, the reason the file exists, that more
connects can be in flight at once than there are workers.

The two tests that need an address which refuses get one from `dead_address()`,
which picks a different address on a host where the usual technique does not
produce a refusal. Its docstring says why.
"""

from std.runtime.asyncrt import TaskGroup, _run, parallelism_level
from std.testing import assert_equal, assert_false, assert_true

from httpx._exceptions import is_connect_error, is_connect_timeout
from httpx._ffi.netdb import SockAddr
from httpx._io.aio_connect import Race, race_connect, race_to_host, start_race
from httpx._io.deadline import Deadline, connect_deadline
from httpx._io.dns import Resolver

from tests.support.loopback import Loopback, dead_address


def test_aio_connect_a_single_working_address_connects() raises:
    var listener = Loopback()
    var race = Race([listener.addr], "loopback")
    _run(race_connect(Pointer(to=race), Deadline.after(5.0)))

    assert_false(race.failed())
    var stream = race.take_stream()
    assert_true(stream.is_open())
    assert_true(listener.has_pending())


def test_aio_connect_a_dead_first_address_does_not_stop_the_second() raises:
    """The point of the race, and the thing giving way must not break."""
    var listener = Loopback()
    var race = Race([dead_address(), listener.addr], "loopback")
    _run(race_connect(Pointer(to=race), Deadline.after(5.0)))

    var stream = race.take_stream()
    assert_true(stream.is_open())
    assert_true(listener.has_pending())


def test_aio_connect_a_working_first_address_wins_before_the_second_starts() raises:
    """The stagger survives the rewrite. Without it both listeners would see a
    connection, because starting an attempt costs nothing and the loop is now
    faster than it was."""
    var winner = Loopback()
    var spare = Loopback()
    var race = Race([winner.addr, spare.addr], "loopback")
    _run(race_connect(Pointer(to=race), Deadline.after(5.0)))

    assert_true(race.take_stream().is_open())
    assert_true(winner.has_pending())
    assert_false(spare.has_pending())


def test_aio_connect_every_address_failing_is_reported_not_raised() raises:
    """A coroutine cannot raise, so the failure has to survive as a value and
    become an exception only when synchronous code asks for the stream."""
    var race = Race([dead_address(), dead_address()], "all dead")
    _run(race_connect(Pointer(to=race), Deadline.after(5.0)))

    assert_true(race.failed())
    var raised = False
    try:
        _ = race.take_stream()
    except e:
        raised = True
        assert_true(is_connect_error(e))
        assert_true("all dead" in String(e))
    assert_true(raised)


def test_aio_connect_a_race_with_no_time_left_is_a_connect_timeout() raises:
    var listener = Loopback()
    var race = Race([listener.addr], "loopback")
    # The deadline is built out here rather than inline, because a coroutine
    # that makes a task group may not have an `Optional` in its frame and the
    # habit of keeping them out is cheaper than remembering which ones do.
    var no_time = connect_deadline(Optional[Float64](0.0))
    _run(race_connect(Pointer(to=race), no_time))

    var raised = False
    try:
        _ = race.take_stream()
    except e:
        raised = True
        assert_true(is_connect_timeout(e))
    assert_true(raised)
    # Keeps the listener open for the whole race. Mojo drops a value after its
    # last use, and a listener that closed first would turn the timeout being
    # tested for into a refusal.
    assert_true(listener.port > 0)


def test_aio_connect_by_name_resolves_and_then_races() raises:
    var listener = Loopback()
    var resolver = Resolver()
    var stream = race_to_host(
        resolver, "localhost", listener.port, Deadline.after(5.0)
    )

    assert_true(stream.is_open())
    assert_equal(resolver.cached_count(), 1)
    # Keeps the listener alive to the end of the test. Mojo drops a value after
    # its last use, and a listener dropped at the line that read its port would
    # have closed before anything connected to it.
    assert_true(listener.has_pending())


def test_aio_connect_a_name_whose_addresses_all_fail_is_forgotten() raises:
    """So the retry gets a fresh answer, the same as on the synchronous path."""
    var listener = Loopback()
    var port = listener.port
    listener.close()

    var resolver = Resolver()
    var raised = False
    try:
        _ = race_to_host(resolver, "localhost", port, Deadline.after(5.0))
    except e:
        raised = True
        assert_true(is_connect_error(e))
    assert_true(raised)
    assert_equal(resolver.cached_count(), 0)


def test_aio_connect_resolution_that_finds_nothing_raises_before_the_race() raises:
    """A name with no addresses is a failure the caller can be told about
    directly, because resolving happens in synchronous code on purpose."""
    var resolver = Resolver()
    var raised = False
    try:
        _ = start_race(resolver, "no.such.host.invalid", 80)
    except e:
        raised = True
        assert_true(is_connect_error(e))
    assert_true(raised)


def test_aio_connect_more_connects_at_once_than_there_are_workers() raises:
    """The claim the async race exists to make.

    Every race is started before any of them can finish, so each one has to give
    way at least once. If a waiting race held its worker, the ones past the
    worker count would not run until an earlier one finished, and the whole
    point of not blocking would be lost.
    """
    var count = parallelism_level() * 2
    assert_true(count > parallelism_level())

    var work = Work()
    for _ in range(count):
        var listener = Loopback()
        work.races.append(Race([listener.addr], "loopback"))
        work.listeners.append(listener^)

    _run(_all_of_them(Pointer(to=work), Deadline.after(5.0)))

    for i in range(count):
        assert_false(work.races[i].failed())
        assert_true(work.races[i].take_stream().is_open())
        assert_true(work.listeners[i].has_pending())


struct Work(Movable):
    """Every race the concurrency test has in flight, and what answers it.

    One struct rather than two lists passed separately, because two mutable
    pointers sharing one origin parameter are rejected as aliasing.

    Both lists are filled before any task starts and neither is resized
    afterwards, so a task holding an element by index is not racing a
    reallocation. Each task touches one index and no other.
    """

    var races: List[Race]
    var listeners: List[Loopback]

    def __init__(out self):
        self.races = List[Race]()
        self.listeners = List[Loopback]()


async def _all_of_them[
    w: MutOrigin
](work: Pointer[Work, w], deadline: Deadline):
    """Every race outstanding together, under one group.

    The deadline arrives as an argument rather than being built here. A
    coroutine that makes a `TaskGroup` may not have an `Optional` anywhere in
    its own frame, and `connect_deadline` takes one, so building it here would
    crash the compiler with no message at all.
    """
    var group = TaskGroup()
    for i in range(work[].races.__len__()):
        group.create_task(race_connect(Pointer(to=work[].races[i]), deadline))
    await group
