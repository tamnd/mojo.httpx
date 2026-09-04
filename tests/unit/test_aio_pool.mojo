"""Tests for the connection pool driven by coroutines.

The rules the pool applies, reuse by origin, expiry by age, liveness before
handing a connection out, eviction under the total limit, are the rules
`tests/unit/test_pool.mojo` covers against the synchronous pool and are not
retested here in full. What is tested is what is genuinely different: that a
request which has to open a connection and a request which reuses one both come
back with the same answer, that a failure arrives as an exception from `finish`
rather than out of a coroutine, that the accounting survives both, and, the
reason the file exists, that more requests can be in flight at once than there
are workers.

Both ends run in the same task group, and the server side here does not block.
Every other test in this suite writes its server as ordinary blocking code,
which is allowed and holds a worker for as long as it runs. That is fine when
the client has already written before the server starts reading. It is not fine
here, because the client cannot write until its connect has finished, so a
blocking server would hold the worker that the connect still needs. The server
side is therefore a step and a `yield_now`, the same shape the library itself
uses.
"""

from std.runtime.asyncrt import TaskGroup, _run, parallelism_level
from std.testing import assert_equal, assert_false, assert_true

from httpx._exceptions import is_connect_error, is_pool_timeout
from httpx._io.aio import yield_now
from httpx._io.deadline import Deadline, Deadlines
from httpx._models.request import Request
from httpx._models.url import URL
from httpx._pool.aio_pool import AsyncConnectionPool, PoolCall, pooled_exchange
from httpx._pool.limits import Limits
from httpx._stream.config import TlsConfig

from tests.support.loopback import Loopback, Peer, dead_address
from tests.support.testserver import TestServer

comptime OK_RESPONSE = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"

comptime WAITING = 0
"""The server side has not finished answering yet. Give way and come back."""

comptime SERVED = 1
"""The server side is done, whether it answered or gave up."""


def test_aio_pool_a_request_over_a_new_connection_gets_its_answer() raises:
    var work = Work()
    var pool = AsyncConnectionPool(Limits())
    var at = work.add(pool, "/hello")

    _run(_one_of_them(Pointer(to=work), at, at, OK_RESPONSE, _budget()))

    assert_true("GET /hello HTTP/1.1" in work.seen[at])
    var response = pool.finish(work.calls[at])
    assert_equal(response.status_code, 200)
    assert_equal(response.text(), "hello")


def test_aio_pool_a_connection_that_finished_cleanly_goes_back() raises:
    var work = Work()
    var pool = AsyncConnectionPool(Limits())
    var at = work.add(pool, "/")

    _run(_one_of_them(Pointer(to=work), at, at, OK_RESPONSE, _budget()))
    _ = pool.finish(work.calls[at])

    assert_equal(pool.idle_count(), 1)
    assert_equal(pool.leased_count(), 0)


def test_aio_pool_a_second_request_reuses_the_connection() raises:
    """The whole reason a pool exists, on the async path this time."""
    var work = Work()
    var pool = AsyncConnectionPool(Limits())
    var first = work.add(pool, "/one")

    _run(_one_of_them(Pointer(to=work), first, first, OK_RESPONSE, _budget()))
    _ = pool.finish(work.calls[first])

    work.seen[first] = String()
    var second = work.add(pool, "/two", on=first)
    _run(_one_of_them(Pointer(to=work), second, first, OK_RESPONSE, _budget()))
    var response = pool.finish(work.calls[second])

    assert_equal(response.status_code, 200)
    assert_true("GET /two HTTP/1.1" in work.seen[first])
    assert_equal(pool.idle_count(), 1)
    assert_equal(pool.total_count(), 1)
    # Nothing connected a second time, which is the claim. A pool that opened a
    # fresh connection would leave one waiting in the listener's accept queue.
    assert_false(work.listeners[first].has_pending(0))


def test_aio_pool_a_connection_the_server_dropped_is_not_handed_out() raises:
    """A pooled connection is a guess, and this is the guess being wrong."""
    var work = Work()
    var pool = AsyncConnectionPool(Limits())
    var first = work.add(pool, "/one")

    _run(_one_of_them(Pointer(to=work), first, first, OK_RESPONSE, _budget()))
    _ = pool.finish(work.calls[first])
    assert_equal(pool.idle_count(), 1)

    work.peers[first] = None
    _wait_until_the_drop_is_visible(pool)

    var second = work.add(pool, "/two", on=first)
    assert_equal(pool.idle_count(), 0)
    _run(_one_of_them(Pointer(to=work), second, first, OK_RESPONSE, _budget()))
    assert_equal(pool.finish(work.calls[second]).status_code, 200)


