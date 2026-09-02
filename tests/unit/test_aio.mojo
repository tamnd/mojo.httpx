"""Tests for the async loop and the socket that runs on it.

Two things are being pinned down here. The first is that the async stream moves
the same bytes and produces the same errors as the synchronous one, because the
whole design rests on the two being the same loop with a different wait, and a
difference in behaviour between them is a bug in the client that gets used less.

The second is the claim the loop exists to make: that more coroutines can be
waiting on sockets at once than there are workers to run them. That is the
property a thread pool fallback would not have had, so it gets a test of its own
rather than a paragraph in the docs.

Every coroutine is started here with `_run` or with `TaskGroup.create_task` and
never with a bare `await`, and each result comes back through a pointer. Those
are the only shapes Mojo 1.0.0 compiles, for the reasons in the docstring of
`httpx._io.aio`, so the tests are written the way a caller has to write it.

These are also the first tests in the suite that drive both ends of a connection
at the same time. Until Mojo had a scheduler there was no way to, and the
comment at the top of tests/support/loopback.mojo says as much.
"""

from std.ffi import c_int
from std.runtime.asyncrt import TaskGroup, _run, parallelism_level
from std.testing import assert_equal, assert_false, assert_true

from httpx._exceptions import (
    ErrorKind,
    is_connect_error,
    is_read_timeout,
)
from httpx._ffi.errno import Op
from httpx._ffi.socket import POLLIN, POLLOUT
from httpx._io.aio import Outcome, wait_ready
from httpx._io.aio_socket import AsyncTcpStream, finish_connect
from httpx._io.deadline import (
    Deadline,
    connect_deadline,
    read_deadline,
    write_deadline,
)
from httpx._io.socket import open_stream, start_connect

from tests.support.loopback import Loopback, Peer, dead_address

comptime BAD_FD = c_int(9999)
"""A descriptor number nothing in this process has open.

`poll` answers POLLNVAL for it, which is the one poll result that is neither
readiness nor a timeout. Picked rather than closing a real socket because a
closed number is immediately available for reuse and the test would then be
polling whatever got it next.
"""


def test_aio_an_outcome_carries_nothing_when_nothing_went_wrong() raises:
    var fine = Outcome(3)
    assert_false(fine.failed())
    assert_equal(fine.check("read from somewhere"), 3)


def test_aio_an_outcome_becomes_the_exception_it_describes() raises:
    """The subject of the message comes from the caller, not from the outcome.

    That is the whole point of the split: the coroutine carries five registers
    and the words are put together on the side of the boundary where a `raise`
    is allowed.
    """
    var failed = Outcome.from_deadline(
        Deadline.after(0.0, ErrorKind.READ_TIMEOUT), Op.READ
    )
    assert_true(failed.failed())
    var raised = False
    try:
        _ = failed.check("read from example.com:80")
    except e:
        raised = True
        assert_true(is_read_timeout(e))
        assert_true("read from example.com:80" in String(e))
    assert_true(raised)


def test_aio_a_failed_wait_reads_the_same_as_the_synchronous_one() raises:
    """A timeout is worded once, so both clients report it identically."""
    var deadline = Deadline.after(0.0, ErrorKind.READ_TIMEOUT)
    var failed = Outcome.from_deadline(deadline, Op.READ)
    assert_equal(
        failed.message("read from example.com:80"),
        deadline.timeout_message("read from example.com:80"),
    )


def test_aio_an_outcome_that_failed_raises_instead_of_answering() raises:
    var failed = Outcome.not_open(Op.POLL)
    assert_false(failed.is_ready())
    var raised = False
    try:
        _ = failed.check("wait on a test descriptor")
    except e:
        raised = True
        assert_true("not open" in String(e))
    assert_true(raised)


def test_aio_a_wait_on_a_passed_deadline_is_a_timeout_not_a_failure() raises:
    var got = Outcome.waiting()
    _run(wait_ready(BAD_FD, POLLIN, Deadline.after(0.0), Pointer(to=got)))
    assert_false(got.is_ready())
    assert_false(got.failed())


