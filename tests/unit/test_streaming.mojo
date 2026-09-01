"""Tests for a body that is still on the wire when the response comes back.

The eager path already had tests, and the iterators already had tests over
buffers. What is new here is the join between them: a real socket, a response
handed over before its body has arrived, and a connection that has to end up
back in the pool or closed rather than lost.

Every test that looks at pool counts calls `server.stop()` at the end. Not
because stopping matters to the assertion, but because Mojo ends a value's life
at its last use, and a test that stopped mentioning the server halfway through
would have shut it down while the body was still arriving.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

import httpx
from httpx._client import Client
from httpx._exceptions import ErrorKind, kind_of
from httpx._io.deadline import Deadlines
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._models.headers import Headers
from httpx._models.stream import ByteSource, ByteStream, erase_source
from httpx._models.url import URL
from httpx._transport.http import HTTPTransport

from tests.support.testserver import TestServer


def _deadlines() -> Deadlines:
    return Deadlines.uniform(Optional[Float64](10.0))


def _stream(
    mut transport: HTTPTransport, server: TestServer, path: StringSpan
) raises -> Response:
    return transport.handle_stream(
        Request("GET", URL(server.url(path))), _deadlines()
    )


def _get(
    mut transport: HTTPTransport, server: TestServer, path: StringSpan
) raises -> Response:
    return transport.handle_request(
        Request("GET", URL(server.url(path))), _deadlines()
    )


def _drain(mut response: Response) raises -> List[UInt8]:
    var out = List[UInt8]()
    var chunks = response.iter_raw()
    while chunks.has_next():
        out.extend(Span(chunks.next()))
    return out^


def _count_chunks(mut response: Response) raises -> Int:
    var seen = 0
    var chunks = response.iter_raw()
    while chunks.has_next():
        _ = chunks.next()
        seen += 1
    return seen


def _status_only(
    mut transport: HTTPTransport, server: TestServer, path: StringSpan
) raises -> Int:
    """Stream a response, look at the status line, and drop it unread.

    The dropping is the point, and it has to happen inside a function so that
    the response really is destroyed before the caller checks the pool.
    """
    var response = _stream(transport, server, path)
    return response.status_code


def test_a_streamed_response_arrives_before_its_body() raises:
    # The whole claim of streaming, stated as an assertion. The head is here,
    # the status and the headers can be read, and the body is not in memory.
    var server = TestServer()
    var transport = HTTPTransport()
    var response = _stream(transport, server, "/bytes/64")

    assert_equal(response.status_code, 200)
    assert_equal(response.headers["content-type"], "application/octet-stream")
    assert_false(response.is_closed)
    assert_false(response.is_stream_consumed)

    with assert_raises(contains="has not been read"):
        _ = response.content()

    response.read()
    assert_equal(len(response.content()), 64)
    server.stop()


def test_a_streamed_body_matches_the_eager_one() raises:
    # Two ways down to the same bytes. If the framing were read differently on
    # the streaming path this is what would catch it.
    var server = TestServer()
    var transport = HTTPTransport()
    var eager = _get(transport, server, "/bytes/300")
    var streamed = _stream(transport, server, "/bytes/300")
    var chunked = _drain(streamed)

    assert_equal(len(chunked), 300)
    var same = True
    for i in range(300):
        if chunked[i] != eager.content()[i]:
            same = False
    assert_true(same)
    server.stop()


def test_a_chunked_body_streams_out_of_the_chunks() raises:
    var server = TestServer()
    var transport = HTTPTransport()
    var response = _stream(transport, server, "/chunked")
    var body = _drain(response)
    assert_equal(
        String(StringSpan(unsafe_from_utf8=Span(body))),
        "chunk one chunk two chunk three",
    )
    server.stop()


def test_a_streamed_body_comes_out_in_more_than_one_piece() raises:
    # Not a strict guarantee of the protocol, but it is what makes streaming
    # worth having, and a change that quietly buffered the whole body before
    # handing over the first chunk would show up here as a count of one.
    var server = TestServer()
    var transport = HTTPTransport()
    var response = _stream(transport, server, "/stream-bytes/65536")
    assert_true(_count_chunks(response) > 1)
    server.stop()


def test_trailers_arrive_on_a_streamed_response() raises:
    var server = TestServer()
    var transport = HTTPTransport()
    var response = _stream(transport, server, "/trailers")
    response.read()
    assert_equal(response.text(), "hello")
    assert_equal(response.trailers["x-checksum"], "abc123")
    server.stop()


def test_a_body_framed_by_the_close_streams_to_the_end() raises:
    var server = TestServer()
    var transport = HTTPTransport()
    var response = _stream(transport, server, "/no-length")
    var body = _drain(response)
    assert_equal(
        String(StringSpan(unsafe_from_utf8=Span(body))),
        "this ends when the connection does",
    )
    server.stop()


def test_the_connection_stays_out_of_the_pool_until_the_body_ends() raises:
    var server = TestServer()
    var transport = HTTPTransport()
    var response = _stream(transport, server, "/bytes/64")

    assert_equal(transport.pool[].leased_count(), 1)
    assert_equal(transport.pool[].idle_count(), 0)

    response.read()

    assert_equal(transport.pool[].leased_count(), 0)
    assert_equal(transport.pool[].idle_count(), 1)
    server.stop()


def test_a_connection_returned_by_a_stream_is_used_again() raises:
    # The proof that the give back is a real return to the pool rather than a
    # count going down. The server tells us which connection answered.
    var server = TestServer()
    var transport = HTTPTransport()
    var first = _stream(transport, server, "/conn")
    first.read()
    var second = _get(transport, server, "/conn")

    assert_equal(first.headers["x-conn-id"], second.headers["x-conn-id"])
    assert_equal(transport.pool[].total_count(), 1)
    server.stop()


def test_closing_a_streamed_response_early_drops_the_connection() raises:
    # Closed rather than pooled, and deliberately so: the rest of the body is
    # still on the wire, and a connection whose next byte is the middle of an
    # old response is not one to hand to the next request.
    var server = TestServer()
    var transport = HTTPTransport()
    var response = _stream(transport, server, "/bytes/4096")
    response.close()

    assert_equal(transport.pool[].leased_count(), 0)
    assert_equal(transport.pool[].idle_count(), 0)
    server.stop()


def test_dropping_a_streamed_response_gives_the_lease_back() raises:
    # Without the destructor on the source this is the test that fails: the
    # socket would be closed by its own destructor but the pool would go on
    # counting it as in use, and a program that abandoned a few responses would
    # be told its pool was full when it was empty.
    var server = TestServer()
    var transport = HTTPTransport()
    assert_equal(_status_only(transport, server, "/bytes/4096"), 200)

    assert_equal(transport.pool[].leased_count(), 0)
    assert_equal(transport.pool[].idle_count(), 0)
    server.stop()


def test_a_response_that_says_close_is_not_pooled_after_streaming() raises:
    var server = TestServer()
    var transport = HTTPTransport()
    var response = _stream(transport, server, "/close")
    response.read()

    assert_equal(response.text(), '{"closed": true}')
    assert_equal(transport.pool[].total_count(), 0)
    server.stop()


def test_a_streamed_body_can_only_be_read_once() raises:
    var server = TestServer()
    var transport = HTTPTransport()
    var response = _stream(transport, server, "/bytes/16")
    _ = _drain(response)

    var raised = False
    try:
        _ = response.iter_raw()
    except e:
        raised = True
        assert_true(kind_of(e) == ErrorKind.STREAM_CONSUMED)
    assert_true(raised)
    server.stop()


def test_the_client_streams_a_response() raises:
    var server = TestServer()
    var client = Client()
    var response = client.stream("GET", server.url("/chunked"))
    var lines = List[String]()
    var chunks = response.iter_text(10)
    while chunks.has_next():
        lines.append(chunks.next())

    var joined = String()
    for piece in lines:
        joined += piece
    assert_equal(joined, "chunk one chunk two chunk three")
    server.stop()


def test_a_streamed_response_works_as_a_context_manager() raises:
    var server = TestServer()
    var client = Client()
    var body = String()
    with client.stream("GET", server.url("/chunked")) as response:
        assert_equal(response.status_code, 200)
        var chunks = response.iter_lines()
        while chunks.has_next():
            body += chunks.next()
    assert_equal(body, "chunk one chunk two chunk three")
    server.stop()


def test_the_one_shot_stream_helper_works() raises:
    var server = TestServer()
    var response = httpx.stream("GET", server.url("/bytes/32"))
    response.read()
    assert_equal(len(response.content()), 32)
    server.stop()


def test_a_streamed_head_response_has_no_body() raises:
    # The one framing rule that cannot be read off the headers. The response
    # says it has a length, and there is nothing there anyway, so a client that
    # trusted the header would hang here.
    var server = TestServer()
    var client = Client()
    var request = client.build_request("HEAD", server.url("/bytes/128"))
    var response = client.send(request^, stream=True)
    response.read()

    assert_equal(response.status_code, 200)
    assert_equal(len(response.content()), 0)
    server.stop()


struct Chunks(ByteSource, Movable):
    """A request body handed over one piece at a time.

    What a caller uploading a file or generating a body as it goes would write.
    Held as a list so a test can say exactly how the body is cut up, which is
    what decides how many chunks go on the wire.
    """

    var _pieces: List[List[UInt8]]
    var _at: Int

    def __init__(out self, var pieces: List[List[UInt8]]):
        self._pieces = pieces^
        self._at = 0

    def read_chunk(mut self) raises -> List[UInt8]:
        if self._at >= len(self._pieces):
            return List[UInt8]()
        var out = self._pieces[self._at].copy()
        self._at += 1
        return out^

    def close(mut self):
        self._at = len(self._pieces)

    def trailers(self) -> Headers:
        return Headers()


struct FailingChunks(ByteSource, Movable):
    """Sends one piece and then the upload falls over."""

    var _sent: Bool

    def __init__(out self):
        self._sent = False

    def read_chunk(mut self) raises -> List[UInt8]:
        if self._sent:
            raise Error("the file being uploaded went away")
        self._sent = True
        var out = List[UInt8]()
        out.extend("first".as_bytes())
        return out^

    def close(mut self):
        pass

    def trailers(self) -> Headers:
        return Headers()


def _body_of(*parts: StringSpan) raises -> ByteStream:
    var pieces = List[List[UInt8]]()
    for part in parts:
        var piece = List[UInt8]()
        piece.extend(part.as_bytes())
        pieces.append(piece^)
    return erase_source(Chunks(pieces^))


def _empty_body() raises -> ByteStream:
    """The variadic helper above cannot be called with nothing."""
    return erase_source(Chunks(List[List[UInt8]]()))


def test_a_streaming_request_body_arrives_whole() raises:
    var server = TestServer()
    var client = Client()
    var response = client.post(
        server.url("/echo"),
        content_stream=Optional[ByteStream](_body_of("one ", "two ", "three")),
    )
    assert_equal(response.status_code, 200)
    assert_equal(response.text(), "one two three")
    server.stop()


def test_a_streaming_request_body_goes_out_chunked() raises:
    # No length is known when the head is written, so chunked is the only
    # framing available. The server tells us what it saw.
    var server = TestServer()
    var client = Client()
    var response = client.post(
        server.url("/post"),
        content_stream=Optional[ByteStream](_body_of("a", "b")),
    )
    var seen = response.text()
    assert_true('"Transfer-Encoding": "chunked"' in seen)
    assert_true('"Content-Length"' not in seen)
    assert_true('"data": "ab"' in seen)
    server.stop()


def test_a_streaming_body_with_a_declared_length_is_not_chunked() raises:
    # A caller who knows the size says so and gets a length framed body. Worth
    # having because some servers and more proxies still handle chunked request
    # bodies badly.
    var server = TestServer()
    var client = Client()
    var headers = Headers()
    headers["Content-Length"] = "6"
    var response = client.post(
        server.url("/post"),
        content_stream=Optional[ByteStream](_body_of("abc", "def")),
        headers=headers^,
    )
    var seen = response.text()
    assert_true('"Content-Length": "6"' in seen)
    assert_true('"Transfer-Encoding"' not in seen)
    assert_true('"data": "abcdef"' in seen)
    server.stop()


def test_an_empty_streaming_body_still_ends_the_message() raises:
    # The terminal chunk has to go out even when nothing before it did, or the
    # server waits for a body that is already over.
    var server = TestServer()
    var client = Client()
    var response = client.post(
        server.url("/echo"),
        content_stream=Optional[ByteStream](_empty_body()),
    )
    assert_equal(response.status_code, 200)
    assert_equal(len(response.content()), 0)
    server.stop()


def test_a_streaming_body_can_be_sent_to_a_streaming_response() raises:
    var server = TestServer()
    var client = Client()
    var body = String()
    with client.stream(
        "POST",
        server.url("/echo"),
        content_stream=Optional[ByteStream](_body_of("up", "load")),
    ) as response:
        var chunks = response.iter_text()
        while chunks.has_next():
            body += chunks.next()
    assert_equal(body, "upload")
    server.stop()


def test_a_request_with_a_streaming_body_says_it_has_one() raises:
    var request = Request.streaming(
        "POST", URL("http://example.com/"), _body_of("x")
    )
    assert_true(request.has_body())
    assert_true(request.has_stream())


def test_a_copy_of_a_streaming_request_cannot_be_sent() raises:
    # The rule that makes a redirect or a retry of a streamed upload an error
    # rather than an empty body arriving at the new location.
    var request = Request.streaming(
        "POST", URL("http://example.com/"), _body_of("x")
    )
    var second = request.copy()
    assert_true(second.has_stream() == False)

    var raised = False
    try:
        _ = second.take_stream()
    except e:
        raised = True
        assert_true(kind_of(e) == ErrorKind.REQUEST_NOT_READ)
        assert_true("cannot be sent again" in String(e))
    assert_true(raised)


def test_a_body_that_fails_partway_closes_the_connection() raises:
    # Half the body is already on the wire and there is no taking it back, so
    # the connection cannot be reused whatever happens next.
    var server = TestServer()
    var transport = HTTPTransport()
    var request = Request.streaming(
        "POST", URL(server.url("/echo")), erase_source(FailingChunks())
    )
    var raised = False
    try:
        _ = transport.handle_request(request^, _deadlines())
    except e:
        raised = True
        assert_true("went away" in String(e))
    assert_true(raised)
    assert_equal(transport.pool[].total_count(), 0)
    server.stop()