def test_aio_pool_an_https_request_shakes_hands_before_it_sends() raises:
    """The handshake driven by the coroutine rather than by a client above it.

    A real server rather than the hand driven loopback the rest of this file
    uses, because the server side of a handshake is OpenSSL and writing one a
    step at a time here would be testing the test. What this checks is the pool
    side: that `open` builds an https call, that `pooled_exchange` runs the
    handshake inside its connect loop, and that the answer comes back through
    `finish` the same as a plain one.
    """
    var server = TestServer(tls=True)
    var tls = TlsConfig()
    tls.verify = TestServer.tls_verify()
    var pool = AsyncConnectionPool(Limits(), tls=tls^)
    var request = Request("GET", URL(server.url("/get")))
    var call = pool.open(request, Deadlines.never())
    var budget = _budget()
    _run(
        pooled_exchange(
            Pointer(to=call.race),
            Pointer(to=call.conn),
            Pointer(to=call.securing),
            Pointer(to=request),
            Pointer(to=call.result),
            call.connecting,
            budget.connect,
            budget.write,
            budget.read,
            call.form,
        )
    )

    var response = pool.finish(call)
    assert_equal(response.status_code, 200)
    assert_true('"method": "GET"' in response.text())
    assert_equal(pool.leased_count(), 0)
    assert_equal(pool.idle_count(), 1)
    server.stop()


def test_aio_pool_a_certificate_nobody_trusts_stops_the_connect() raises:
    """A handshake failure has to reach `finish` as an exception, the same as a
    refused connect. It is recorded on the exchange rather than raised, because
    the coroutine that noticed it cannot raise, and a pool that lost the reason
    would report a working server as unreachable."""
    var server = TestServer(tls=True)
    var pool = AsyncConnectionPool(Limits())
    var request = Request("GET", URL(server.url("/get")))
    var call = pool.open(request, Deadlines.never())
    var budget = _budget()
    _run(
        pooled_exchange(
            Pointer(to=call.race),
            Pointer(to=call.conn),
            Pointer(to=call.securing),
            Pointer(to=request),
            Pointer(to=call.result),
            call.connecting,
            budget.connect,
            budget.write,
            budget.read,
            call.form,
        )
    )

    var raised = False
    try:
        _ = pool.finish(call)
    except e:
        raised = True
        assert_true("verify" in String(e) or "certificate" in String(e))
    assert_true(raised)
    assert_equal(pool.leased_count(), 0)
    assert_equal(pool.idle_count(), 0)
    server.stop()


def test_aio_pool_a_refused_connect_comes_back_from_finish() raises:
    """A coroutine cannot raise, so the reason has to survive as a value."""
    var dead = dead_address()
    var pool = AsyncConnectionPool(Limits())
    var request = Request(
        "GET", URL(String("http://", dead.text(), ":", dead.port(), "/"))
    )
    var call = pool.open(request, Deadlines.never())
    var budget = _budget()
    _run(
        pooled_exchange(
            Pointer(to=call.race),
            Pointer(to=call.conn),
            Pointer(to=call.securing),
            Pointer(to=request),
            Pointer(to=call.result),
            call.connecting,
            budget.connect,
            budget.write,
            budget.read,
            call.form,
        )
    )

    var raised = False
    try:
        _ = pool.finish(call)
    except e:
        raised = True
        assert_true(is_connect_error(e))
    assert_true(raised)
    assert_equal(pool.leased_count(), 0)
    assert_equal(pool.idle_count(), 0)
    # The addresses that all refused are worth forgetting, so the next attempt
    # asks again rather than getting the same list back.
    assert_equal(pool.resolver.cached_count(), 0)