def test_aio_a_wait_on_a_descriptor_that_is_not_open_reports_it() raises:
    var got = Outcome.waiting()
    _run(wait_ready(BAD_FD, POLLIN, Deadline.after(1.0), Pointer(to=got)))
    assert_false(got.is_ready())
    assert_true(got.failed())
    assert_true("not open" in got.message("wait on a test descriptor"))


def test_aio_a_read_gets_what_the_other_end_sent() raises:
    var listener = Loopback()
    var stream = _connect(listener)
    var peer = listener.accept_within()
    peer.send_text("hello")

    var buf = List[UInt8](length=32, fill=0)
    var got = Outcome.waiting()
    _run(stream.read(Span(buf), read_deadline(5.0), Pointer(to=got)))

    assert_false(got.failed())
    assert_equal(_text(buf, got.count), "hello")


def test_aio_a_read_with_nothing_coming_times_out() raises:
    var listener = Loopback()
    var stream = _connect(listener)
    var peer = listener.accept_within()

    # Short, because this test spends the whole of it waiting. Long enough that
    # a loaded machine does not decide the deadline passed before the first
    # poll, which would pass for the wrong reason.
    var buf = List[UInt8](length=32, fill=0)
    var got = Outcome.waiting()
    _run(stream.read(Span(buf), read_deadline(0.25), Pointer(to=got)))

    assert_true(got.failed())
    var raised = False
    try:
        _ = got.check("read from loopback")
    except e:
        raised = True
        assert_true(is_read_timeout(e))
    assert_true(raised)
    # The server side has to still be here. Mojo destroys a value after its last
    # use, so without this the accepted socket closes before the read and the
    # test measures an end of stream rather than a timeout.
    assert_true(peer.fd() >= 0)


def test_aio_a_read_at_end_of_stream_is_zero_and_not_an_error() raises:
    var listener = Loopback()
    var stream = _connect(listener)
    var peer = listener.accept_within()
    peer.half_close()

    var buf = List[UInt8](length=32, fill=0)
    var got = Outcome.waiting()
    _run(stream.read(Span(buf), read_deadline(5.0), Pointer(to=got)))

    assert_false(got.failed())
    assert_equal(got.count, 0)


def test_aio_a_write_arrives_whole_at_the_other_end() raises:
    var listener = Loopback()
    var stream = _connect(listener)
    var peer = listener.accept_within()

    var got = Outcome.waiting()
    _run(
        stream.write(
            "a request line".as_bytes(), write_deadline(5.0), Pointer(to=got)
        )
    )

    assert_equal(got.check("write to loopback"), 14)
    assert_equal(peer.recv_text(), "a request line")


def test_aio_a_write_to_a_closed_socket_reports_it_as_a_value() raises:
    var listener = Loopback()
    var stream = _connect(listener)
    var peer = listener.accept_within()
    stream.close()

    var got = Outcome.waiting()
    _run(stream.write("gone".as_bytes(), write_deadline(5.0), Pointer(to=got)))

    assert_true(got.failed())


def test_aio_a_connect_reaches_a_listener() raises:
    var listener = Loopback()
    var deadline = connect_deadline(5.0)
    var pending = start_connect(listener.addr, String("loopback"))

    var got = Outcome.waiting()
    _run(wait_ready(pending.fd(), POLLOUT, deadline, Pointer(to=got)))

    var stream = finish_connect(pending^, got, deadline)
    assert_true(stream.is_open())
    assert_true(listener.has_pending())


def test_aio_a_connect_to_a_dead_address_fails_rather_than_hangs() raises:
    var deadline = connect_deadline(5.0)
    var pending = start_connect(dead_address(), String("nowhere"))

    var got = Outcome.waiting()
    _run(wait_ready(pending.fd(), POLLOUT, deadline, Pointer(to=got)))

    var raised = False
    try:
        _ = finish_connect(pending^, got, deadline)
    except e:
        raised = True
        assert_true(is_connect_error(e))
    assert_true(raised)


