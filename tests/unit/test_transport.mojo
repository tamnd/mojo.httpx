"""Tests for the transport boundary and the erasure that makes it pluggable.

Two things to prove. That a transport can be swapped for one that never touches
a socket, which is what makes testing an application against this library
bearable. And that the vtable really reaches the concrete type underneath, in
both directions, because a dispatch that quietly went to the wrong place would
show up as a hang or a wrong answer somewhere far from here.
"""

from std.testing import assert_equal, assert_true

from httpx._io.deadline import Deadlines
from httpx._models.headers import Headers
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._models.url import URL
from httpx._pool.limits import Limits
from httpx._transport.base import AnyTransport, Transport, erase_transport
from httpx._transport.http import HTTPTransport
from httpx._transport.mock import MockTransport
from httpx._util.erase import ErasedBox

from tests.support.testserver import TestServer


def _deadlines() -> Deadlines:
    return Deadlines.uniform(Optional[Float64](10.0))


def _text(var body: String) raises -> Response:
    var content = List[UInt8]()
    content.extend(body.as_bytes())
    return Response(200, "OK", "HTTP/1.1", Headers(), content^)


def _hello(var request: Request) raises -> Response:
    return _text(String("hello from ", request.url.path()))


def _teapot(var request: Request) raises -> Response:
    var response = _text(String("no coffee"))
    response.status_code = 418
    return response^


struct Recorder(Transport):
    """A transport that counts what was asked of it, through a shared box.

    The count is in an `ErasedBox` so the test can still see it after the
    transport has been moved into an `AnyTransport` and is no longer nameable.
    """

    var counts: ErasedBox

    def __init__(out self, var counts: ErasedBox):
        self.counts = counts^

    def handle_request(
        mut self, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        self.counts.get[Int]() += 1
        return _text(String("recorded"))

    def handle_stream(
        mut self, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        return self.handle_request(request^, deadlines)

    def close(mut self):
        self.counts.get[Int]() += 100


def _get(
    mut transport: HTTPTransport, server: TestServer, path: StringSpan
) raises -> Response:
    """One request to `server`, with the server held alive for the whole call.

    The server is a parameter rather than something inlined into the URL
    because Mojo ends a value's life at its last use, so a test that built the
    URL and then made the request would have shut the server down in between.
    """
    return transport.handle_request(
        Request("GET", URL(server.url(path))), _deadlines()
    )


def _get_erased(
    mut transport: AnyTransport, server: TestServer, path: StringSpan
) raises -> Response:
    return transport.handle_request(
        Request("GET", URL(server.url(path))), _deadlines()
    )


def _request(path: StringSpan) raises -> Request:
    return Request("GET", URL(String("http://example.invalid", path)))


def test_a_mock_transport_answers_without_a_network() raises:
    var transport = MockTransport(_hello)
    var response = transport.handle_request(_request("/greet"), _deadlines())
    assert_equal(response.status_code, 200)
    assert_equal(response.text(), "hello from /greet")


def test_a_mock_transport_records_what_it_was_given() raises:
    var transport = MockTransport(_hello)
    _ = transport.handle_request(_request("/one"), _deadlines())
    _ = transport.handle_request(_request("/two"), _deadlines())
    assert_equal(len(transport.requests), 2)
    assert_equal(transport.requests[0].url.path(), "/one")
    assert_equal(transport.requests[1].url.path(), "/two")


def test_an_erased_transport_still_answers() raises:
    var transport = erase_transport[MockTransport](MockTransport(_hello))
    var response = transport.handle_request(_request("/erased"), _deadlines())
    assert_equal(response.text(), "hello from /erased")


def test_erasure_reaches_the_concrete_transport() raises:
    # The dispatch has to land on this type's method rather than on some
    # default, so the assertion is on something only this transport does.
    var counts = ErasedBox.make[Int](0)
    var transport = erase_transport[Recorder](Recorder(counts.copy()))
    _ = transport.handle_request(_request("/"), _deadlines())
    _ = transport.handle_request(_request("/"), _deadlines())
    assert_equal(counts.get[Int](), 2)


def test_closing_an_erased_transport_reaches_it_too() raises:
    var counts = ErasedBox.make[Int](0)
    var transport = erase_transport[Recorder](Recorder(counts.copy()))
    transport.close()
    assert_equal(counts.get[Int](), 100)


def test_a_copied_handle_drives_the_same_transport() raises:
    # What a second client built from one transport gets. Sharing is the point:
    # two handles on separate copies would be two connection pools and twice
    # the connection limit.
    var counts = ErasedBox.make[Int](0)
    var transport = erase_transport[Recorder](Recorder(counts.copy()))
    var second = transport.copy()
    _ = transport.handle_request(_request("/"), _deadlines())
    _ = second.handle_request(_request("/"), _deadlines())
    assert_equal(counts.get[Int](), 2)


def test_transports_of_different_types_live_in_one_list() raises:
    # The reason for erasure at all. `mounts` is a list of transports chosen at
    # runtime, and without this it could only hold one type.
    var counts = ErasedBox.make[Int](0)
    var transports = List[AnyTransport]()
    transports.append(erase_transport[MockTransport](MockTransport(_hello)))
    transports.append(erase_transport[MockTransport](MockTransport(_teapot)))
    transports.append(erase_transport[Recorder](Recorder(counts.copy())))

    assert_equal(
        transports[0].handle_request(_request("/a"), _deadlines()).text(),
        "hello from /a",
    )
    assert_equal(
        transports[1].handle_request(_request("/b"), _deadlines()).status_code,
        418,
    )
    assert_equal(
        transports[2].handle_request(_request("/c"), _deadlines()).text(),
        "recorded",
    )
    assert_equal(counts.get[Int](), 1)


def test_the_http_transport_reaches_a_real_server() raises:
    var server = TestServer()
    var transport = HTTPTransport()
    var response = _get(transport, server, "/get")
    assert_equal(response.status_code, 200)
    assert_true('"method": "GET"' in response.text())
    assert_equal(transport.pool[].idle_count(), 1)


def test_the_http_transport_pools_across_requests() raises:
    var server = TestServer()
    var transport = HTTPTransport()
    var first = _get(transport, server, "/conn")
    var second = _get(transport, server, "/conn")
    assert_equal(first.headers["x-conn-id"], second.headers["x-conn-id"])
    assert_equal(transport.pool[].total_count(), 1)


def test_closing_the_http_transport_drops_its_connections() raises:
    var server = TestServer()
    var transport = HTTPTransport()
    _ = _get(transport, server, "/get")
    assert_equal(transport.pool[].idle_count(), 1)
    transport.close()
    assert_equal(transport.pool[].idle_count(), 0)


def test_an_erased_http_transport_works_end_to_end() raises:
    # The whole stack as a client will use it: an erased transport, a real
    # socket, and a response that came back through the vtable.
    var server = TestServer()
    var transport = erase_transport[HTTPTransport](
        HTTPTransport(Limits(5, 2, 30.0))
    )
    var response = _get_erased(transport, server, "/get")
    assert_equal(response.status_code, 200)
    transport.close()
