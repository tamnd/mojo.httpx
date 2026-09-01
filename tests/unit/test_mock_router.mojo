"""Tests for the routing mock transport.

Two halves. The routing itself, which is a matching problem and is tested
directly against the router. And the router under a real client, which is the
part that matters: the point of a mock transport is that everything above it
still runs, so a redirect followed through two mocked routes and a cookie set by
one and sent by the other are what prove the seam is in the right place.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._client import Client
from httpx._io.deadline import Deadlines
from httpx._models.headers import Headers
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._models.url import URL, QueryParams
from httpx._transport.base import erase_transport
from httpx._transport.mock import MockRouter, Route


def _deadlines() -> Deadlines:
    return Deadlines.uniform(Optional[Float64](10.0))


def _send(
    mut router: MockRouter, method: StringSpan, url: StringSpan
) raises -> Response:
    return router.handle_request(Request(method, URL(url)), _deadlines())


# Matching.


def test_a_route_matches_on_method_and_path() raises:
    var router = MockRouter()
    router.add(Route.get("/users").respond_text(200, "the users"))
    var response = _send(router, "GET", "http://example.com/users")
    assert_equal(response.status_code, 200)
    assert_equal(response.text(), "the users")


def test_a_path_route_matches_any_host() raises:
    # What a test with one fake server wants, and the reason a bare path is the
    # common way to write a route.
    var router = MockRouter()
    router.add(Route.get("/ping").respond(204))
    assert_equal(_send(router, "GET", "http://a.example/ping").status_code, 204)
    assert_equal(_send(router, "GET", "http://b.example/ping").status_code, 204)


def test_an_absolute_route_pins_the_host() raises:
    var router = MockRouter()
    router.add(Route.get("http://a.example/ping").respond(204))
    assert_equal(_send(router, "GET", "http://a.example/ping").status_code, 204)
    var raised = False
    try:
        var response = _send(router, "GET", "http://b.example/ping")
        _ = response
    except e:
        raised = True
        assert_true("no route matched" in String(e))
    assert_true(raised)


def test_a_route_with_no_path_matches_a_root_request() raises:
    # `http://example.com` and `http://example.com/` name the same resource, so
    # a route written either way answers a request written the other way.
    var router = MockRouter()
    router.add(Route.get("http://example.com").respond(200))
    assert_equal(_send(router, "GET", "http://example.com/").status_code, 200)


def test_the_wrong_method_falls_through_to_the_next_route() raises:
    var router = MockRouter()
    router.add(Route.get("/thing").respond(200))
    router.add(Route.post("/thing").respond(201))
    assert_equal(_send(router, "POST", "http://x/thing").status_code, 201)


def test_the_first_matching_route_wins() raises:
    # Order is the whole disambiguation rule, so the specific routes go first.
    var router = MockRouter()
    router.add(Route.get("/thing").respond(200))
    router.add(Route.get("/thing").respond(500))
    assert_equal(_send(router, "GET", "http://x/thing").status_code, 200)


def test_a_catch_all_route_answers_what_nothing_else_did() raises:
    var router = MockRouter()
    router.add(Route.get("/known").respond(200))
    router.add(Route.any().respond(404))
    assert_equal(_send(router, "DELETE", "http://x/other").status_code, 404)


def test_an_unmatched_request_raises_and_says_what_it_was() raises:
    # Rather than answering 404, which would turn a typo in the code under test
    # into a plausible looking failure somewhere else.
    var router = MockRouter()
    router.add(Route.get("/known").respond(200))
    var raised = False
    try:
        var response = _send(router, "GET", "http://x/unknown")
        _ = response
    except e:
        raised = True
        assert_true("GET" in String(e))
        assert_true("http://x/unknown" in String(e))
    assert_true(raised)


def test_a_route_can_require_query_parameters() raises:
    var params = QueryParams()
    params = params.set("page", "2")
    var router = MockRouter()
    router.add(Route.get("/items").with_params(params^).respond(200))
    router.add(Route.any().respond(404))
    assert_equal(_send(router, "GET", "http://x/items?page=2").status_code, 200)
    assert_equal(_send(router, "GET", "http://x/items?page=1").status_code, 404)
    assert_equal(_send(router, "GET", "http://x/items").status_code, 404)


def test_required_parameters_are_a_subset_not_the_whole_query() raises:
    # A tracking parameter the test does not care about should not stop the
    # request being the request the test meant.
    var params = QueryParams()
    params = params.set("page", "2")
    var router = MockRouter()
    router.add(Route.get("/items").with_params(params^).respond(200))
    var url = "http://x/items?page=2&utm_source=mail"
    assert_equal(_send(router, "GET", url).status_code, 200)


def test_a_route_can_require_a_header() raises:
    var wanted = Headers()
    wanted["X-Key"] = "secret"
    var router = MockRouter()
    router.add(Route.get("/items").with_headers(wanted^).respond(200))
    router.add(Route.any().respond(403))
    assert_equal(_send(router, "GET", "http://x/items").status_code, 403)

    var headers = Headers()
    headers["X-Key"] = "secret"
    var request = Request("GET", URL("http://x/items"), headers^)
    var response = router.handle_request(request^, _deadlines())
    assert_equal(response.status_code, 200)


# What a route answers with.


def test_respond_json_sets_the_content_type() raises:
    var router = MockRouter()
    router.add(Route.get("/j").respond_json(200, '{"ok": true}'))
    var response = _send(router, "GET", "http://x/j")
    assert_equal(response.headers["content-type"], "application/json")
    assert_true(response.json()["ok"].as_bool())


def test_a_reply_carries_a_content_length() raises:
    # A real response says how long the body is, and a test asserting on that
    # should not have to know the answer came from a mock.
    var router = MockRouter()
    router.add(Route.get("/t").respond_text(200, "twelve bytes"))
    var response = _send(router, "GET", "http://x/t")
    assert_equal(response.headers["content-length"], "12")


def test_a_route_with_no_reply_answers_200() raises:
    var router = MockRouter()
    router.add(Route.get("/t"))
    assert_equal(_send(router, "GET", "http://x/t").status_code, 200)


def test_replies_are_used_in_order_and_the_last_one_repeats() raises:
    # The shape a retry test needs: fail once, then succeed, and keep
    # succeeding rather than running out.
    var router = MockRouter()
    router.add(Route.get("/flaky").respond(503).respond(200))
    assert_equal(_send(router, "GET", "http://x/flaky").status_code, 503)
    assert_equal(_send(router, "GET", "http://x/flaky").status_code, 200)
    assert_equal(_send(router, "GET", "http://x/flaky").status_code, 200)


# Recording.


def test_a_route_records_the_requests_it_answered() raises:
    var router = MockRouter()
    router.add(Route.get("/a").respond(200))
    router.add(Route.get("/b").respond(200))
    var first = _send(router, "GET", "http://x/a")
    _ = first
    var second = _send(router, "GET", "http://x/a")
    _ = second
    assert_equal(router.routes[0].call_count(), 2)
    assert_true(router.routes[0].called())
    assert_false(router.routes[1].called())
    assert_equal(String(router.routes[0].calls[0].url), "http://x/a")


def test_the_router_records_every_request_including_unmatched_ones() raises:
    # What did this program send is a different question from did this endpoint
    # get hit, and it is the one that finds the bug.
    var router = MockRouter()
    router.add(Route.get("/a").respond(200))
    var response = _send(router, "GET", "http://x/a")
    _ = response
    try:
        var missed = _send(router, "GET", "http://x/nowhere")
        _ = missed
    except:
        pass
    assert_equal(len(router.calls), 2)
    assert_equal(String(router.calls[1].url), "http://x/nowhere")


def test_all_called_is_false_while_a_route_is_untouched() raises:
    var router = MockRouter()
    router.add(Route.get("/a").respond(200))
    router.add(Route.get("/b").respond(200))
    var response = _send(router, "GET", "http://x/a")
    _ = response
    assert_false(router.all_called())
    var raised = False
    try:
        router.assert_all_called()
    except e:
        raised = True
        assert_true("/b" in String(e))
    assert_true(raised)
    var second = _send(router, "GET", "http://x/b")
    _ = second
    assert_true(router.all_called())
    router.assert_all_called()


def test_reset_forgets_the_calls_and_starts_the_replies_over() raises:
    var router = MockRouter()
    router.add(Route.get("/flaky").respond(503).respond(200))
    var first = _send(router, "GET", "http://x/flaky")
    _ = first
    var second = _send(router, "GET", "http://x/flaky")
    _ = second
    router.reset()
    assert_equal(len(router.calls), 0)
    assert_equal(router.routes[0].call_count(), 0)
    assert_equal(_send(router, "GET", "http://x/flaky").status_code, 503)


def test_a_routed_response_carries_the_request_that_produced_it() raises:
    var router = MockRouter()
    router.add(Route.get("/a").respond(200))
    var response = _send(router, "GET", "http://x/a")
    assert_equal(response.request().method, "GET")
    assert_equal(String(response.url()), "http://x/a")


# Under a client, which is the point of the whole thing.


def test_a_client_over_a_router_follows_a_redirect_across_two_routes() raises:
    var headers = Headers()
    headers["Location"] = "http://x/end"
    var router = MockRouter()
    router.add(Route.get("/start").respond(302, headers=headers^))
    router.add(Route.get("/end").respond_text(200, "arrived"))
    var client = Client(erase_transport(router^))
    client.follow_redirects = True
    var response = client.get("http://x/start")
    assert_equal(response.status_code, 200)
    assert_equal(response.text(), "arrived")
    assert_equal(response.history_count(), 1)


def test_a_cookie_set_by_one_route_is_sent_to_the_next() raises:
    # The client's jar is above the transport, so swapping the transport leaves
    # it running. If it did not, this would fall through to the 403.
    var set_cookie = Headers()
    set_cookie["Set-Cookie"] = "session=abc; Path=/"
    var wanted = Headers()
    wanted["Cookie"] = "session=abc"
    var router = MockRouter()
    router.add(Route.post("/login").respond(200, headers=set_cookie^))
    router.add(
        Route.get("/me").with_headers(wanted^).respond_text(200, "alice")
    )
    router.add(Route.any().respond(403))
    var client = Client(erase_transport(router^))
    var login = client.post("http://x/login")
    assert_equal(login.status_code, 200)
    var me = client.get("http://x/me")
    assert_equal(me.status_code, 200)
    assert_equal(me.text(), "alice")


def test_the_recording_can_be_read_back_after_the_client_took_it() raises:
    # A copy of the erased transport is the same transport, so the recording is
    # readable through the copy after the client has been handed the original.
    var transport = erase_transport(MockRouter())
    var handle = transport.copy()
    handle.state[MockRouter]().add(Route.get("/a").respond_text(200, "ok"))
    var client = Client(transport^)
    var response = client.get("http://x/a")
    assert_equal(response.text(), "ok")
    ref router = handle.state[MockRouter]()
    assert_equal(len(router.calls), 1)
    assert_equal(router.routes[0].call_count(), 1)
    assert_equal(String(router.calls[0].url), "http://x/a")


def test_a_client_sends_its_own_headers_through_a_router() raises:
    var wanted = Headers()
    wanted["X-Client"] = "yes"
    var router = MockRouter()
    router.add(Route.get("/a").with_headers(wanted^).respond(200))
    router.add(Route.any().respond(400))
    var headers = Headers()
    headers["X-Client"] = "yes"
    var client = Client(erase_transport(router^))
    client.headers = headers^
    var response = client.get("http://x/a")
    assert_equal(response.status_code, 200)
