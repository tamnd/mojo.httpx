"""Tests for the client, through the whole stack against a live server.

These are the tests that say the milestone is done. Everything below has its own
unit tests, so what is checked here is the joining up: that configuration set on
a client reaches the wire, that a request level value beats a client level one,
that the connection is reused between calls, and that `httpx.get` on its own
works for somebody who has read one line of the README and nothing else.

Every call that needs the server goes through a helper that takes the server as
an argument. Mojo ends a value's life at its last use, so a test that built the
URL inline in the call would have shut the server down before the request went
out, and the failure would look like a connection refused rather than like a
test written wrong.
"""

from std.testing import assert_equal, assert_false, assert_true

import httpx
from httpx._client import USER_AGENT, Client
from httpx._config import Timeout
from httpx._models.headers import Headers
from httpx._models.response import Response
from httpx._models.url import URL, QueryParams

from tests.support.testserver import TestServer


def _get(
    mut client: Client, server: TestServer, path: StringSpan
) raises -> Response:
    return client.get(server.url(path))


def _head(
    mut client: Client, server: TestServer, path: StringSpan
) raises -> Response:
    return client.head(server.url(path))


def _get_with_headers(
    mut client: Client,
    server: TestServer,
    path: StringSpan,
    var headers: Headers,
) raises -> Response:
    return client.get(server.url(path), headers=headers^)


def _get_with_timeout(
    mut client: Client,
    server: TestServer,
    path: StringSpan,
    timeout: Timeout,
) raises -> Response:
    return client.get(server.url(path), timeout=timeout)


def _post(
    mut client: Client,
    server: TestServer,
    path: StringSpan,
    body: StringSpan,
) raises -> Response:
    var content = List[UInt8]()
    content.extend(body.as_bytes())
    return client.post(server.url(path), content=content^)


def _one_shot_get(server: TestServer, path: StringSpan) raises -> Response:
    return httpx.get(server.url(path))


def _one_shot_post(
    server: TestServer, path: StringSpan, body: StringSpan
) raises -> Response:
    var content = List[UInt8]()
    content.extend(body.as_bytes())
    return httpx.post(server.url(path), content=content^)


def _client_based_at(server: TestServer) raises -> Client:
    return Client(base_url=URL(server.url("/")))


def _get_relative(
    mut client: Client, server: TestServer, path: StringSpan
) raises -> Response:
    """A GET on a relative path, with the server held alive across the call.

    The server is an argument this function does not use. It is here because
    borrowing it is what stops Mojo ending its life at the last statement that
    mentioned it, which for a relative request is not the request itself.
    """
    return client.get(path)


