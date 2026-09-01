"""Tests for the client's option set.

The options that only exist once a transport can be swapped in, which is to say
the ones a network test could never reach: the transport argument itself, the
default encoding travelling from the client onto every response it produces, and
the client level auth scheme with the per call override that turns it off again.

Everything here runs over a `MockRouter`, so what is asserted is what the client
put on the wire rather than what a server made of it.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._auth import basic_auth, no_auth
from httpx._client import Client
from httpx._models.headers import Headers
from httpx._models.url import QueryParams, URL
from httpx._transport.base import erase_transport
from httpx._transport.mock import MockRouter, Route
from httpx._util.charset import DefaultEncoding


def _latin_1_body() -> List[UInt8]:
    """`café`, in Latin-1, where it is four bytes and the last one is 0xE9."""
    var out = List[UInt8]()
    out.append(UInt8(ord("c")))
    out.append(UInt8(ord("a")))
    out.append(UInt8(ord("f")))
    out.append(UInt8(0xE9))
    return out^


# The transport argument.


def test_a_transport_can_be_given_alongside_the_other_options() raises:
    # The combination that matters: a mock underneath, and everything above it
    # still configured. A transport argument that quietly reset the rest would
    # pass a test that only checked the response came back.
    var router = MockRouter()
    router.add(Route.get("/v1/things").respond_text(200, "listed"))
    router.add(Route.any().respond(404))
    var transport = erase_transport(router^)
    var handle = transport.copy()
    var headers = Headers()
    headers["X-Api-Key"] = "secret"
    var client = Client(
        transport=transport^,
        base_url=URL("http://api.example/v1/"),
        headers=headers^,
    )

    var response = client.get("things")
    assert_equal(response.status_code, 200)
    assert_equal(response.text(), "listed")

    ref sent = handle.state[MockRouter]().calls
    assert_equal(len(sent), 1)
    assert_equal(String(sent[0].url), "http://api.example/v1/things")
    assert_equal(sent[0].headers.get("x-api-key"), "secret")


def test_the_transport_only_constructor_leaves_the_rest_at_defaults() raises:
    var router = MockRouter()
    router.add(Route.any().respond(200))
    var client = Client(erase_transport(router^))
    assert_false(client.follow_redirects)
    assert_equal(client.max_redirects, 20)
    assert_false(Bool(client.auth))
    assert_equal(client.default_encoding.name, "utf-8")


def test_a_client_over_a_mock_still_reports_itself_closed() raises:
    var router = MockRouter()
    router.add(Route.any().respond(200))
    var client = Client(erase_transport(router^))
    assert_false(client.is_closed())
    client.close()
    assert_true(client.is_closed())


# The default encoding.


def test_the_client_default_encoding_reaches_the_response() raises:
    # No charset on the response, so the client's answer is the only thing that
    # can decide what the 0xE9 is.
    var headers = Headers()
    headers["Content-Type"] = "text/plain"
    var router = MockRouter()
    router.add(Route.any().respond(200, _latin_1_body(), headers^))
    var client = Client(
        transport=erase_transport(router^),
        default_encoding=DefaultEncoding("latin-1"),
    )
    assert_equal(client.get("http://x/").text(), "café")


def test_a_charset_on_the_response_beats_the_client_default() raises:
    # The server said what it sent, so the client's guess does not get a vote.
    var headers = Headers()
    headers["Content-Type"] = "text/plain; charset=iso-8859-1"
    var router = MockRouter()
    router.add(Route.any().respond(200, _latin_1_body(), headers^))
    var client = Client(
        transport=erase_transport(router^),
        default_encoding=DefaultEncoding("utf-8"),
    )
    assert_equal(client.get("http://x/").text(), "café")


def test_the_default_encoding_applies_to_every_hop_of_a_redirect() raises:
    var moved = Headers()
    moved["Location"] = "http://x/end"
    var body = Headers()
    body["Content-Type"] = "text/plain"
    var router = MockRouter()
    router.add(Route.get("/start").respond(302, headers=moved^))
    router.add(Route.get("/end").respond(200, _latin_1_body(), body^))
    var client = Client(
        transport=erase_transport(router^),
        follow_redirects=True,
        default_encoding=DefaultEncoding("latin-1"),
    )
    assert_equal(client.get("http://x/start").text(), "café")


def test_the_default_encoding_can_be_changed_after_construction() raises:
    var headers = Headers()
    headers["Content-Type"] = "text/plain"
    var router = MockRouter()
    router.add(Route.any().respond(200, _latin_1_body(), headers^))
    var client = Client(erase_transport(router^))
    client.default_encoding = DefaultEncoding("latin-1")
    assert_equal(client.get("http://x/").text(), "café")


# Auth on the client.


def test_the_client_scheme_signs_a_request_that_names_none() raises:
    var router = MockRouter()
    router.add(Route.any().respond(200))
    var transport = erase_transport(router^)
    var handle = transport.copy()
    var client = Client(
        transport=transport^,
        auth=basic_auth("alice", "hunter2"),
    )
    _ = client.get("http://x/")
    ref sent = handle.state[MockRouter]().calls
    assert_equal(
        sent[0].headers.get("authorization"), "Basic YWxpY2U6aHVudGVyMg=="
    )


def test_a_scheme_attached_after_construction_is_used() raises:
    var router = MockRouter()
    router.add(Route.any().respond(200))
    var transport = erase_transport(router^)
    var handle = transport.copy()
    var client = Client(transport^)
    _ = client.get("http://x/")
    client.auth = basic_auth("alice", "hunter2")
    _ = client.get("http://x/")

    ref sent = handle.state[MockRouter]().calls
    assert_equal(len(sent), 2)
    assert_false("authorization" in sent[0].headers)
    assert_true("authorization" in sent[1].headers)


def test_no_auth_turns_the_client_scheme_off_for_one_call() raises:
    # httpx spells this `auth=None`, which it can do because it tells `None`
    # apart from `not passed`. Here the absence already means take the client's,
    # so turning it off is a value.
    var router = MockRouter()
    router.add(Route.any().respond(200))
    var transport = erase_transport(router^)
    var handle = transport.copy()
    var client = Client(
        transport=transport^,
        auth=basic_auth("alice", "hunter2"),
    )
    _ = client.get("http://x/", auth=no_auth())
    _ = client.get("http://x/")

    ref sent = handle.state[MockRouter]().calls
    assert_false("authorization" in sent[0].headers)
    assert_true("authorization" in sent[1].headers)


def test_a_per_call_scheme_wins_over_the_client_scheme() raises:
    var router = MockRouter()
    router.add(Route.any().respond(200))
    var transport = erase_transport(router^)
    var handle = transport.copy()
    var client = Client(
        transport=transport^,
        auth=basic_auth("alice", "hunter2"),
    )
    _ = client.get("http://x/", auth=basic_auth("bob", "hunter2"))
    ref sent = handle.state[MockRouter]().calls
    assert_equal(sent[0].headers.get("authorization"), "Basic Ym9iOmh1bnRlcjI=")


def test_no_auth_on_a_client_with_no_scheme_changes_nothing() raises:
    var router = MockRouter()
    router.add(Route.any().respond(200))
    var transport = erase_transport(router^)
    var handle = transport.copy()
    var client = Client(transport^)
    var response = client.get("http://x/", auth=no_auth())
    assert_equal(response.status_code, 200)
    assert_false("authorization" in handle.state[MockRouter]().calls[0].headers)


def test_the_client_scheme_signs_every_hop_of_a_redirect() raises:
    # Auth sits outside the redirect loop, so the second hop is signed too. That
    # is httpx's behaviour and it is why a redirect to another host is a leak
    # worth knowing about.
    var moved = Headers()
    moved["Location"] = "http://x/end"
    var router = MockRouter()
    router.add(Route.get("/start").respond(302, headers=moved^))
    router.add(Route.get("/end").respond(200))
    var transport = erase_transport(router^)
    var handle = transport.copy()
    var client = Client(
        transport=transport^,
        follow_redirects=True,
        auth=basic_auth("alice", "hunter2"),
    )
    assert_equal(client.get("http://x/start").status_code, 200)

    ref sent = handle.state[MockRouter]().calls
    assert_equal(len(sent), 2)
    assert_true("authorization" in sent[0].headers)
    assert_true("authorization" in sent[1].headers)


# Merging, over a transport that records what was merged.


def test_client_params_merge_with_per_request_params() raises:
    var router = MockRouter()
    router.add(Route.any().respond(200))
    var transport = erase_transport(router^)
    var handle = transport.copy()
    var client = Client(
        transport=transport^,
        params=QueryParams().add("key", "abc"),
    )
    _ = client.get("http://x/search", params=QueryParams().add("q", "mojo"))

    ref sent = handle.state[MockRouter]().calls
    assert_equal(String(sent[0].url), "http://x/search?key=abc&q=mojo")


def test_a_per_request_header_overrides_the_client_one() raises:
    var router = MockRouter()
    router.add(Route.any().respond(200))
    var transport = erase_transport(router^)
    var handle = transport.copy()
    var client_headers = Headers()
    client_headers["Accept"] = "application/json"
    var client = Client(transport=transport^, headers=client_headers^)
    var per_call = Headers()
    per_call["Accept"] = "text/csv"
    _ = client.get("http://x/", headers=per_call^)

    ref sent = handle.state[MockRouter]().calls
    assert_equal(sent[0].headers.get("accept"), "text/csv")
