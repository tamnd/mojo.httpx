"""Tests for the async transport and the erasure that makes it pluggable.

Three things to prove. That a request through the async transport comes back
the same as one through the synchronous transport, since that is the promise the
whole async path is being built to keep. That a batch really overlaps, which is
the only reason the async transport exists at all. And that the vtable reaches
the concrete type underneath in both directions, because a dispatch that quietly
went to the wrong place would show up as a hang somewhere far from here. And
that the TLS configuration reaches the pool, which is a one line join that has
already been got wrong once.

The server is the real one from `tests/server/server.py` rather than a loopback
socket driven by hand. `tests/unit/test_aio_pool.mojo` drives both ends itself,
because there it is testing the coroutine and needs the server side to give its
worker back too. Here the client blocks the calling thread until the whole batch
is finished, so the server has to be somewhere else entirely, and a process that
answers on threads is exactly that.
"""

from std.runtime.asyncrt import parallelism_level
from std.testing import assert_equal, assert_true

from httpx._exceptions import is_connect_error, is_pool_timeout
from httpx._io.deadline import NANOS_PER_SECOND, Deadlines, now_ns
from httpx._models.headers import Headers
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._models.url import URL
from httpx._pool.limits import Limits
from httpx._stream.config import TlsConfig
from httpx._transport.aio_base import AnyAsyncTransport, erase_async_transport
from httpx._transport.aio_http import AsyncHTTPTransport
from httpx._transport.mock import MockRouter, MockTransport, Route

from tests.support.loopback import dead_address
from tests.support.testserver import TestServer


comptime DELAY_SECONDS = 0.3
"""How long the server sits on a request in the test that times a batch.

Long enough that the difference between overlapping and taking turns is
seconds rather than milliseconds, and short enough that the test is not the
slow one in the suite.
"""


def _deadlines() -> Deadlines:
    return Deadlines.uniform(Optional[Float64](10.0))


def _get(server: TestServer, path: String) raises -> Request:
    return Request(
        "GET", URL(String("http://", server.host, ":", server.port, path))
    )


def _send(
    mut transport: AsyncHTTPTransport,
    server: TestServer,
    var requests: List[Request],
) raises -> List[Response]:
    """Run a batch with the server borrowed for the length of the call.

    The borrow is the point. Mojo destroys a value after its last use, and a
    request built from the server's port is not a use of the server, so a test
    that built its requests and then called the transport would have the server
    torn down before the first connect and would fail with a refusal. Handing it
    through the call says what is actually true, which is that the batch needs
    the server to still be running.
    """
    return transport.handle_many(requests^, _deadlines())


def _send_one(
    mut transport: AsyncHTTPTransport, server: TestServer, var request: Request
) raises -> Response:
    """One request, with the server held for the same reason as in `_send`."""
    return transport.handle_request(request^, _deadlines())


def _send_erased(
    mut transport: AnyAsyncTransport,
    server: TestServer,
    var requests: List[Request],
) raises -> List[Response]:
    return transport.handle_many(requests^, _deadlines())


def _send_one_erased(
    mut transport: AnyAsyncTransport, server: TestServer, var request: Request
) raises -> Response:
    return transport.handle_request(request^, _deadlines())


def test_aio_transport_a_single_request_gets_its_answer() raises:
    var server = TestServer()
    var transport = AsyncHTTPTransport()

    var response = _send_one(transport, server, _get(server, "/get"))

    assert_equal(response.status_code, 200)
    assert_true("/get" in response.request().url.path())


def test_aio_transport_a_batch_comes_back_in_the_order_it_went_out() raises:
    """Responses are paired with requests by position and nothing else.

    Each request asks for a different query string and the server echoes the
    path it was asked for, so a response that landed in the wrong slot is
    visible rather than merely likely. They finish in whatever order the server
    and the scheduler between them decide, which is the point: the ordering here
    is something the transport puts back, not something that happens by itself.
    """
    var server = TestServer()
    var transport = AsyncHTTPTransport()

    var requests = List[Request]()
    for i in range(6):
        requests.append(_get(server, String("/get?i=", i)))

    var responses = _send(transport, server, requests^)

    assert_equal(len(responses), 6)
    for i in range(6):
        assert_equal(responses[i].status_code, 200)
        assert_true(String("i=", i) in responses[i].text())
        assert_true(String("i=", i) in String(responses[i].request().url))