def _sent_header(response: Response, name: StringSpan) raises -> String:
    """One header the server says it received, out of the echoed JSON.

    Read by hand rather than with a JSON decoder because the decoder is M4 work
    and this only needs to find one quoted value in a document the test server
    wrote a moment ago.

    The search is over a lowercased copy and the value comes out of the original
    at the same offsets, because the server reports each field under the name it
    was sent with and the tests should not have to know which of those the
    client capitalised. Both strings are ASCII, so the offsets line up.
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


def test_a_get_through_the_client_returns_a_parsed_response() raises:
    var server = TestServer()
    var client = Client()
    var response = _get(client, server, "/get")
    assert_equal(response.status_code, 200)
    assert_true(response.is_success())
    assert_equal(response.http_version, "HTTP/1.1")
    assert_true(response.text().find('"method": "GET"') >= 0)
    client.close()


def test_the_top_level_get_works_with_no_client_at_all() raises:
    # The exit criterion for this milestone, in one line, which is how somebody
    # who has read the first example in the README will write it.
    var server = TestServer()
    var response = _one_shot_get(server, "/get")
    assert_equal(response.status_code, 200)


def test_the_top_level_post_sends_its_body() raises:
    var server = TestServer()
    var response = _one_shot_post(server, "/post", "hello")
    assert_equal(response.status_code, 200)
    assert_true(response.text().find('"data": "hello"') >= 0)


def test_a_head_response_has_no_body_and_does_not_hang() raises:
    # The failure this guards against is not a wrong answer, it is a client that
    # waits for a body the server described and did not send.
    var server = TestServer()
    var client = Client()
    var response = _head(client, server, "/get")
    assert_equal(response.status_code, 200)
    assert_equal(len(response.content), 0)
    assert_true(response.headers["content-length"].byte_length() > 0)
    client.close()


def test_a_post_body_reaches_the_server() raises:
    var server = TestServer()
    var client = Client()
    var response = _post(client, server, "/post", "hello world")
    assert_true(response.text().find('"data": "hello world"') >= 0)
    client.close()


def test_the_default_headers_are_sent() raises:
    var server = TestServer()
    var client = Client()
    var response = _get(client, server, "/headers")
    assert_equal(_sent_header(response, "user-agent"), USER_AGENT)
    assert_equal(_sent_header(response, "accept"), "*/*")
    # Not `gzip, deflate`. Asking for a coding this client cannot undo would
    # mean handing the caller compressed bytes and calling them the body.
    assert_equal(_sent_header(response, "accept-encoding"), "identity")
    client.close()


def test_a_client_header_is_sent_on_every_request() raises:
    var server = TestServer()
    var headers = Headers()
    headers["X-Client"] = "yes"
    var client = Client(headers=headers^)
    var first = _get(client, server, "/headers")
    var second = _get(client, server, "/headers")
    assert_equal(_sent_header(first, "x-client"), "yes")
    assert_equal(_sent_header(second, "x-client"), "yes")
    client.close()


def test_a_request_header_overrides_the_client_one() raises:
    var base = Headers()
    base["X-Which"] = "client"
    var server = TestServer()
    var client = Client(headers=base^)
    var per_call = Headers()
    per_call["X-Which"] = "request"
    var response = _get_with_headers(client, server, "/headers", per_call^)
    assert_equal(_sent_header(response, "x-which"), "request")
    client.close()


def test_a_caller_who_sets_the_user_agent_keeps_it() raises:
    var server = TestServer()
    var client = Client()
    var headers = Headers()
    headers["User-Agent"] = "something-else/1.0"
    var response = _get_with_headers(client, server, "/headers", headers^)
    assert_equal(_sent_header(response, "user-agent"), "something-else/1.0")
    client.close()


def test_a_relative_url_is_resolved_against_the_base_url() raises:
    var server = TestServer()
    var client = _client_based_at(server)
    var absolute = _get(client, server, "/get")
    assert_equal(absolute.status_code, 200)
    var relative = _get_relative(client, server, "/get")
    assert_equal(relative.status_code, 200)
    client.close()


def test_a_base_url_does_not_concatenate_paths() raises:
    # The httpx behaviour that surprises people: an absolute reference replaces
    # the whole path rather than being appended to it, because RFC 3986 says so.
    # Kept deliberately, since code written against httpx depends on it.
    var client = Client(base_url=URL("https://example.com/api"))
    var built = client.build_request("GET", "/users")
    assert_equal(String(built.url), "https://example.com/users")


def test_an_absolute_url_ignores_the_base_url() raises:
    var client = Client(base_url=URL("https://example.com/api/"))
    var built = client.build_request("GET", "http://other.test/thing")
    assert_equal(String(built.url), "http://other.test/thing")


def test_client_params_are_merged_into_every_request() raises:
    var client = Client(params=QueryParams("token=abc"))
    var built = client.build_request("GET", "https://example.com/search")
    assert_equal(String(built.url), "https://example.com/search?token=abc")


def test_request_params_win_over_client_params() raises:
    var client = Client(params=QueryParams("page=1"))
    var built = client.build_request(
        "GET", "https://example.com/list", params=QueryParams("page=2")
    )
    assert_equal(String(built.url), "https://example.com/list?page=2")


def test_a_built_request_carries_the_merged_configuration() raises:
    # `build_request` exists so a caller can see what would be sent without
    # sending it, so what it hands back has to be the finished article.
    var headers = Headers()
    headers["X-Client"] = "yes"
    var client = Client(headers=headers^)
    var built = client.build_request("get", "https://example.com/thing")
    assert_equal(built.method, "GET")
    assert_equal(built.headers["x-client"], "yes")
    assert_equal(built.headers["user-agent"], USER_AGENT)


def test_a_client_reuses_its_connection_between_requests() raises:
    # The reason `Client` exists next to `httpx.get`. The test server numbers
    # the connections it accepts and reports the id of the one being served, so
    # two requests on one client have to come back with the same id.
    var server = TestServer()
    var client = Client()
    var first = _get(client, server, "/conn")
    var second = _get(client, server, "/conn")
    assert_equal(first.text(), second.text())
    client.close()


def test_two_one_shot_calls_do_not_share_a_connection() raises:
    # The other half of the same claim, and why the helpers say to keep a client
    # as soon as there is a second request.
    var server = TestServer()
    var first = _one_shot_get(server, "/conn")
    var second = _one_shot_get(server, "/conn")
    assert_true(first.text() != second.text())


def test_a_chunked_response_is_read_whole() raises:
    var server = TestServer()
    var client = Client()
    var response = _get(client, server, "/chunked")
    assert_equal(response.status_code, 200)
    assert_true(len(response.content) > 0)
    client.close()


def test_a_request_timeout_replaces_the_client_one() raises:
    # Wholesale, not per field, which is what httpx does. A caller passing a
    # timeout for one request gets exactly the four values they wrote down.
    var server = TestServer()
    var client = Client(timeout=Timeout.uniform(Optional[Float64](5.0)))
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


def test_a_closed_client_refuses_to_send() raises:
    var client = Client()
    client.close()
    assert_true(client.is_closed())
    var raised = False
    try:
        _ = client.get("http://127.0.0.1:1/get")
    except:
        raised = True
    assert_true(raised)


def test_closing_twice_is_harmless() raises:
    var client = Client()
    client.close()
    client.close()
    assert_true(client.is_closed())


def test_a_client_can_be_used_as_a_context_manager() raises:
    # The block owns the client, so the pool and its sockets go away at the end
    # of it whether the body returned or raised.
    var server = TestServer()
    with Client() as client:
        var response = _get(client, server, "/get")
        assert_equal(response.status_code, 200)
