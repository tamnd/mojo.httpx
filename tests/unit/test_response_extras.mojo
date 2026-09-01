"""Tests for the response accessors that are not about the body itself.

`elapsed`, `num_bytes_downloaded`, `raise_for_status` and the `Link` header. The
parsers underneath the last one are tested in `test_links.mojo`; what is tested
here is the wiring, that a response reaches them and resolves what they hand
back against the URL it came from.

The timing tests go over a real socket rather than a mock, because the thing
being pinned is that the clock stops when the body ends and not when the headers
do, and a mock has no gap between the two. They assert on ordering and on
availability rather than on a number of milliseconds, since a test that asserts
a duration is a test that fails on a loaded machine.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from httpx._client import Client
from httpx._exceptions import ErrorKind, kind_of
from httpx._models.headers import Headers
from httpx._models.response import Response
from httpx._transport.base import AnyTransport, erase_transport
from httpx._transport.mock import MockRouter, Route
from tests.support.testserver import TestServer


def _answering(
    status_code: Int,
    var content: List[UInt8] = List[UInt8](),
    var headers: Headers = Headers(),
    var reason_phrase: String = String(),
) raises -> Client:
    var router = MockRouter()
    router.add(
        Route.any().respond(status_code, content^, headers^, reason_phrase^)
    )
    return Client(erase_transport(router^))


def _bytes(text: StringSpan) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(text.as_bytes())
    return out^


def _linked(header: StringSpan) raises -> Client:
    var headers = Headers()
    headers["Link"] = String(header)
    return _answering(200, headers=headers^)


def _stream_chunked(server: TestServer, mut client: Client) raises -> Response:
    return client.stream("GET", server.url("/chunked"))


# How long the exchange took.


def test_a_buffered_response_reports_its_elapsed_time() raises:
    var client = _answering(200)
    var r = client.get("http://x/")
    # The transport handed the body back with the headers, so the exchange was
    # over before the client saw it and the clock has already stopped.
    assert_true(r.elapsed().nanoseconds > 0)


def test_a_response_built_by_hand_has_no_elapsed_time() raises:
    # It was never sent, so there is nothing to report and no honest number to
    # invent.
    var r = Response(200)
    with assert_raises():
        _ = r.elapsed()


def test_a_streamed_body_is_timed_to_its_last_byte() raises:
    var server = TestServer()
    var client = Client()
    var r = _stream_chunked(server, client)
    # Headers are in, body is not. httpx2 raises here for the same reason: a
    # number covering only the status line would hide the case worth measuring.
    with assert_raises():
        _ = r.elapsed()
    r.read()
    assert_true(r.elapsed().nanoseconds > 0)
    server.stop()


def test_closing_an_unread_stream_still_stops_the_clock() raises:
    # A caller who decided on the status line that they do not want the body
    # still had an exchange, and it still took some time.
    var server = TestServer()
    var client = Client()
    var r = _stream_chunked(server, client)
    r.close()
    assert_true(r.elapsed().nanoseconds > 0)
    server.stop()


def test_elapsed_does_not_move_after_the_exchange_ends() raises:
    var server = TestServer()
    var client = Client()
    var r = _stream_chunked(server, client)
    r.read()
    var first = r.elapsed()
    r.close()
    assert_equal(r.elapsed(), first)
    server.stop()


def test_every_hop_of_a_redirect_chain_is_timed_on_its_own() raises:
    # Per hop rather than for the chain, so a caller can see which one was slow.
    # A single total would not let them.
    var server = TestServer()
    var client = Client(follow_redirects=True)
    var r = client.get(server.url("/redirect/2"))
    assert_equal(r.history_count(), 2)
    var chain = r.history()
    assert_true(chain[0].elapsed().nanoseconds > 0)
    assert_true(chain[1].elapsed().nanoseconds > 0)
    assert_true(r.elapsed().nanoseconds > 0)
    server.stop()


# How much of the body has arrived.


def test_a_read_response_counts_its_whole_body() raises:
    var client = _answering(200, _bytes("twelve bytes"))
    var r = client.get("http://x/")
    assert_equal(r.num_bytes_downloaded(), 12)


def test_a_streamed_response_counts_nothing_until_it_is_read() raises:
    var server = TestServer()
    var client = Client()
    var r = _stream_chunked(server, client)
    assert_equal(r.num_bytes_downloaded(), 0)
    r.read()
    assert_equal(r.num_bytes_downloaded(), len(r.content()))
    server.stop()


def test_the_iterator_counts_bytes_as_they_arrive() raises:
    # The response gave the stream away, so from here the iterator is the only
    # thing that sees the bytes and the only thing that can report on them.
    var server = TestServer()
    var client = Client()
    var r = _stream_chunked(server, client)
    var chunks = r.iter_raw()
    var seen = 0
    var last = 0
    while chunks.has_next():
        seen += len(chunks.next())
        var counted = chunks.num_bytes_downloaded()
        assert_true(counted >= last)
        assert_true(counted >= seen)
        last = counted
    assert_equal(last, seen)
    assert_equal(seen, 31)
    server.stop()


# Turning a status into an error.


def test_raise_for_status_is_quiet_on_a_success() raises:
    var client = _answering(204)
    client.get("http://x/").raise_for_status()


def test_raise_for_status_names_the_status_and_the_url() raises:
    var client = _answering(404)
    var r = client.get("http://x/missing")
    var raised = False
    try:
        r.raise_for_status()
    except e:
        raised = True
        assert_true(kind_of(e) == ErrorKind.HTTP_STATUS_ERROR)
        assert_equal(
            String(e),
            (
                "HTTPStatusError: Client error '404 Not Found' for url"
                " 'http://x/missing'"
            ),
        )
    assert_true(raised)


def test_raise_for_status_uses_the_phrase_the_server_sent() raises:
    # Not the registered one. A server that answered `404 Nope` said that, and
    # reporting `Not Found` instead makes the log harder to match to the wire.
    var client = _answering(404, reason_phrase="Nope")
    var r = client.get("http://x/")
    with assert_raises(contains="'404 Nope'"):
        r.raise_for_status()


def test_a_server_error_is_named_as_one() raises:
    var client = _answering(503)
    var r = client.get("http://x/")
    with assert_raises(contains="Server error '503 Service Unavailable'"):
        r.raise_for_status()


def test_an_informational_response_is_named_as_one() raises:
    var client = _answering(103)
    var r = client.get("http://x/")
    with assert_raises(contains="Informational response '103"):
        r.raise_for_status()


def test_a_status_outside_every_class_is_named_as_invalid() raises:
    var client = _answering(600)
    var r = client.get("http://x/")
    with assert_raises(contains="Invalid status code '600'"):
        r.raise_for_status()


def test_a_redirect_that_was_not_followed_names_where_it_pointed() raises:
    # Reaching this means following was turned off, so the location is the thing
    # the caller will want next.
    var headers = Headers()
    headers["Location"] = "http://x/elsewhere"
    var client = _answering(302, headers=headers^)
    var r = client.get("http://x/")
    var raised = False
    try:
        r.raise_for_status()
    except e:
        raised = True
        assert_true("Redirect response '302 Found'" in String(e))
        assert_true("redirect location 'http://x/elsewhere'" in String(e))
    assert_true(raised)


def test_a_response_built_by_hand_cannot_raise_for_status() raises:
    # There is no URL to name, and a status error that could not say which
    # request failed would be less useful than the complaint.
    var r = Response(404)
    with assert_raises(contains="did not come from sending a request"):
        r.raise_for_status()


# The Link header.


def test_links_come_back_in_the_order_the_header_wrote_them() raises:
    var client = _linked('<http://x/1>; rel="prev", <http://x/3>; rel="next"')
    var r = client.get("http://x/2")
    var found = r.links()
    assert_equal(len(found), 2)
    assert_equal(found[0].url, "http://x/1")
    assert_equal(found[1].url, "http://x/3")


def test_link_url_finds_the_relation_and_hands_back_a_url() raises:
    var client = _linked('<http://x/3>; rel="next"')
    var r = client.get("http://x/2")
    var found = r.link_url("next")
    assert_true(found)
    assert_equal(String(found.value()), "http://x/3")


def test_link_url_resolves_a_relative_target() raises:
    # The part httpx2 leaves to the caller, who then has to remember to do it.
    var client = _linked("</items?page=3>; rel=next")
    var r = client.get("http://x/items?page=2")
    assert_equal(String(r.link_url("next").value()), "http://x/items?page=3")


def test_link_url_is_nothing_when_no_link_carries_that_relation() raises:
    var client = _linked('<http://x/3>; rel="next"')
    var r = client.get("http://x/2")
    assert_false(Bool(r.link_url("last")))


def test_a_response_with_no_link_header_has_no_links() raises:
    var client = _answering(200)
    var r = client.get("http://x/")
    assert_equal(len(r.links()), 0)
    assert_false(Bool(r.link_url("next")))
