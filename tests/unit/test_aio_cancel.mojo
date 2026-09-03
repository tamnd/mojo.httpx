"""Tests for stopping an async request that is already going.

There is no cancel here, and `docs/async.md` says why: a user never holds
anything that stands for a request in flight, so there is nothing to call cancel
on. What takes its place is three things, and this file is the three of them.

A deadline stops a request whether or not the server ever answers, and it stops
it near the deadline rather than near the end of whatever the server was doing.
Dropping a streamed response stops the reading, and it closes the connection
rather than pooling it, because the rest of the body is still on the wire.
Whatever stopped a request gives the lease back, so a program that walks away
from responses does not end up being told its pool is full when it is empty.

The timings here are one sided on purpose. Each one asserts that a stop happened
long before the server would have finished, with a bound several times the
deadline it is testing, so a loaded machine makes them slow rather than flaky.

Every call that needs the server takes it as an argument, for the reason
`tests/unit/test_streaming.mojo` gives.
"""

from std.testing import assert_equal, assert_true

from httpx._aio_client import AsyncClient
from httpx._exceptions import (
    ErrorKind,
    is_connect_error,
    is_read_timeout,
    kind_of,
)
from httpx._io.deadline import Deadlines, NANOS_PER_SECOND, now_ns
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._models.url import URL
from httpx._transport.aio_http import AsyncHTTPTransport

from tests.support.loopback import dead_address
from tests.support.testserver import TestServer


comptime SLOW_BODY = "/drip/10?delay=1.0"
"""A response whose head arrives at once and whose body takes ten seconds.

Ten bytes a second apart. The head is out of the way immediately, so what any
deadline in this file hits is a gap in the body rather than a slow server.
"""

comptime QUICK_READ = 0.25
"""The read budget every stopping test is given, in seconds.

Four times shorter than one gap in `SLOW_BODY`, so the stop is the deadline and
not a coincidence.
"""


def _stopping() -> Deadlines:
    """Room to connect and to write, and almost none to read."""
    return Deadlines.after(
        Optional[Float64](5.0),
        Optional[Float64](QUICK_READ),
        Optional[Float64](5.0),
        Optional[Float64](5.0),
    )


def _patient() -> Deadlines:
    return Deadlines.uniform(Optional[Float64](10.0))


def _stream(
    mut transport: AsyncHTTPTransport,
    server: TestServer,
    path: StringSpan,
    deadlines: Deadlines,
) raises -> Response:
    return transport.handle_stream(
        Request("GET", URL(server.url(path))), deadlines
    )


def _get(
    mut transport: AsyncHTTPTransport,
    server: TestServer,
    path: StringSpan,
    deadlines: Deadlines,
) raises -> Response:
    return transport.handle_request(
        Request("GET", URL(server.url(path))), deadlines
    )


def _client_stream(
    mut client: AsyncClient, server: TestServer, path: StringSpan
) raises -> Response:
    return client.stream("GET", server.url(path))


def _drain(mut response: Response) raises -> Int:
    var seen = 0
    var chunks = response.aiter_raw()
    while chunks.has_next():
        seen += len(chunks.next())
    return seen


def _first_chunk(mut response: Response) raises -> Int:
    """One chunk and then walk away, leaving the rest of the body on the wire.

    The iterator is destroyed here rather than at the call site, which is the
    half read state the caller then closes out of.
    """
    var chunks = response.aiter_raw()
    if not chunks.has_next():
        return 0
    return len(chunks.next())


def _read_after_closing_the_client(
    mut response: Response, server: TestServer
) raises -> Int:
    response.read()
    return len(response.content())


def _seconds_since(started: UInt64) -> Float64:
    return Float64(now_ns() - started) / Float64(NANOS_PER_SECOND)


def test_a_streamed_read_gives_up_when_its_deadline_passes() raises:
    """The stop that stands in for cancellation, and the one that has to be
    prompt.

    A read that waited on the socket without a bound would come back when the
    server finished, ten seconds from now, and the deadline would be a thing the
    caller was told about afterwards rather than a thing that stopped anything.
    """
    var server = TestServer()
    var transport = AsyncHTTPTransport()
    var response = _stream(transport, server, SLOW_BODY, _stopping())
    var started = now_ns()

    var raised = False
    try:
        _ = _drain(response)
    except e:
        raised = True
        assert_true(is_read_timeout(e))
    assert_true(raised, "a body arriving slower than the deadline should stop")

    var waited = _seconds_since(started)
    assert_true(
        waited < 5.0,
        String("gave up after ", waited, "s, which is not the deadline"),
    )
    server.stop()


