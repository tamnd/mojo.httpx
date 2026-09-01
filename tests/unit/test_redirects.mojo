"""Tests for following a redirect, and for what must not be carried along.

Two halves. The first works on the rules directly, because they are functions
over a request and a status code and nothing else, so a table of cases is
cheaper and clearer than a server for every one of them. The second drives a
real server, because the interesting part of a redirect chain is the part where
each hop is a real exchange and the connection has to survive being reused
between them.

The credential rules get more attention than anything else here. A redirect is
the one place an HTTP client can be talked into sending somebody's password to
an address it was not given, so the tests for stripping `Authorization` are
written against two real servers rather than against a mock, and they assert on
what the second server saw rather than on what the client believes it sent.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._client import Client
from httpx._exceptions import (
    ErrorKind,
    is_remote_protocol_error,
    kind_of,
    message_of,
)
from httpx._models.headers import Headers
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._models.stream import ByteSource, erase_source
from httpx._models.url import URL
from httpx._redirects import (
    build_redirect_request,
    is_https_redirect,
    redirect_headers,
    redirect_method,
    redirect_url,
)

from tests.support.testserver import TestServer


def _request(
    method: StringSpan, url: StringSpan, var headers: Headers = Headers()
) raises -> Request:
    return Request(method, URL(url), headers^)


struct Chunks(ByteSource, Movable):
    """A body handed out one piece at a time, so it can only be sent once."""

    var _parts: List[List[UInt8]]
    var _at: Int

    def __init__(out self, var parts: List[List[UInt8]]):
        self._parts = parts^
        self._at = 0

    def read_chunk(mut self) raises -> List[UInt8]:
        if self._at >= len(self._parts):
            return List[UInt8]()
        var out = self._parts[self._at].copy()
        self._at += 1
        return out^

    def close(mut self):
        self._at = len(self._parts)

    def trailers(self) -> Headers:
        return Headers()


def _body(*parts: StringSpan) raises -> Chunks:
    var pieces = List[List[UInt8]]()
    for part in parts:
        var one = List[UInt8]()
        one.extend(part.as_bytes())
        pieces.append(one^)
    return Chunks(pieces^)


def _get(
    mut client: Client,
    server: TestServer,
    path: StringSpan,
    var headers: Headers = Headers(),
    follow_redirects: Optional[Bool] = None,
) raises -> Response:
    """One request to `server`, with the server held alive for the whole call.

    The server is a parameter rather than something inlined into the URL because
    Mojo ends a value's life at its last use, so a test that built the URL and
    then made the request would have shut the server down in between. Every test
    below that mentions its server for the last time before the exchange is over
    calls `server.stop()` at the end for the same reason.
    """
    return client.get(
        server.url(path), headers=headers^, follow_redirects=follow_redirects
    )


def _post(
    mut client: Client,
    server: TestServer,
    path: StringSpan,
    body: StringSpan,
) raises -> Response:
    var content = List[UInt8]()
    content.extend(body.as_bytes())
    return client.post(server.url(path), content=content^)


def _get_across(
    mut client: Client,
    first: TestServer,
    second: TestServer,
    path: StringSpan,
    var headers: Headers = Headers(),
) raises -> Response:
    """A hop from `first` to `path` on `second`, both servers held alive.

    The cross origin case needs two servers rather than two paths on one,
    because the rule being tested is about the origin changing, and a client
    that got this wrong would still pass a test where it did not.
    """
    var target = second.url(path)
    return client.get(
        first.url(String("/redirect-to?url=", target)), headers=headers^
    )


def test_a_303_turns_anything_but_head_into_a_get() raises:
    assert_equal(redirect_method("POST", 303), "GET")
    assert_equal(redirect_method("PUT", 303), "GET")
    assert_equal(redirect_method("DELETE", 303), "GET")
    assert_equal(redirect_method("HEAD", 303), "HEAD")


def test_a_302_turns_anything_but_head_into_a_get() raises:
    assert_equal(redirect_method("POST", 302), "GET")
    assert_equal(redirect_method("PUT", 302), "GET")
    assert_equal(redirect_method("HEAD", 302), "HEAD")


def test_a_301_only_rewrites_a_post() raises:
    assert_equal(redirect_method("POST", 301), "GET")
    assert_equal(redirect_method("PUT", 301), "PUT")
    assert_equal(redirect_method("GET", 301), "GET")


def test_a_307_and_a_308_keep_the_method() raises:
    # The whole reason those two codes exist, so a client that rewrote them
    # would be resending a payment as a page view.
    assert_equal(redirect_method("POST", 307), "POST")
    assert_equal(redirect_method("POST", 308), "POST")
    assert_equal(redirect_method("PUT", 307), "PUT")


def test_a_relative_location_resolves_against_the_request() raises:
    var url = redirect_url(URL("http://example.com/a/b"), "../c")
    assert_equal(String(url), "http://example.com/c")


def test_an_absolute_location_replaces_everything() raises:
    var url = redirect_url(URL("http://example.com/a"), "https://other.test/z")
    assert_equal(String(url), "https://other.test/z")


def test_a_scheme_relative_location_keeps_the_scheme() raises:
    var url = redirect_url(URL("https://example.com/a"), "//other.test/z")
    assert_equal(String(url), "https://other.test/z")


def test_a_location_with_a_scheme_and_no_host_keeps_the_host() raises:
    # Malformed, and sent by real servers. What they meant is the host we were
    # already talking to over the scheme they named.
    var url = redirect_url(URL("http://example.com/a"), "https://")
    assert_equal(url.scheme(), "https")
    assert_equal(String(StringSpan(from_utf8=url.raw_host())), "example.com")


def test_a_scheme_with_no_host_but_a_path_keeps_the_host_too() raises:
    var url = redirect_url(URL("http://example.com/a"), "https:///b")
    assert_equal(url.scheme(), "https")
    assert_equal(String(StringSpan(from_utf8=url.raw_host())), "example.com")
    assert_equal(url.path(), "/b")


def test_a_path_that_merely_contains_a_scheme_marker_is_left_alone() raises:
    # The host is only filled in when the thing before `://` is a scheme. A
    # path that happens to contain those three characters is a relative
    # reference and resolves like one.
    var url = redirect_url(URL("http://example.com/a"), "/x://y")
    assert_equal(String(StringSpan(from_utf8=url.raw_host())), "example.com")
    assert_equal(url.path(), "/x://y")


def test_a_fragment_is_carried_to_the_new_url() raises:
    # Fragments never reach a server, so a redirect cannot know about one. A
    # link to `#install` that redirects should still land on `#install`.
    var url = redirect_url(URL("http://example.com/a#install"), "/b")
    assert_equal(url.fragment(), "install")


def test_a_fragment_on_the_location_wins() raises:
    var url = redirect_url(URL("http://example.com/a#one"), "/b#two")
    assert_equal(url.fragment(), "two")


def test_a_location_that_is_not_a_url_is_the_servers_fault() raises:
    var raised = False
    try:
        _ = redirect_url(URL("http://example.com/a"), "http://[")
    except e:
        raised = True
        assert_true(is_remote_protocol_error(e))
        assert_true("Invalid URL in location header" in message_of(e))
    assert_true(raised)


def test_authorization_does_not_cross_an_origin() raises:
    var headers = Headers()
    headers.append("Authorization", "Bearer hunter2")
    var request = _request("GET", "http://example.com/a", headers^)
    var out = redirect_headers(request, URL("http://other.test/b"), "GET")
    assert_false("authorization" in out)


def test_authorization_stays_within_an_origin() raises:
    var headers = Headers()
    headers.append("Authorization", "Bearer hunter2")
    var request = _request("GET", "http://example.com/a", headers^)
    var out = redirect_headers(request, URL("http://example.com/b"), "GET")
    assert_equal(out["authorization"], "Bearer hunter2")


def test_authorization_survives_an_https_upgrade() raises:
    # Same host, http to https on the default ports. The credentials go to the
    # host that already had them, over a better connection than the one they
    # arrived on.
    var headers = Headers()
    headers.append("Authorization", "Bearer hunter2")
    var request = _request("GET", "http://example.com/a", headers^)
    var out = redirect_headers(request, URL("https://example.com/a"), "GET")
    assert_equal(out["authorization"], "Bearer hunter2")


def test_an_https_upgrade_is_only_an_upgrade_on_the_same_host() raises:
    assert_true(
        is_https_redirect(
            URL("http://example.com/a"), URL("https://example.com/a")
        )
    )
    assert_false(
        is_https_redirect(
            URL("http://example.com/a"), URL("https://other.test/a")
        )
    )
    # Not a scheme upgrade at all, so it does not qualify however familiar the
    # host is.
    assert_false(
        is_https_redirect(
            URL("http://example.com/a"), URL("http://example.com/b")
        )
    )
    # A non default port is not the pair of ports this rule is about.
    assert_false(
        is_https_redirect(
            URL("http://example.com:8080/a"), URL("https://example.com/a")
        )
    )


def test_a_cookie_never_travels() raises:
    # Even to the same origin. A `Cookie` is computed for the URL being asked
    # for, and the URL has changed.
    var headers = Headers()
    headers.append("Cookie", "session=abc")
    var request = _request("GET", "http://example.com/a", headers^)
    var out = redirect_headers(request, URL("http://example.com/b"), "GET")
    assert_false("cookie" in out)


def test_a_rewrite_to_get_drops_the_framing() raises:
    var headers = Headers()
    headers.append("Content-Length", "5")
    var request = _request("POST", "http://example.com/a", headers^)
    var out = redirect_headers(request, URL("http://example.com/b"), "GET")
    assert_false("content-length" in out)
    assert_false("transfer-encoding" in out)


def test_a_kept_method_keeps_the_framing() raises:
    var headers = Headers()
    headers.append("Content-Length", "5")
    var request = _request("POST", "http://example.com/a", headers^)
    var out = redirect_headers(request, URL("http://example.com/b"), "POST")
    assert_equal(out["content-length"], "5")


def test_a_307_carries_the_body() raises:
    var body = List[UInt8]()
    body.extend("payload".as_bytes())
    var request = Request("POST", URL("http://example.com/a"), Headers(), body^)
    var following = build_redirect_request(request, 307, "/b")
    assert_equal(following.method, "POST")
    assert_equal(
        String(StringSpan(from_utf8=Span(following.content))), "payload"
    )


def test_a_303_leaves_the_body_behind() raises:
    var body = List[UInt8]()
    body.extend("payload".as_bytes())
    var request = Request("POST", URL("http://example.com/a"), Headers(), body^)
    var following = build_redirect_request(request, 303, "/b")
    assert_equal(following.method, "GET")
    assert_false(following.has_body())


def test_a_streamed_body_cannot_be_sent_to_the_new_place() raises:
    # The bytes went out as they were produced and there is nowhere to get them
    # back from, so this is an error with instructions rather than a redirect
    # that quietly uploads nothing.
    var request = Request.streaming(
        "POST", URL("http://example.com/a"), erase_source(_body("one", "two"))
    )
    _ = request.take_stream()
    var raised = False
    try:
        _ = build_redirect_request(request, 307, "/b")
    except e:
        raised = True
        assert_true(kind_of(e) == ErrorKind.REQUEST_NOT_READ)
        assert_true("content=" in message_of(e))
    assert_true(raised)


def test_a_streamed_body_is_fine_when_the_method_is_rewritten() raises:
    # A 303 drops the body, so there is nothing to replay and nothing to refuse.
    var request = Request.streaming(
        "POST", URL("http://example.com/a"), erase_source(_body("one"))
    )
    _ = request.take_stream()
    var following = build_redirect_request(request, 303, "/b")
    assert_equal(following.method, "GET")
    assert_false(following.has_body())


def test_a_redirect_is_returned_rather_than_followed_by_default() raises:
    var server = TestServer()
    var client = Client()
    var response = _get(client, server, "/redirect/1")
    assert_equal(response.status_code, 302)
    assert_equal(response.history_count(), 0)
    assert_true(response.has_next_request())
    client.close()
    server.stop()


def test_the_next_request_points_at_where_the_server_said() raises:
    var server = TestServer()
    var client = Client()
    var response = _get(client, server, "/redirect/1")
    var following = response.next_request()
    assert_equal(following.method, "GET")
    assert_equal(following.url.path(), "/get")
    client.close()
    server.stop()


def test_a_caller_can_step_through_a_chain_themselves() raises:
    var server = TestServer()
    var client = Client()
    var response = _get(client, server, "/redirect/2")
    var hops = 0
    while response.has_next_request():
        response = client.send(response.next_request())
        hops += 1
    assert_equal(hops, 2)
    assert_equal(response.status_code, 200)
    client.close()
    server.stop()


def test_a_chain_is_followed_when_asked() raises:
    var server = TestServer()
    var client = Client(follow_redirects=True)
    var response = _get(client, server, "/redirect/3")
    assert_equal(response.status_code, 200)
    assert_true('"method": "GET"' in response.text())
    client.close()
    server.stop()


def test_the_history_is_every_hop_that_led_here() raises:
    var server = TestServer()
    var client = Client(follow_redirects=True)
    var response = _get(client, server, "/redirect/3")
    assert_equal(response.history_count(), 3)
    var history = response.history()
    assert_equal(len(history), 3)
    assert_equal(history[0].status_code, 302)
    assert_equal(history[0].url().path(), "/redirect/3")
    assert_equal(history[1].url().path(), "/redirect/2")
    assert_equal(history[2].url().path(), "/redirect/1")
    client.close()
    server.stop()


def test_the_final_response_reports_where_it_ended_up() raises:
    var server = TestServer()
    var client = Client(follow_redirects=True)
    var response = _get(client, server, "/redirect/2")
    assert_equal(response.url().path(), "/get")
    client.close()
    server.stop()


def test_a_response_carries_the_request_that_produced_it() raises:
    var server = TestServer()
    var client = Client()
    var response = _get(client, server, "/get")
    assert_equal(response.request().method, "GET")
    assert_equal(response.url().path(), "/get")
    client.close()
    server.stop()


def test_following_can_be_turned_on_for_one_call() raises:
    var server = TestServer()
    var client = Client()
    var response = _get(
        client, server, "/redirect/1", follow_redirects=Optional[Bool](True)
    )
    assert_equal(response.status_code, 200)
    assert_equal(response.history_count(), 1)
    client.close()
    server.stop()


def test_following_can_be_turned_off_for_one_call() raises:
    var server = TestServer()
    var client = Client(follow_redirects=True)
    var response = _get(
        client, server, "/redirect/1", follow_redirects=Optional[Bool](False)
    )
    assert_equal(response.status_code, 302)
    client.close()
    server.stop()


def test_a_303_after_a_post_arrives_as_a_get() raises:
    var server = TestServer()
    var client = Client(follow_redirects=True)
    var response = _post(
        client, server, "/redirect-to?url=/post&status_code=303", "name=value"
    )
    var text = response.text()
    assert_equal(response.status_code, 200)
    assert_true('"method": "GET"' in text)
    # The body went nowhere, and neither did the header that described it.
    assert_true('"data": ""' in text)
    assert_false("Content-Length" in text)
    client.close()
    server.stop()


def test_a_307_after_a_post_arrives_as_a_post_with_its_body() raises:
    var server = TestServer()
    var client = Client(follow_redirects=True)
    var response = _post(
        client, server, "/redirect-to?url=/post&status_code=307", "name=value"
    )
    var text = response.text()
    assert_equal(response.status_code, 200)
    assert_true('"method": "POST"' in text)
    assert_true('"data": "name=value"' in text)
    client.close()
    server.stop()


def test_a_chain_that_never_ends_is_given_up_on() raises:
    var server = TestServer()
    var client = Client(follow_redirects=True, max_redirects=3)
    var raised = False
    try:
        _ = _get(client, server, "/redirect/10")
    except e:
        raised = True
        assert_true(kind_of(e) == ErrorKind.TOO_MANY_REDIRECTS)
        assert_equal(message_of(e), "Exceeded maximum allowed redirects.")
    assert_true(raised)
    client.close()
    server.stop()


def test_a_chain_exactly_at_the_limit_is_followed() raises:
    var server = TestServer()
    var client = Client(follow_redirects=True, max_redirects=3)
    var response = _get(client, server, "/redirect/3")
    assert_equal(response.status_code, 200)
    client.close()
    server.stop()


def test_a_followed_chain_reuses_one_connection() raises:
    # Every hop is to the same origin, so a chain of four requests should cost
    # one connection and not four. This is the reason the intermediate bodies
    # are drained rather than abandoned: a connection with an unread body left
    # on it cannot be handed back to the pool. The server labels every response
    # with the connection it came in on, so the assertion is on what actually
    # happened rather than on the pool's own bookkeeping.
    var server = TestServer()
    var client = Client(follow_redirects=True)
    var response = _get(client, server, "/redirect/3")
    assert_equal(response.status_code, 200)
    assert_true('"method": "GET"' in response.text())

    var history = response.history()
    assert_equal(len(history), 3)
    var first = history[0].headers["x-conn-id"]
    assert_true(first != "")
    for i in range(len(history)):
        assert_equal(history[i].headers["x-conn-id"], first)
    assert_equal(response.headers["x-conn-id"], first)
    client.close()
    server.stop()


def _stream_text(mut client: Client, server: TestServer) raises -> String:
    """A streamed chain, read to the end inside the `with` that owns it."""
    var text = String()
    with client.stream("GET", server.url("/redirect/2")) as response:
        assert_equal(response.status_code, 200)
        assert_equal(response.history_count(), 2)
        var chunks = response.iter_bytes()
        while chunks.has_next():
            text += StringSpan(from_utf8=Span(chunks.next()))
    return text^


def test_a_streamed_redirect_chain_only_streams_the_last_hop() raises:
    var server = TestServer()
    var client = Client(follow_redirects=True)
    var text = _stream_text(client, server)
    assert_true('"method": "GET"' in text)
    client.close()
    server.stop()


def test_credentials_are_not_handed_to_the_host_a_server_names() raises:
    # The attack this rule exists for. One server redirects to another, and the
    # header the caller set for the first must not arrive at the second. The
    # assertion is on what the second server echoed back, not on what the client
    # thinks it sent.
    var first = TestServer()
    var second = TestServer()
    var client = Client(follow_redirects=True)

    var headers = Headers()
    headers.append("Authorization", "Bearer hunter2")
    var response = _get_across(client, first, second, "/headers", headers^)
    var text = response.text()
    assert_equal(response.status_code, 200)
    assert_false("hunter2" in text)
    assert_false("Authorization" in text)
    client.close()
    first.stop()
    second.stop()


def test_credentials_survive_a_hop_within_one_origin() raises:
    var server = TestServer()
    var client = Client(follow_redirects=True)
    var headers = Headers()
    headers.append("Authorization", "Bearer hunter2")
    var response = _get(client, server, "/redirect-to?url=/headers", headers^)
    assert_true("hunter2" in response.text())
    client.close()
    server.stop()


def test_the_host_header_follows_the_new_url() raises:
    var first = TestServer()
    var second = TestServer()
    var client = Client(follow_redirects=True)
    var response = _get_across(client, first, second, "/headers")
    var text = response.text()
    assert_true(String("127.0.0.1:", second.port) in text)
    assert_false(String("127.0.0.1:", first.port) in text)
    client.close()
    first.stop()
    second.stop()
