"""Tests for one HTTP/1.1 exchange driven by coroutines.

The sans I/O half is `H1Machine` and is tested through the synchronous driver,
which is the point of there being one machine. What is tested here is the second
driver over it: that an async exchange puts the same bytes on the wire, reads
the same response back, reports a failure as a value rather than raising out of
a coroutine, and, the reason any of this exists, that several exchanges can be
in flight at once on fewer workers than there are exchanges.

Both ends run in the same task group. The server side is ordinary blocking code
in a coroutine, which is allowed and costs a worker for as long as it runs, and
the client side never blocks. A test that used a blocking server without a
scheduler could not drive both ends of one connection at all, which is what the
comment at the top of tests/support/loopback.mojo has always said.
"""

from std.runtime.asyncrt import TaskGroup, _run, parallelism_level
from std.testing import assert_equal, assert_false, assert_true

from httpx._exceptions import is_read_timeout, is_remote_protocol_error
from httpx._io.aio_socket import AsyncTcpStream
from httpx._io.deadline import Deadline, read_deadline, write_deadline
from httpx._io.socket import open_stream
from httpx._models.headers import Headers
from httpx._models.request import Request
from httpx._models.url import URL
from httpx._proto.h1.aio import AsyncH1Connection, Exchange, exchange
from httpx._stream.aio_stream import AsyncStream

from tests.support.loopback import Loopback, Peer

comptime OK_RESPONSE = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"


def test_h1_aio_a_get_reaches_the_server_and_the_answer_comes_back() raises:
    var listener = Loopback()
    var conn = _connect(listener)
    var peer = listener.accept_within()

    var request = Request("GET", URL("http://example.com/hello"))
    var got = Exchange()
    var seen = String()
    _run(
        _both_ends(
            Pointer(to=conn),
            Pointer(to=request),
            Pointer(to=got),
            Pointer(to=peer),
            Pointer(to=seen),
            OK_RESPONSE,
            write_deadline(5.0),
            read_deadline(5.0),
        )
    )

    assert_equal(seen, "GET /hello HTTP/1.1\r\nHost: example.com\r\n\r\n")
    var response = got.response()
    assert_equal(response.status_code, 200)
    assert_equal(response.text(), "hello")


def test_h1_aio_a_post_puts_its_body_on_the_wire() raises:
    var listener = Loopback()
    var conn = _connect(listener)
    var peer = listener.accept_within()

    var request = Request("POST", URL("http://example.com/submit"))
    request.content = List[UInt8]("hi there".as_bytes())
    var got = Exchange()
    var seen = String()
    _run(
        _both_ends(
            Pointer(to=conn),
            Pointer(to=request),
            Pointer(to=got),
            Pointer(to=peer),
            Pointer(to=seen),
            OK_RESPONSE,
            write_deadline(5.0),
            read_deadline(5.0),
        )
    )

    assert_true("POST /submit HTTP/1.1" in seen)
    assert_true("Content-Length: 8" in seen)
    assert_true(seen.endswith("hi there"))
    assert_equal(got.response().status_code, 200)


def test_h1_aio_a_response_split_across_packets_is_read_whole() raises:
    """The read loop has to keep going, not take a pause for an ending."""
    var listener = Loopback()
    var conn = _connect(listener)
    var peer = listener.accept_within()

    var request = Request("GET", URL("http://example.com/"))
    var got = Exchange()
    var seen = String()
    _run(
        _both_ends_in_pieces(
            Pointer(to=conn),
            Pointer(to=request),
            Pointer(to=got),
            Pointer(to=peer),
            Pointer(to=seen),
            write_deadline(5.0),
            read_deadline(5.0),
        )
    )

    var response = got.response()
    assert_equal(response.status_code, 200)
    assert_equal(response.text(), "hello")


def test_h1_aio_a_server_that_never_answers_is_a_timeout_not_a_hang() raises:
    var listener = Loopback()
    var conn = _connect(listener)
    var peer = listener.accept_within()

    var request = Request("GET", URL("http://example.com/"))
    var got = Exchange()
    # Short, because the test spends the whole of it waiting.
    _run(
        exchange(
            Pointer(to=conn),
            Pointer(to=request),
            Pointer(to=got),
            write_deadline(5.0),
            read_deadline(0.25),
        )
    )

    assert_true(got.failed())
    var raised = False
    try:
        _ = got.response()
    except e:
        raised = True
        assert_true(is_read_timeout(e))
    assert_true(raised)
    # The server side has to outlive the read. Mojo destroys a value after its
    # last use, so without this the accepted socket closes and the exchange
    # reads an end of stream rather than timing out.
    assert_true(peer.fd() >= 0)


def test_h1_aio_a_server_that_hangs_up_early_is_reported_not_returned() raises:
    var listener = Loopback()
    var conn = _connect(listener)
    var peer = listener.accept_within()

    var request = Request("GET", URL("http://example.com/"))
    var got = Exchange()
    var seen = String()
    _run(
        _both_ends(
            Pointer(to=conn),
            Pointer(to=request),
            Pointer(to=got),
            Pointer(to=peer),
            Pointer(to=seen),
            "HTTP/1.1 200 OK\r\nContent-Len",
            write_deadline(5.0),
            read_deadline(5.0),
        )
    )

    assert_true(got.failed())
    var raised = False
    try:
        _ = got.response()
    except e:
        raised = True
        assert_true(is_remote_protocol_error(e))
    assert_true(raised)


