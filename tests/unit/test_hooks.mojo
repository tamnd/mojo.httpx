"""Tests for event hooks.

The interesting questions are all about when a hook runs rather than whether it
runs at all. Once per send, which means once per redirect hop and once per auth
retry rather than once per call. In order. With the request the transport is
about to be handed, not the one the caller wrote. And with the response before
its body has been read, so a hook can stream it.

The last one here is about failure. A hook that raises has taken the response
with it, so the connection is released by destruction rather than by anybody
remembering to close it, and the error reaches the caller rather than being
swallowed into a half sent request.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._auth import basic_auth, digest_auth
from httpx._client import Client
from httpx._exceptions import ErrorKind, kind_of
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
from httpx._models.url import URL

from tests.support.testserver import TestServer


struct _SeenRequests(Movable, RequestHook):
    """Records the URL of every request that went past."""

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


struct _Stamp(Movable, RequestHook):
    """Adds a header, to prove a hook can change what is sent."""

    var value: String

    def __init__(out self, value: StringSpan):
        self.value = String(value)

    def on_request(mut self, var request: Request) raises -> Request:
        request.headers["X-Stamp"] = self.value
        return request^


struct _Refuse(Movable, ResponseHook):
    """Raises on every response, the way a `raise_for_status` hook would."""

    def __init__(out self):
        pass

    def on_response(mut self, var response: Response) raises -> Response:
        raise Error("RuntimeError: the hook refused this response")


struct _ReadsTheBody(Movable, ResponseHook):
    var lengths: List[Int]

    def __init__(out self):
        self.lengths = List[Int]()

    def on_response(mut self, var response: Response) raises -> Response:
        response.read()
        self.lengths.append(len(response.content()))
        return response^


def _get(
    mut client: Client, server: TestServer, path: StringSpan
) raises -> Response:
    """One request to `server`, with the server held alive for the whole call.
    """
    return client.get(server.url(path))


def _follow(
    mut client: Client, server: TestServer, path: StringSpan
) raises -> Response:
    return client.get(server.url(path), follow_redirects=True)


# The plain function spelling.


def _tag(var request: Request) raises -> Request:
    request.headers["X-Tagged"] = "yes"
    return request^


def test_a_plain_function_hook_can_change_the_request() raises:
    var server = TestServer()
    var hooks = EventHooks()
    hooks.on_request(_tag)
    var client = Client(event_hooks=hooks^)
    var response = _get(client, server, "/headers")
    assert_true('"x-tagged": "yes"' in response.text().lower())
    server.stop()


def test_an_empty_hook_list_changes_nothing() raises:
    var server = TestServer()
    var client = Client()
    assert_equal(len(client.event_hooks), 0)
    var response = _get(client, server, "/headers")
    assert_equal(response.status_code, 200)
    server.stop()


# Ordering and counting.


def test_a_request_hook_runs_once_per_request() raises:
    var server = TestServer()
    var recorder = erase_request_hook(_SeenRequests())
    var handle = recorder.copy()
    var hooks = EventHooks()
    hooks.request.append(recorder^)
    var client = Client(event_hooks=hooks^)
    var first = _get(client, server, "/headers")
    _ = first
    var second = _get(client, server, "/headers")
    _ = second
    assert_equal(len(handle.state[_SeenRequests]().urls), 2)
    server.stop()


def test_a_request_hook_runs_for_every_redirect_hop() raises:
    var server = TestServer()
    var recorder = erase_request_hook(_SeenRequests())
    var handle = recorder.copy()
    var hooks = EventHooks()
    hooks.request.append(recorder^)
    var client = Client(event_hooks=hooks^)
    var response = _follow(client, server, "/redirect/2")
    assert_equal(response.status_code, 200)
    # Three sends: the first request and the two hops it was redirected on.
    ref urls = handle.state[_SeenRequests]().urls
    assert_equal(len(urls), 3)
    assert_true(urls[0] != urls[1])
    server.stop()


def test_a_response_hook_sees_the_redirects_as_well() raises:
    var server = TestServer()
    var recorder = erase_response_hook(_SeenResponses())
    var handle = recorder.copy()
    var hooks = EventHooks()
    hooks.response.append(recorder^)
    var client = Client(event_hooks=hooks^)
    var response = _follow(client, server, "/redirect/1")
    _ = response
    ref codes = handle.state[_SeenResponses]().codes
    assert_equal(len(codes), 2)
    assert_equal(codes[0], 302)
    assert_equal(codes[1], 200)
    server.stop()


def test_a_hook_sees_the_401_an_auth_scheme_answered() raises:
    var server = TestServer()
    var recorder = erase_response_hook(_SeenResponses())
    var handle = recorder.copy()
    var hooks = EventHooks()
    hooks.response.append(recorder^)
    var client = Client(event_hooks=hooks^, auth=digest_auth("alice", "s3cret"))
    # Digest cannot answer until it has been challenged, so this is two sends
    # for one call and a hook that only saw the successful one would be a hook
    # that could not count round trips.
    var response = _get(client, server, "/digest-auth/auth/alice/s3cret")
    assert_equal(response.status_code, 200)
    ref codes = handle.state[_SeenResponses]().codes
    assert_equal(len(codes), 2)
    assert_equal(codes[0], 401)
    assert_equal(codes[1], 200)
    server.stop()


def test_basic_auth_costs_one_send_and_the_hook_agrees() raises:
    var server = TestServer()
    var recorder = erase_response_hook(_SeenResponses())
    var handle = recorder.copy()
    var hooks = EventHooks()
    hooks.response.append(recorder^)
    var client = Client(event_hooks=hooks^, auth=basic_auth("alice", "s3cret"))
    var response = _get(client, server, "/basic-auth/alice/s3cret")
    assert_equal(response.status_code, 200)
    assert_equal(len(handle.state[_SeenResponses]().codes), 1)
    server.stop()


def test_hooks_run_in_the_order_they_were_added() raises:
    var server = TestServer()
    var hooks = EventHooks()
    hooks.request.append(erase_request_hook(_Stamp("first")))
    hooks.request.append(erase_request_hook(_Stamp("second")))
    var client = Client(event_hooks=hooks^)
    var response = _get(client, server, "/headers")
    # The second one overwrote the first, so the value that arrived says which
    # ran last.
    assert_true('"x-stamp": "second"' in response.text().lower())
    server.stop()


# What a hook can do.


def test_a_request_hook_sees_the_merged_request_not_the_written_one() raises:
    var server = TestServer()
    var recorder = erase_request_hook(_SeenRequests())
    var handle = recorder.copy()
    var hooks = EventHooks()
    hooks.request.append(recorder^)
    var headers = Headers()
    headers["X-Client"] = "yes"
    var client = Client(headers=headers^, event_hooks=hooks^)
    var response = _get(client, server, "/headers")
    # The hook ran on the request that was about to go out, so the client level
    # header the caller never wrote on this call is already on it.
    assert_true('"x-client": "yes"' in response.text().lower())
    assert_equal(len(handle.state[_SeenRequests]().urls), 1)
    server.stop()


def test_a_response_hook_can_read_the_body() raises:
    var server = TestServer()
    var reader = erase_response_hook(_ReadsTheBody())
    var handle = reader.copy()
    var hooks = EventHooks()
    hooks.response.append(reader^)
    var client = Client(event_hooks=hooks^)
    var response = _get(client, server, "/headers")
    ref lengths = handle.state[_ReadsTheBody]().lengths
    assert_equal(len(lengths), 1)
    assert_true(lengths[0] > 0)
    # And the caller still gets it, because reading buffers rather than consumes.
    assert_equal(len(response.content()), lengths[0])
    server.stop()


def test_a_hook_that_raises_stops_the_call() raises:
    var server = TestServer()
    var hooks = EventHooks()
    hooks.response.append(erase_response_hook(_Refuse()))
    var client = Client(event_hooks=hooks^)
    var raised = False
    try:
        var response = _get(client, server, "/headers")
        _ = response
    except e:
        raised = True
        assert_true("the hook refused this response" in String(e))
    assert_true(raised)
    server.stop()


def test_a_client_still_works_after_a_hook_raised() raises:
    var server = TestServer()
    var hooks = EventHooks()
    hooks.response.append(erase_response_hook(_Refuse()))
    var client = Client(event_hooks=hooks^)
    try:
        var first = _get(client, server, "/headers")
        _ = first
    except:
        pass
    # The refused response was destroyed with the hook frame, which is what
    # released its connection. If it had not been, the pool would be holding a
    # connection nobody can use and this would hang or fail.
    client.event_hooks.clear()
    var second = _get(client, server, "/headers")
    assert_equal(second.status_code, 200)
    server.stop()


# The hooks themselves, without a server.


def test_hooks_added_after_the_client_was_built_still_run() raises:
    var server = TestServer()
    var client = Client()
    client.event_hooks.on_request(_tag)
    var response = _get(client, server, "/headers")
    assert_true('"x-tagged": "yes"' in response.text().lower())
    server.stop()


def test_a_copied_hook_shares_its_state() raises:
    var hook = erase_request_hook(_SeenRequests())
    var handle = hook.copy()
    var request = Request("GET", URL("http://example.com/"))
    var passed = hook.call(request^)
    _ = passed
    assert_equal(len(handle.state[_SeenRequests]().urls), 1)


def test_copying_the_hook_list_shares_every_hook() raises:
    var hooks = EventHooks()
    hooks.request.append(erase_request_hook(_SeenRequests()))
    var other = hooks.copy()
    var request = Request("GET", URL("http://example.com/"))
    var passed = hooks.request[0].call(request^)
    _ = passed
    assert_equal(len(other.request[0].state[_SeenRequests]().urls), 1)


def test_clear_removes_both_lists() raises:
    var hooks = EventHooks()
    hooks.on_request(_tag)
    hooks.request.append(erase_request_hook(_SeenRequests()))
    hooks.response.append(erase_response_hook(_SeenResponses()))
    assert_equal(len(hooks), 3)
    hooks.clear()
    assert_equal(len(hooks), 0)