def test_aio_transport_a_batch_overlaps_rather_than_taking_turns() raises:
    """The claim the async transport exists to make, timed rather than assumed.

    Every request asks the server to sit still for `DELAY_SECONDS` before it
    answers, so a batch that took its turns would take the whole of the sum. It
    takes about one delay instead.

    The bound is half of what taking turns would cost, which is a wide margin
    around the real figure and a wide margin under the wrong one. The suite runs
    on machines under load, so a bound tight enough to measure the overhead
    would be a bound that failed for reasons that have nothing to do with this
    library. What is being asserted is which of the two orders of magnitude it
    is, and that is not a close call.

    More requests than workers on purpose. If a request waiting on a socket held
    the worker it was given, the ones past the worker count could not start
    until an earlier one finished, and taking turns is exactly what that would
    look like.
    """
    # At least eight even on a machine with two workers, so that the gap
    # between overlapping and taking turns stays several seconds wide and the
    # bound below is not being asked to resolve a difference of milliseconds.
    var count = max(8, parallelism_level() * 2)
    assert_true(count > parallelism_level())

    var server = TestServer()
    var transport = AsyncHTTPTransport()

    var requests = List[Request]()
    for _ in range(count):
        requests.append(_get(server, String("/delay/", DELAY_SECONDS)))

    var started = now_ns()
    var responses = _send(transport, server, requests^)
    var elapsed = Float64(now_ns() - started) / Float64(NANOS_PER_SECOND)

    assert_equal(len(responses), count)
    for i in range(count):
        assert_equal(responses[i].status_code, 200)

    var taking_turns = Float64(count) * DELAY_SECONDS
    assert_true(
        elapsed < taking_turns / 2.0,
        String(
            count,
            " requests of ",
            DELAY_SECONDS,
            " seconds each took ",
            elapsed,
            " seconds, which is not far enough under the ",
            taking_turns,
            " they would take one at a time",
        ),
    )


def test_aio_transport_a_batch_leaves_the_accounting_straight() raises:
    """Every lease taken by a batch is given back, and the sockets are kept."""
    var server = TestServer()
    var transport = AsyncHTTPTransport()

    var requests = List[Request]()
    for _ in range(4):
        requests.append(_get(server, "/get"))
    _ = _send(transport, server, requests^)

    assert_equal(transport.pool[].leased_count(), 0)
    assert_equal(transport.pool[].idle_count(), 4)


def test_aio_transport_the_first_failure_in_a_batch_is_the_one_raised() raises:
    """One bad address among good ones, and nothing left leased afterwards.

    The batch still runs to the end. What is being checked is that the failure
    arrives as an exception with a reason in it, rather than as a response that
    is somehow not a response, and that the requests which did work have given
    their connections back rather than leaving the pool believing it is full.
    """
    var server = TestServer()
    var dead = dead_address()
    var transport = AsyncHTTPTransport()

    var requests = List[Request]()
    requests.append(_get(server, "/get"))
    requests.append(
        Request(
            "GET", URL(String("http://", dead.text(), ":", dead.port(), "/"))
        )
    )

    var raised = False
    try:
        _ = _send(transport, server, requests^)
    except e:
        raised = True
        assert_true(is_connect_error(e))
    assert_true(raised)
    assert_equal(transport.pool[].leased_count(), 0)


def test_aio_transport_close_releases_the_pooled_connections() raises:
    var server = TestServer()
    var transport = AsyncHTTPTransport()

    _ = _send_one(transport, server, _get(server, "/get"))
    assert_equal(transport.pool[].idle_count(), 1)

    transport.close()
    assert_equal(transport.pool[].total_count(), 0)


def test_aio_transport_sends_over_https() raises:
    """The transport carries the TLS configuration down to the pool.

    Worth its own test rather than being covered by the client one above it,
    because the wiring between the two used to drop `tls` on the floor and a
    dropped trust store looks exactly like a certificate that is not trusted.
    """
    var server = TestServer(tls=True)
    var tls = TlsConfig()
    tls.verify = TestServer.tls_verify()
    var transport = AsyncHTTPTransport(Limits(), tls^)
    var response = _send_one(
        transport, server, Request("GET", URL(server.url("/get")))
    )
    assert_equal(response.status_code, 200)
    transport.close()