def test_h1_aio_more_exchanges_at_once_than_there_are_workers() raises:
    """The claim the async driver exists to make.

    Every exchange is started before any server answers, so each one has to
    wait. If a waiting exchange held its worker, the ones past the worker count
    would not run until a deadline passed and would come back as timeouts rather
    than as responses.
    """
    var count = parallelism_level() * 2
    assert_true(count > parallelism_level())

    var listener = Loopback()
    var work = Work()
    for _ in range(count):
        var conn = _connect(listener)
        var peer = listener.accept_within()
        work.conns.append(conn^)
        work.peers.append(peer^)
        work.requests.append(Request("GET", URL("http://example.com/")))
        work.results.append(Exchange())

    _run(
        _all_of_them(Pointer(to=work), write_deadline(5.0), read_deadline(5.0))
    )

    for i in range(count):
        assert_false(work.results[i].failed())
        assert_equal(work.results[i].response().status_code, 200)


struct Work(Movable):
    """Every exchange the concurrency test has in flight, and both ends of it.

    One struct rather than four lists passed separately, because two mutable
    pointers sharing one origin parameter are rejected as aliasing.

    Every list is filled before any task starts and none is resized afterwards,
    so a task holding an element by index is not racing a reallocation. Each
    task touches one index and no other.
    """

    var conns: List[AsyncH1Connection]
    var peers: List[Peer]
    var requests: List[Request]
    var results: List[Exchange]

    def __init__(out self):
        self.conns = List[AsyncH1Connection]()
        self.peers = List[Peer]()
        self.requests = List[Request]()
        self.results = List[Exchange]()


def _connect(listener: Loopback) raises -> AsyncH1Connection:
    return AsyncH1Connection(
        AsyncStream(
            AsyncTcpStream(
                open_stream(listener.addr, "loopback", Deadline.after(5.0))
            )
        )
    )


async def _serve[
    p: MutOrigin, s: MutOrigin
](peer: Pointer[Peer, p], seen: Pointer[String, s], response: String):
    """The server side: read a request, send a canned answer.

    Ordinary blocking code, which a coroutine is allowed to run as long as it
    does not raise out of one. It holds its worker while it blocks, and the
    reason that is fine here is that it only blocks once the client has already
    written, which the client does without holding anything.
    """
    try:
        seen[] = peer[].recv_until("\r\n\r\n")
        if response.byte_length() > 0:
            peer[].send_text(response)
    except e:
        pass
    peer[].half_close()


async def _serve_in_pieces[
    p: MutOrigin, s: MutOrigin
](peer: Pointer[Peer, p], seen: Pointer[String, s]):
    """The same answer, arriving in three writes instead of one."""
    try:
        seen[] = peer[].recv_until("\r\n\r\n")
        peer[].send_text("HTTP/1.1 200 OK\r\n")
        peer[].send_text("Content-Length: 5\r\n\r\n")
        peer[].send_text("hello")
    except e:
        pass


async def _both_ends[
    c: MutOrigin, q: MutOrigin, x: MutOrigin, p: MutOrigin, s: MutOrigin
](
    conn: Pointer[AsyncH1Connection, c],
    request: Pointer[Request, q],
    result: Pointer[Exchange, x],
    peer: Pointer[Peer, p],
    seen: Pointer[String, s],
    response: String,
    write_at: Deadline,
    read_at: Deadline,
):
    """Both sides of one connection, outstanding together.

    The two deadlines are arguments rather than being built here, and they have
    to be. `write_deadline` takes an `Optional`, and a coroutine that makes a
    `TaskGroup` may not have an `Optional` anywhere in its own frame: the
    compiler crashes with a stack dump and no message at all. `httpx._io.aio`
    has the whole list and `tools/probe/async.mojo` has the case.
    """
    var group = TaskGroup()
    group.create_task(exchange(conn, request, result, write_at, read_at))
    group.create_task(_serve(peer, seen, response))
    await group


async def _both_ends_in_pieces[
    c: MutOrigin, q: MutOrigin, x: MutOrigin, p: MutOrigin, s: MutOrigin
](
    conn: Pointer[AsyncH1Connection, c],
    request: Pointer[Request, q],
    result: Pointer[Exchange, x],
    peer: Pointer[Peer, p],
    seen: Pointer[String, s],
    write_at: Deadline,
    read_at: Deadline,
):
    var group = TaskGroup()
    group.create_task(exchange(conn, request, result, write_at, read_at))
    group.create_task(_serve_in_pieces(peer, seen))
    await group


async def _all_of_them[
    w: MutOrigin
](work: Pointer[Work, w], write_at: Deadline, read_at: Deadline):
    """Every exchange and every server, all outstanding together.

    The deadlines arrive as arguments for the reason on `_both_ends`.
    """
    var group = TaskGroup()
    for i in range(work[].conns.__len__()):
        group.create_task(
            exchange(
                Pointer(to=work[].conns[i]),
                Pointer(to=work[].requests[i]),
                Pointer(to=work[].results[i]),
                write_at,
                read_at,
            )
        )
    for i in range(work[].peers.__len__()):
        group.create_task(_answer(Pointer(to=work[].peers[i])))
    await group


async def _answer[p: MutOrigin](peer: Pointer[Peer, p]):
    try:
        _ = peer[].recv_until("\r\n\r\n")
        peer[].send_text(OK_RESPONSE)
    except e:
        pass