def test_aio_pool_a_full_pool_says_so_rather_than_waiting_forever() raises:
    var listener = Loopback()
    var pool = AsyncConnectionPool(Limits(max_connections=1))
    var first = Request("GET", URL(_url(listener.port, "/one")))
    var second = Request("GET", URL(_url(listener.port, "/two")))

    var held = pool.open(first, Deadlines.never())
    assert_equal(pool.leased_count(), 1)

    var raised = False
    try:
        _ = pool.open(second, Deadlines.never())
    except e:
        raised = True
        assert_true(is_pool_timeout(e))
    assert_true(raised)
    # Keeps the opened call alive to the end of the test. Mojo drops a value
    # after its last use, and the lease it holds is what the limit is counting.
    assert_equal(held.connecting, 1)


def test_aio_pool_closing_it_drops_the_connections_it_was_keeping() raises:
    var work = Work()
    var pool = AsyncConnectionPool(Limits())
    var at = work.add(pool, "/")

    _run(_one_of_them(Pointer(to=work), at, at, OK_RESPONSE, _budget()))
    _ = pool.finish(work.calls[at])
    assert_equal(pool.idle_count(), 1)

    pool.close()
    assert_equal(pool.idle_count(), 0)
    assert_equal(pool.total_count(), 0)


def test_aio_pool_more_requests_at_once_than_there_are_workers() raises:
    """The claim the async pool exists to make.

    Every request is started before any server answers, and every one of them
    has to open its own connection first, so each one has to give way several
    times. If a waiting request held its worker, the ones past the worker count
    would not run until a deadline passed and would come back as timeouts rather
    than as responses.

    A listener each rather than one shared between them, so that every task
    touches one index and no other. Sharing a listener would mean several tasks
    appending to the same list, which is a race in the test rather than a test
    of anything.
    """
    var count = parallelism_level() * 2
    assert_true(count > parallelism_level())

    var work = Work()
    var pool = AsyncConnectionPool(Limits())
    for _ in range(count):
        _ = work.add(pool, "/")

    _run(_all_of_them(Pointer(to=work), OK_RESPONSE, _budget()))

    for i in range(count):
        assert_true("GET / HTTP/1.1" in work.seen[i])
        assert_equal(pool.finish(work.calls[i]).status_code, 200)


struct Work(Movable):
    """Both ends of every request one test has in flight.

    One struct rather than five lists passed separately, because two mutable
    pointers sharing one origin parameter are rejected as aliasing.

    Every list is filled before any task starts and none is resized while tasks
    are running, so a task holding an element by index is not racing a
    reallocation. Each task touches one index and no other.
    """

    var listeners: List[Loopback]
    var peers: List[Optional[Peer]]
    """The accepted side of each connection, or nothing until it is accepted.

    Kept here rather than in the coroutine that accepts it, so that a connection
    survives between two `_run` calls. The reuse test needs exactly that: the
    second request goes to the same server socket the first one used.
    """

    var seen: List[String]
    """What each server has read so far, request line included."""

    var calls: List[PoolCall]
    var requests: List[Request]

    def __init__(out self):
        self.listeners = List[Loopback]()
        self.peers = List[Optional[Peer]]()
        self.seen = List[String]()
        self.calls = List[PoolCall]()
        self.requests = List[Request]()

    def add(
        mut self, mut pool: AsyncConnectionPool, path: String, on: Int = -1
    ) raises -> Int:
        """Add one request and say which index it went to.

        `on` is the listener to send it to, and -1 means a new one. A request
        that is meant to reuse a connection has to name an existing listener,
        because reuse is decided by origin and an origin is a port: send the
        second request to a listener of its own and the pool is right to open a
        second connection, and the test would be watching itself rather than the
        pool.
        """
        var served_by = on
        if served_by < 0:
            served_by = len(self.listeners)
            self.listeners.append(Loopback())
            self.peers.append(None)
            self.seen.append(String())
        var request = Request(
            "GET", URL(_url(self.listeners[served_by].port, path))
        )
        var at = len(self.calls)
        self.calls.append(pool.open(request, Deadlines.never()))
        self.requests.append(request^)
        return at


def _url(port: UInt16, path: String) -> String:
    return String("http://127.0.0.1:", port, path)


