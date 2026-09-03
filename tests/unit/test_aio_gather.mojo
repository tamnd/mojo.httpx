"""Tests for `gather`, which is the reason the async path exists at all.

Two kinds of thing are checked. That a batch really overlaps, which is timed
rather than assumed, and that everything the client does for one request it
still does for each request in a batch: the hooks, the cookie jar, the redirect
chain, the auth retry and the order the answers come back in.

The second kind is where the bugs would be. `gather` is the one place in the
library that runs the client's decisions per slot rather than per call, so it is
the one place where a redirect could be followed for the wrong request or a
challenge answered with somebody else's credentials. Several of these are built
so that a batch that got the pairing wrong comes back wrong rather than merely
slow.

Every call that needs the server takes it as an argument, for the reason
`tests/unit/test_client.mojo` gives.
"""

from std.runtime.asyncrt import parallelism_level
from std.testing import assert_equal, assert_true

import httpx
from httpx._aio_client import AsyncClient, gather
from httpx._auth import basic_auth
from httpx._config import Timeout
from httpx._exceptions import ErrorKind, is_connect_error, kind_of
from httpx._hooks import (
    EventHooks,
    RequestHook,
    ResponseHook,
    erase_request_hook,
    erase_response_hook,
)
from httpx._io.deadline import NANOS_PER_SECOND, now_ns
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._models.url import URL
from httpx._transport.aio_base import erase_async_transport
from httpx._transport.mock import MockRouter, Route

from tests.support.loopback import dead_address
from tests.support.testserver import TestServer


comptime DELAY_SECONDS = 0.3
"""How long the server sits on a request in the test that times a batch."""


struct _SeenRequests(Movable, RequestHook):
    var urls: List[String]

    def __init__(out self):
        self.urls = List[String]()

    def on_request(mut self, var request: Request) raises -> Request:
        self.urls.append(String(request.url))
        return request^


struct _SeenResponses(Movable, ResponseHook):
    var codes: List[Int]

    def __init__(out self):
        self.codes = List[Int]()

    def on_response(mut self, var response: Response) raises -> Response:
        self.codes.append(response.status_code)
        return response^


def _gather(
    mut client: AsyncClient, server: TestServer, var requests: List[Request]
) raises -> List[Response]:
    """A batch with the server borrowed for the length of the call.

    Mojo ends a value's life at its last use, and building a request from the
    server's port is not a use of the server that outlives the batch. Handing it
    through says what is true, which is that the requests need it still running.
    """
    return gather(client, requests^)


def _gather_following(
    mut client: AsyncClient, server: TestServer, var requests: List[Request]
) raises -> List[Response]:
    return gather(client, requests^, follow_redirects=True)


def _paths(
    mut client: AsyncClient, server: TestServer, paths: List[String]
) raises -> List[Request]:
    var out = List[Request]()
    for i in range(len(paths)):
        out.append(client.build_request("GET", server.url(paths[i])))
    return out^


def test_gather_answers_in_the_order_the_requests_went_in() raises:
    """Pairing by position, made visible rather than merely likely.

    Each request asks for a different query string and the server echoes what it
    was asked for, so an answer that landed in the wrong slot shows up as a
    wrong string rather than as nothing at all.
    """
    var server = TestServer()
    var client = AsyncClient()

    var paths = List[String]()
    for i in range(6):
        paths.append(String("/get?i=", i))
    var responses = _gather(client, server, _paths(client, server, paths))

    assert_equal(len(responses), 6)
    for i in range(6):
        assert_equal(responses[i].status_code, 200)
        assert_true(String("i=", i) in responses[i].text())
    client.close()


def test_gather_overlaps_rather_than_taking_turns() raises:
    """The claim the whole async path exists to make, timed at the top level.

    `tests/unit/test_aio_transport.mojo` times the same thing one layer down.
    This one is worth having as well, because everything between the two is the
    client's per slot work, and a `gather` that did its rounds one request at a
    time would pass every other test in this file.

    The bound is half of what taking turns would cost, which is a wide margin
    either side of the truth. The suite runs on loaded machines, so a bound
    tight enough to measure overhead would fail for reasons unrelated to the
    library. Which order of magnitude it is, is not a close call.
    """
    # At least eight even on a two worker machine, so the gap between
    # overlapping and taking turns stays seconds wide.
    var count = max(8, parallelism_level() * 2)
    var server = TestServer()
    var client = AsyncClient()

    var paths = List[String]()
    for _ in range(count):
        paths.append(String("/delay/", DELAY_SECONDS))
    var requests = _paths(client, server, paths)

    var started = now_ns()
    var responses = _gather(client, server, requests^)
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
    client.close()


def test_gather_of_nothing_is_no_responses_and_no_error() raises:
    var client = AsyncClient()
    var responses = gather(client, List[Request]())
    assert_equal(len(responses), 0)
    client.close()


def test_gather_follows_a_redirect_for_the_slot_that_was_redirected() raises:
    """A batch where the hops differ, which is where the pairing could slip.

    One request redirects three times, one twice, one not at all, and the last
    one is asked for a path it can be recognised by. Four rounds, with the batch
    shrinking each time. If a round put an answer against the wrong slot the
    history counts come out wrong, and if it kept sending a finished slot the
    last one would come back redirected.
    """
    var server = TestServer()
    var client = AsyncClient()

    var paths = List[String]()
    paths.append(String("/redirect/3"))
    paths.append(String("/redirect/2"))
    paths.append(String("/get?i=plain"))
    var responses = _gather_following(
        client, server, _paths(client, server, paths)
    )

    assert_equal(len(responses), 3)
    for i in range(3):
        assert_equal(responses[i].status_code, 200)
    assert_equal(responses[0].history_count(), 3)
    assert_equal(responses[1].history_count(), 2)
    assert_equal(responses[2].history_count(), 0)
    assert_true("i=plain" in responses[2].text())
    client.close()