def test_aio_transport_a_batch_through_a_limit_of_one_still_answers() raises:
    """A pool too small for the batch is a refusal, not a wrong answer.

    Nothing waits for a slot here, because there is nothing to wait on: the
    requests that would free a connection have not started, and the one asking
    for it is the thing that would have to give way. So the pool says so, and it
    says so before anything went out on the wire.
    """
    var server = TestServer()
    var transport = AsyncHTTPTransport(Limits(max_connections=1))

    var requests = List[Request]()
    for _ in range(3):
        requests.append(_get(server, "/get"))

    var raised = False
    try:
        _ = _send(transport, server, requests^)
    except e:
        raised = True
        assert_true(is_pool_timeout(e))
    assert_true(raised)
    # The point of the test. The first request was opened before the second one
    # was refused, and its lease has to come back even though it never ran.
    assert_equal(transport.pool[].leased_count(), 0)


def test_aio_transport_erased_dispatch_reaches_the_real_one() raises:
    var server = TestServer()
    var erased = erase_async_transport(AsyncHTTPTransport())

    var response = _send_one_erased(erased, server, _get(server, "/get"))
    assert_equal(response.status_code, 200)

    var requests = List[Request]()
    requests.append(_get(server, "/get?i=0"))
    requests.append(_get(server, "/get?i=1"))
    var responses = _send_erased(erased, server, requests^)
    assert_equal(len(responses), 2)
    assert_true("i=1" in responses[1].text())

    erased.close()


def test_aio_transport_the_erased_state_is_the_transport_that_went_in() raises:
    """Reaching back through the box, which is how a test inspects a mock."""
    var server = TestServer()
    var erased = erase_async_transport(AsyncHTTPTransport())
    _ = _send_one_erased(erased, server, _get(server, "/get"))

    assert_equal(erased.state[AsyncHTTPTransport]().pool[].idle_count(), 1)


def test_aio_transport_a_copied_handle_is_the_same_transport() raises:
    """A copy shares the pool, which is what makes it a handle and not a clone.
    """
    var server = TestServer()
    var erased = erase_async_transport(AsyncHTTPTransport())
    var other = erased.copy()

    _ = _send_one_erased(erased, server, _get(server, "/get"))

    assert_equal(other.state[AsyncHTTPTransport]().pool[].idle_count(), 1)


def _hello(var request: Request) raises -> Response:
    var content = List[UInt8]()
    content.extend(String("hello from ", request.url.path()).as_bytes())
    return Response(200, "OK", "HTTP/1.1", Headers(), content^)


def test_aio_transport_a_mock_is_an_async_transport_as_well() raises:
    """The same double serves both clients, which is the whole point of it.

    A test that had to write one mock for `Client` and another for
    `AsyncClient` would be testing two programs.
    """
    var erased = erase_async_transport(MockTransport(_hello))

    var requests = List[Request]()
    requests.append(Request("GET", URL("http://example.com/one")))
    requests.append(Request("GET", URL("http://example.com/two")))
    var responses = erased.handle_many(requests^, _deadlines())

    assert_equal(len(responses), 2)
    assert_equal(responses[0].text(), "hello from /one")
    assert_equal(responses[1].text(), "hello from /two")
    assert_equal(erased.state[MockTransport]().requests.__len__(), 2)


def test_aio_transport_a_mock_router_records_a_batch_in_order() raises:
    var router = MockRouter()
    router.add(Route.get("/one").respond(201))
    router.add(Route.get("/two").respond(202))
    var erased = erase_async_transport(router^)

    var requests = List[Request]()
    requests.append(Request("GET", URL("http://example.com/one")))
    requests.append(Request("GET", URL("http://example.com/two")))
    var responses = erased.handle_many(requests^, _deadlines())

    assert_equal(responses[0].status_code, 201)
    assert_equal(responses[1].status_code, 202)
    ref recording = erased.state[MockRouter]()
    assert_equal(recording.calls.__len__(), 2)
    assert_equal(recording.calls[0].url.path(), "/one")
    assert_equal(recording.calls[1].url.path(), "/two")