def _wait_until_the_drop_is_visible(mut pool: AsyncConnectionPool) raises:
    """Spin until the pooled connection can tell that its peer went away.

    Closing the server side of a connection sends a FIN, and the client learning
    about it is a network event rather than something that has finished by the
    time the close returns. On the loopback of a Linux or macOS host it is there
    at once, and on Windows it is not, so a test that went straight on to open
    its second request would sometimes be handed a connection that still looked
    sound, and would then fail on the read rather than on the thing it is here
    to check.

    Reaches into `_idle` because the pool has no way to ask this question and
    should not grow one: nothing in the library wants to know whether a
    connection is dead yet, only whether it is dead now.
    """
    var give_up = Deadline.after(5.0)
    while not pool._idle[0].is_stale(pool.limits.keepalive_expiry):
        if give_up.expired():
            raise Error(
                "the pooled connection never noticed the server hang up"
            )


def _budget() -> Deadlines:
    """Five seconds a phase, which is far longer than loopback ever needs.

    Built by a helper rather than inline in each test, and never inside a
    coroutine, because `Deadlines.after` takes `Optional`s and a coroutine that
    makes a `TaskGroup` may not have an `Optional` anywhere in its frame.
    """
    return Deadlines.uniform(5.0)


def _serve_step[
    w: MutOrigin
](work: Pointer[Work, w], at: Int, response: String, deadline: Deadline) -> Int:
    """One non blocking pass of the server side: accept, read, answer.

    A step rather than blocking code, for the reason in the module docstring.
    Gives up rather than raising, because the only caller is a coroutine and the
    assertions are all on what the client got.
    """
    if deadline.expired():
        return SERVED
    if not work[].peers[at]:
        if not work[].listeners[at].has_pending(0):
            return WAITING
        try:
            work[].peers[at] = Optional[Peer](
                work[].listeners[at].accept_within(0)
            )
        except:
            return SERVED
        return WAITING

    try:
        if not work[].peers[at].value().ready(0):
            return WAITING
        var piece = work[].peers[at].value().recv_text()
        if piece.byte_length() == 0:
            return SERVED
        work[].seen[at] += piece
        if "\r\n\r\n" not in work[].seen[at]:
            return WAITING
        work[].peers[at].value().send_text(response)
    except:
        return SERVED
    return SERVED


async def _answer_one[
    w: MutOrigin
](work: Pointer[Work, w], at: Int, response: String, deadline: Deadline):
    """The server side of one connection, waiting by giving the worker back."""
    while _serve_step(work, at, response, deadline) == WAITING:
        await yield_now()


async def _one_of_them[
    w: MutOrigin
](
    work: Pointer[Work, w],
    at: Int,
    served_by: Int,
    response: String,
    budget: Deadlines,
):
    """One request and the server that answers it, outstanding together.

    `at` is the request and `served_by` is the connection that answers it. They
    are the same index except in the reuse test, where the second request goes
    over the socket the first one opened.
    """
    var group = TaskGroup()
    # One iteration each, which is a strange way to write two calls and is the
    # only way that compiles. The same two `create_task` calls written straight
    # line crash the compiler with a stack dump and no diagnostic, and hoisting
    # the pointers into locals first does not help. `_all_of_them` below is the
    # same code with real loops around it and has never had the problem, which
    # is what pointed at the loop rather than at anything in the arguments.
    for i in range(at, at + 1):
        group.create_task(
            pooled_exchange(
                Pointer(to=work[].calls[i].race),
                Pointer(to=work[].calls[i].conn),
                Pointer(to=work[].calls[i].securing),
                Pointer(to=work[].requests[i]),
                Pointer(to=work[].calls[i].result),
                work[].calls[i].connecting,
                budget.connect,
                budget.write,
                budget.read,
                work[].calls[i].form,
            )
        )
    for i in range(served_by, served_by + 1):
        group.create_task(_answer_one(work, i, response, budget.read))
    await group


async def _all_of_them[
    w: MutOrigin
](work: Pointer[Work, w], response: String, budget: Deadlines):
    """Every request and every server, all outstanding together."""
    var group = TaskGroup()
    for i in range(work[].calls.__len__()):
        group.create_task(
            pooled_exchange(
                Pointer(to=work[].calls[i].race),
                Pointer(to=work[].calls[i].conn),
                Pointer(to=work[].calls[i].securing),
                Pointer(to=work[].requests[i]),
                Pointer(to=work[].calls[i].result),
                work[].calls[i].connecting,
                budget.connect,
                budget.write,
                budget.read,
                work[].calls[i].form,
            )
        )
    for i in range(work[].listeners.__len__()):
        group.create_task(_answer_one(work, i, response, budget.read))
    await group