def test_a_stream_stopped_by_its_deadline_leaves_nothing_leased() raises:
    """A request that was stopped still puts the pool back the way it found it.

    The connection goes rather than returning to the pool, because the body
    stopped partway and nobody knows where the wire has got to, and the lease
    comes back either way.
    """
    var server = TestServer()
    var transport = AsyncHTTPTransport()
    var response = _stream(transport, server, SLOW_BODY, _stopping())
    try:
        _ = _drain(response)
    except e:
        pass

    assert_equal(transport.pool[].leased_count(), 0)
    assert_equal(transport.pool[].idle_count(), 0)
    server.stop()


def test_a_buffered_request_stopped_by_its_deadline_leaves_nothing_leased() raises:
    """The same claim on the path that does not stream.

    Worth its own test because the settling is done somewhere else. A streamed
    body is released by the source's own close and a buffered one by the pool's
    `_settle`, so the two could disagree and only one of them would be caught by
    the test above.
    """
    var server = TestServer()
    var transport = AsyncHTTPTransport()
    var raised = False
    try:
        _ = _get(transport, server, SLOW_BODY, _stopping())
    except e:
        raised = True
        assert_true(is_read_timeout(e))
    assert_true(raised)

    assert_equal(transport.pool[].leased_count(), 0)
    assert_equal(transport.pool[].idle_count(), 0)
    server.stop()


def test_a_stream_stopped_halfway_is_not_the_connection_the_next_request_gets() raises:
    """Dropping a half read body closes the connection rather than pooling it.

    The server tells us which connection answered, so this is a claim about the
    socket rather than about a counter. A connection whose next byte is the
    middle of somebody else's response would answer the second request with the
    tail of the first.
    """
    var server = TestServer()
    var transport = AsyncHTTPTransport()
    var first = _stream(transport, server, "/stream-bytes/65536", _patient())
    var first_id = String(first.headers["x-conn-id"])
    assert_true(_first_chunk(first) > 0)
    first.close()

    var second = _get(transport, server, "/conn", _patient())
    assert_true(first_id != String(second.headers["x-conn-id"]))
    assert_equal(transport.pool[].total_count(), 1)
    server.stop()


def test_stopping_a_stream_that_is_already_stopped_is_harmless() raises:
    """Stopping twice is what a caller who cannot remember does, and what a
    `with` block does around a body the caller already closed."""
    var server = TestServer()
    var transport = AsyncHTTPTransport()
    var response = _stream(transport, server, "/bytes/4096", _patient())
    response.close()
    response.close()

    assert_true(response.is_closed)
    assert_equal(transport.pool[].leased_count(), 0)
    assert_equal(transport.pool[].idle_count(), 0)
    server.stop()


def test_a_stopped_stream_has_nothing_left_to_read() raises:
    """Reading a stopped response is an error rather than an empty body.

    An empty list would be indistinguishable from a body that really was empty,
    and a caller acting on the wrong one has no way to find out.
    """
    var server = TestServer()
    var transport = AsyncHTTPTransport()
    var response = _stream(transport, server, "/bytes/4096", _patient())
    response.close()

    var raised = False
    try:
        _ = response.aiter_raw()
    except e:
        raised = True
        assert_true(kind_of(e) == ErrorKind.STREAM_CLOSED)
    assert_true(raised)
    server.stop()


def test_a_streamed_response_outlives_the_client_that_made_it() raises:
    """Closing the client is not a way to stop a body that is still arriving.

    Closing a client closes the connections sitting idle in its pool, and the
    one under a streamed response is not one of those. It is leased, the
    response holds it, and the pool stays alive underneath because the response
    holds a handle on that too.
    """
    var server = TestServer()
    var client = AsyncClient()
    var response = _client_stream(client, server, "/bytes/64")
    client.close()

    assert_equal(_read_after_closing_the_client(response, server), 64)
    server.stop()


def test_a_batch_finishes_every_request_even_after_one_fails() raises:
    """Nothing in a batch is abandoned when another member of it fails.

    There is no cancelling the rest, because `TaskGroup` has no cancel, and it
    would be the wrong thing anyway: a task stopped between its write and its
    read would leave a connection leased forever. So the two good requests here
    are finished and pooled, and the failure is what the caller sees.
    """
    var server = TestServer()
    var dead = dead_address()
    var transport = AsyncHTTPTransport()

    var requests = List[Request]()
    requests.append(Request("GET", URL(server.url("/conn"))))
    requests.append(
        Request(
            "GET",
            URL(String("http://", dead.text(), ":", dead.port(), "/")),
        )
    )
    requests.append(Request("GET", URL(server.url("/conn"))))

    var raised = False
    try:
        _ = transport.handle_many(requests^, _patient())
    except e:
        raised = True
        assert_true(is_connect_error(e))
    assert_true(raised)

    assert_equal(transport.pool[].leased_count(), 0)
    assert_equal(transport.pool[].idle_count(), 2)
    server.stop()