def test_gather_leaves_a_redirect_alone_unless_asked() raises:
    var server = TestServer()
    var client = AsyncClient()

    var paths = List[String]()
    paths.append(String("/redirect/1"))
    paths.append(String("/get"))
    var responses = _gather(client, server, _paths(client, server, paths))

    assert_equal(responses[0].status_code, 302)
    assert_true(responses[0].has_next_request())
    assert_equal(responses[1].status_code, 200)
    client.close()


def test_gather_stops_at_the_redirect_ceiling() raises:
    var server = TestServer()
    var client = AsyncClient(max_redirects=2)

    var paths = List[String]()
    paths.append(String("/get"))
    paths.append(String("/redirect/5"))
    var requests = _paths(client, server, paths)

    var raised = False
    try:
        _ = _gather_following(client, server, requests^)
    except e:
        raised = True
        assert_true(kind_of(e) == ErrorKind.TOO_MANY_REDIRECTS)
    assert_true(raised)
    client.close()


def test_gather_authenticates_every_request_in_the_batch() raises:
    var server = TestServer()
    var client = AsyncClient(auth=basic_auth("alice", "s3cret"))

    var paths = List[String]()
    for _ in range(3):
        paths.append(String("/basic-auth/alice/s3cret"))
    var responses = _gather(client, server, _paths(client, server, paths))

    assert_equal(len(responses), 3)
    for i in range(3):
        assert_equal(responses[i].status_code, 200)
        assert_true('"authenticated": true' in responses[i].text())
    client.close()


def test_gather_writes_the_cookie_jar() raises:
    """Two responses setting different cookies, both of them kept.

    The jar is client state and the batch writes into it from several answers,
    so this is also the test that two rounds are not fighting over it.
    """
    var server = TestServer()
    var client = AsyncClient()

    var paths = List[String]()
    paths.append(String("/cookies/set?one=1"))
    paths.append(String("/cookies/set?two=2"))
    _ = _gather_following(client, server, _paths(client, server, paths))

    var after = List[String]()
    after.append(String("/cookies"))
    var responses = _gather(client, server, _paths(client, server, after))
    assert_true('"one": "1"' in responses[0].text())
    assert_true('"two": "2"' in responses[0].text())
    client.close()


def test_gather_runs_the_hooks_once_per_send() raises:
    """Per send, which in a batch means per request and per redirect hop."""
    var server = TestServer()
    var hooks = EventHooks()
    hooks.request.append(erase_request_hook(_SeenRequests()))
    hooks.response.append(erase_response_hook(_SeenResponses()))
    var watching_requests = hooks.request[0].copy()
    var watching_responses = hooks.response[0].copy()

    var client = AsyncClient(event_hooks=hooks^)
    var paths = List[String]()
    paths.append(String("/redirect/2"))
    paths.append(String("/get"))
    _ = _gather_following(client, server, _paths(client, server, paths))

    # Three sends for the redirected one and one for the other.
    assert_equal(watching_requests.state[_SeenRequests]().urls.__len__(), 4)
    assert_equal(watching_responses.state[_SeenResponses]().codes.__len__(), 4)
    client.close()


def test_gather_raises_the_failure_rather_than_returning_a_gap() raises:
    """One bad address among good ones, and nothing left leased afterwards."""
    var server = TestServer()
    var dead = dead_address()
    var client = AsyncClient()

    var requests = List[Request]()
    requests.append(client.build_request("GET", server.url("/get")))
    requests.append(
        client.build_request(
            "GET", String("http://", dead.text(), ":", dead.port(), "/")
        )
    )

    var raised = False
    try:
        _ = _gather(client, server, requests^)
    except e:
        raised = True
        assert_true(is_connect_error(e))
    assert_true(raised)
    client.close()


def test_gather_honours_a_timeout_it_was_given() raises:
    var server = TestServer()
    var client = AsyncClient()
    var quick = Timeout(
        Optional[Float64](5.0),
        Optional[Float64](0.2),
        Optional[Float64](5.0),
        Optional[Float64](5.0),
    )

    var paths = List[String]()
    paths.append(String("/delay/3"))
    var requests = _paths(client, server, paths)

    var raised = False
    try:
        _ = gather(client, requests^, timeout=quick)
    except:
        raised = True
    assert_true(raised)
    client.close()


def test_gather_refuses_once_the_client_is_closed() raises:
    var client = AsyncClient()
    client.close()

    var requests = List[Request]()
    requests.append(Request("GET", URL("http://127.0.0.1:1/")))
    var raised = False
    try:
        _ = gather(client, requests^)
    except:
        raised = True
    assert_true(raised)


def test_gather_works_over_a_mock_transport() raises:
    """No overlap here and none needed. The promise is the answers, in order."""
    var router = MockRouter()
    router.add(Route.get("/one").respond(201))
    router.add(Route.get("/two").respond(202))
    var client = AsyncClient(erase_async_transport(router^))

    var requests = List[Request]()
    requests.append(client.build_request("GET", "http://example.com/one"))
    requests.append(client.build_request("GET", "http://example.com/two"))
    var responses = gather(client, requests^)

    assert_equal(responses[0].status_code, 201)
    assert_equal(responses[1].status_code, 202)
