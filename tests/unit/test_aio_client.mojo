"""Tests for the async client, which is the same client with a different pool.

The point of this file is the milestone's exit criterion: whatever `Client` does,
`AsyncClient` does. So most of what is here is a second run of the behaviours
already covered against the synchronous client, over the async transport.

That is not busywork even though the two share their implementation. Sharing it
is a claim, and the claim is worth checking, because the way the sharing is done
is a compile time parameter and a parameter that was wired up wrong would give a
client whose transport is the async one and whose redirect loop, cookie jar and
auth retries came out of a different instantiation and were never exercised.
Every one of these ran through code that has only ever been compiled for this
client.

The last few are about what the async client cannot do yet. Both of them raise
with something a reader can act on, and both are tested here so that the day
they start working, these are the tests that fail and say so.

Every call that needs the server goes through a helper taking the server as an
argument, for the reason `tests/unit/test_client.mojo` gives: Mojo ends a value's
life at its last use, and building a URL from the server is not a use of it that
outlives the request.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._aio_client import AsyncClient
from httpx._auth import basic_auth
from httpx._client import USER_AGENT
from httpx._config import Timeout
from httpx._exceptions import ErrorKind, is_invalid_argument, kind_of
from httpx._hooks import (
    EventHooks,
    RequestHook,
    ResponseHook,
    erase_request_hook,
    erase_response_hook,
)
from httpx._models.headers import Headers
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._models.url import URL, QueryParams
from httpx._transport.aio_base import erase_async_transport
from httpx._transport.mock import MockRouter, Route

from tests.support.testserver import TestServer


def _get(
    mut client: AsyncClient, server: TestServer, path: StringSpan
) raises -> Response:
    return client.get(server.url(path))


def _follow(
    mut client: AsyncClient, server: TestServer, path: StringSpan
) raises -> Response:
    return client.get(server.url(path), follow_redirects=True)


def _head(
    mut client: AsyncClient, server: TestServer, path: StringSpan
) raises -> Response:
    return client.head(server.url(path))


def _get_with_timeout(
    mut client: AsyncClient,
    server: TestServer,
    path: StringSpan,
    timeout: Timeout,
) raises -> Response:
    return client.get(server.url(path), timeout=timeout)


def _stream(
    mut client: AsyncClient, server: TestServer, path: StringSpan
) raises -> Response:
    return client.stream("GET", server.url(path))


def _get_with_headers(
    mut client: AsyncClient,
    server: TestServer,
    path: StringSpan,
    var headers: Headers,
) raises -> Response:
    return client.get(server.url(path), headers=headers^)


def _post(
    mut client: AsyncClient,
    server: TestServer,
    path: StringSpan,
    body: StringSpan,
) raises -> Response:
    var content = List[UInt8]()
    content.extend(body.as_bytes())
    return client.post(server.url(path), content=content^)


def _get_relative(
    mut client: AsyncClient, server: TestServer, path: StringSpan
) raises -> Response:
    """A GET on a relative path, with the server held alive across the call."""
    return client.get(path)


def _sent_header(response: Response, name: StringSpan) raises -> String:
    """One header the server says it received, out of the echoed JSON.

    The same by hand read as in `tests/unit/test_client.mojo`, and duplicated
    rather than shared because a test helper that hides a mistake in both files
    at once is worse than two of it.
    """
    var text = response.text()
    var lowered = text.lower()
    var needle = String('"', String(name).lower(), '": "')
    var at = lowered.find(needle)
    if at < 0:
        return String()
    var start = at + needle.byte_length()
    var end = text.find('"', start)
    if end < 0:
        return String()
    return String(text[byte=start:end])


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


def test_aio_client_a_get_returns_a_parsed_response() raises:
    var server = TestServer()
    var client = AsyncClient()
    var response = _get(client, server, "/get")
    assert_equal(response.status_code, 200)
    assert_true(response.is_success())
    assert_equal(response.http_version, "HTTP/1.1")
    assert_true('"method": "GET"' in response.text())
    client.close()


def test_aio_client_a_post_body_reaches_the_server() raises:
    var server = TestServer()
    var client = AsyncClient()
    var response = _post(client, server, "/post", "hello world")
    assert_true('"data": "hello world"' in response.text())
    client.close()


def test_aio_client_a_head_response_has_no_body_and_does_not_hang() raises:
    var server = TestServer()
    var client = AsyncClient()
    var response = _head(client, server, "/get")
    assert_equal(response.status_code, 200)
    assert_equal(len(response.content()), 0)
    assert_true(response.headers["content-length"].byte_length() > 0)
    client.close()


def test_aio_client_sends_the_default_headers() raises:
    var server = TestServer()
    var client = AsyncClient()
    var response = _get(client, server, "/headers")
    assert_equal(_sent_header(response, "user-agent"), USER_AGENT)
    assert_equal(_sent_header(response, "accept"), "*/*")
    assert_equal(_sent_header(response, "accept-encoding"), "identity")
    client.close()


def test_aio_client_a_request_header_overrides_the_client_one() raises:
    var base = Headers()
    base["X-Which"] = "client"
    var server = TestServer()
    var client = AsyncClient(headers=base^)
    var per_call = Headers()
    per_call["X-Which"] = "request"
    var response = _get_with_headers(client, server, "/headers", per_call^)
    assert_equal(_sent_header(response, "x-which"), "request")
    client.close()


def test_aio_client_resolves_a_relative_url_against_the_base_url() raises:
    var server = TestServer()
    var client = AsyncClient(base_url=URL(server.url("/")))
    var response = _get_relative(client, server, "/get")
    assert_equal(response.status_code, 200)
    client.close()


def test_aio_client_merges_client_params_into_every_request() raises:
    var client = AsyncClient(params=QueryParams("token=abc"))
    var built = client.build_request("GET", "https://example.com/search")
    assert_equal(String(built.url), "https://example.com/search?token=abc")


def test_aio_client_reuses_its_connection_between_requests() raises:
    """The reason to hold a client rather than call `httpx.get` twice.

    The same claim as on the synchronous side, and worth repeating here because
    the pool underneath is a different one. The test server numbers the
    connections it accepts and reports which is being served.
    """
    var server = TestServer()
    var client = AsyncClient()
    var first = _get(client, server, "/conn")
    var second = _get(client, server, "/conn")
    assert_equal(first.text(), second.text())
    client.close()


def test_aio_client_reads_a_chunked_response_whole() raises:
    var server = TestServer()
    var client = AsyncClient()
    var response = _get(client, server, "/chunked")
    assert_equal(response.status_code, 200)
    assert_true(len(response.content()) > 0)
    client.close()


def test_aio_client_does_not_follow_a_redirect_unless_asked() raises:
    var server = TestServer()
    var client = AsyncClient()
    var response = _get(client, server, "/redirect/1")
    assert_equal(response.status_code, 302)
    assert_true(response.has_next_request())
    client.close()


def test_aio_client_follows_a_redirect_chain_and_keeps_the_history() raises:
    var server = TestServer()
    var client = AsyncClient()
    var response = _follow(client, server, "/redirect/3")
    assert_equal(response.status_code, 200)
    assert_equal(response.history_count(), 3)
    client.close()


def test_aio_client_stops_at_the_redirect_ceiling() raises:
    var server = TestServer()
    var client = AsyncClient(max_redirects=2)
    var raised = False
    try:
        _ = _follow(client, server, "/redirect/5")
    except e:
        raised = True
        assert_true(kind_of(e) == ErrorKind.TOO_MANY_REDIRECTS)
    assert_true(raised)
    client.close()


def test_aio_client_keeps_a_cookie_the_server_set() raises:
    """The jar is client state, so this is a session and not two requests."""
    var server = TestServer()
    var client = AsyncClient()
    _ = _follow(client, server, "/cookies/set?session=abc")
    var response = _get(client, server, "/cookies")
    assert_true('"session": "abc"' in response.text())
    client.close()


def test_aio_client_authenticates_with_basic_auth() raises:
    var server = TestServer()
    var client = AsyncClient(auth=basic_auth("alice", "s3cret"))
    var response = _get(client, server, "/basic-auth/alice/s3cret")
    assert_equal(response.status_code, 200)
    assert_true('"authenticated": true' in response.text())
    client.close()


def test_aio_client_runs_the_event_hooks_once_per_hop() raises:
    """Every send, not every call, which means every redirect hop as well."""
    var server = TestServer()
    var hooks = EventHooks()
    hooks.request.append(erase_request_hook(_SeenRequests()))
    hooks.response.append(erase_response_hook(_SeenResponses()))
    var watching_requests = hooks.request[0].copy()
    var watching_responses = hooks.response[0].copy()

    var client = AsyncClient(event_hooks=hooks^)
    _ = _follow(client, server, "/redirect/2")

    assert_equal(watching_requests.state[_SeenRequests]().urls.__len__(), 3)
    ref codes = watching_responses.state[_SeenResponses]().codes
    assert_equal(codes.__len__(), 3)
    assert_equal(codes[0], 302)
    assert_equal(codes[2], 200)
    client.close()


def test_aio_client_honours_a_per_request_timeout() raises:
    var server = TestServer()
    var client = AsyncClient(timeout=Timeout.uniform(Optional[Float64](5.0)))
    var quick = Timeout(
        Optional[Float64](5.0),
        Optional[Float64](0.2),
        Optional[Float64](5.0),
        Optional[Float64](5.0),
    )
    var raised = False
    try:
        _ = _get_with_timeout(client, server, "/delay/3", quick)
    except:
        raised = True
    assert_true(raised)
    client.close()


def test_aio_client_refuses_to_send_once_closed() raises:
    var client = AsyncClient()
    client.close()
    assert_true(client.is_closed())
    var raised = False
    try:
        _ = client.get("http://127.0.0.1:1/get")
    except:
        raised = True
    assert_true(raised)


def test_aio_client_aclose_is_close_under_another_name() raises:
    """Present so httpx code reads the same here. It has to actually close."""
    var server = TestServer()
    var client = AsyncClient()
    _ = _get(client, server, "/get")
    client.aclose()
    assert_true(client.is_closed())
    client.aclose()
    assert_true(client.is_closed())


def test_aio_client_works_as_a_context_manager() raises:
    var server = TestServer()
    with AsyncClient() as client:
        var response = _get(client, server, "/get")
        assert_equal(response.status_code, 200)


def test_aio_client_takes_a_transport_the_caller_built() raises:
    """A mock under an async client, which is how most user tests will run."""
    var router = MockRouter()
    router.add(Route.get("/one").respond(201))
    var client = AsyncClient(erase_async_transport(router^))

    var response = client.get("http://example.com/one")
    assert_equal(response.status_code, 201)


def test_aio_client_refuses_https_rather_than_sending_in_the_clear() raises:
    """No async handshake yet, so the only safe answer is to say so."""
    var client = AsyncClient()
    var raised = False
    try:
        _ = client.get("https://example.com/")
    except e:
        raised = True
        assert_true(is_invalid_argument(e))
        assert_true("https" in String(e))
    assert_true(raised)
    client.close()


def test_aio_client_streams_over_a_real_connection() raises:
    """The end to end shape of it. `tests/unit/test_aio_stream.mojo` has the
    rest, including what happens to the connection afterwards."""
    var server = TestServer()
    var client = AsyncClient()
    var response = _stream(client, server, "/chunked")

    assert_equal(response.status_code, 200)
    assert_false(response.is_closed)
    response.read()
    assert_equal(response.text(), "chunk one chunk two chunk three")
    client.close()


def test_aio_client_can_stream_from_a_mock() raises:
    """A mock streams the same way a connection does, which is what lets the
    streaming tests a user writes work against either."""
    var router = MockRouter()
    router.add(Route.get("/big").respond_text(200, "stream me"))
    var client = AsyncClient(erase_async_transport(router^))

    with client.stream("GET", "http://example.com/big") as response:
        assert_equal(response.status_code, 200)
        assert_equal(response.text(), "stream me")