def test_aio_more_waiters_than_workers_all_get_their_bytes() raises:
    """The claim the whole loop exists to make.

    Twice as many reads are outstanding at once as the machine has workers, and
    none of them has any data yet when it starts waiting. If a waiting coroutine
    held its worker, the ones that did not get one would sit in the run queue
    until a deadline passed, so the reads that never ran would come back as
    timeouts rather than as bytes.
    """
    var waiters = _waiter_count()
    assert_true(waiters > parallelism_level())

    var listener = Loopback()
    var pairs = Pairs()
    for _ in range(waiters):
        var stream = _connect(listener)
        var peer = listener.accept_within()
        pairs.streams.append(stream^)
        pairs.peers.append(peer^)
        pairs.results.append(Outcome.waiting())
        pairs.buffers.append(List[UInt8](length=16, fill=0))

    # Every reader is started before anything is sent, so each one has to wait.
    # The sender is a task too, which means it only runs if the readers gave
    # their workers back.
    _run(_read_all(Pointer(to=pairs), read_deadline(5.0)))

    for i in range(waiters):
        assert_false(pairs.results[i].failed())
        assert_equal(pairs.results[i].count, 4)


def _waiter_count() -> Int:
    """How many reads to have outstanding, for the machine this is running on.

    Twice the worker count rather than a number written down here. A constant
    was wrong the first time it met a real machine: it was twelve, which is
    above the four workers on the development laptop and the eight on the Linux
    hosts but below the thirty two on the Windows one, so the test asserted
    itself out on the only machine in the fleet big enough to make the point
    interesting.
    """
    return parallelism_level() * 2


struct Pairs(Movable):
    """Both ends of every connection the concurrency test opens.

    One struct rather than four lists passed separately, because two mutable
    pointers sharing one origin parameter are rejected as aliasing and a single
    pointer to everything sidesteps the question.

    Every list is filled before any task starts and none of them is resized
    afterwards, so a task holding an element by index is not racing a
    reallocation. Each task touches one index and no other.
    """

    var streams: List[AsyncTcpStream]
    var peers: List[Peer]
    var results: List[Outcome]
    var buffers: List[List[UInt8]]

    def __init__(out self):
        self.streams = List[AsyncTcpStream]()
        self.peers = List[Peer]()
        self.results = List[Outcome]()
        self.buffers = List[List[UInt8]]()


def _text(buf: List[UInt8], count: Int) -> String:
    """The first `count` bytes of `buf` as text, for asserting on."""
    var text = String()
    for i in range(count):
        text += chr(Int(buf[i]))
    return text^


async def _send_all[o: MutOrigin](pairs: Pointer[Pairs, o]):
    for i in range(pairs[].peers.__len__()):
        # A coroutine cannot raise, and `send_text` is synchronous, so catching
        # it here is allowed. A failure would show up as a reader that timed
        # out.
        try:
            pairs[].peers[i].send_text("ping")
        except e:
            pass


async def _read_all[o: MutOrigin](pairs: Pointer[Pairs, o], deadline: Deadline):
    """Every read and one sender, all outstanding together.

    `read` goes into the group directly rather than through a per reader helper
    that awaits it. A coroutine that suspends in a loop cannot be awaited from
    another coroutine at all, and `read` is one, so the only thing that may
    drive it is `create_task` or `_run`. That it returns nothing, which
    `create_task` insists on, is why it reports through a pointer.
    """
    var group = TaskGroup()
    for i in range(pairs[].streams.__len__()):
        group.create_task(
            pairs[]
            .streams[i]
            .read(
                Span(pairs[].buffers[i]),
                deadline,
                Pointer(to=pairs[].results[i]),
            )
        )
    group.create_task(_send_all(pairs))
    await group


def _connect(mut listener: Loopback) raises -> AsyncTcpStream:
    """A connected async stream, opened the synchronous way.

    The async connect has its own tests. Using it here as well would make every
    read and write test depend on it, so these start from a stream that is
    already up.
    """
    return AsyncTcpStream(
        open_stream(listener.addr, String("loopback"), Deadline.after(5.0))
    )
