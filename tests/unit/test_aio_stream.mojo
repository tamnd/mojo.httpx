"""Tests for a body read off an async connection a chunk at a time.

The same ground `tests/unit/test_streaming.mojo` covers for the synchronous
path, run again over the async pool, because the two answer the same questions
with completely different machinery underneath. There the body is a blocking
read on a socket the response holds. Here every chunk is its own coroutine,
started and run to the end by the source, and the connection and the parser sit
in the source between chunks because a coroutine cannot hold either.

So the interesting failures are not about HTTP. They are about whether the state
that has to survive between two chunks really does: a framing that reads
correctly when the whole body arrives in one exchange and wrongly when it
arrives in eight, a connection that goes back to the pool at the right moment,
and a lease that comes back at all when a caller walks away halfway through.

Every test that looks at pool counts calls `server.stop()` at the end, and every
call that needs the server takes it as an argument, both for the reasons
`tests/unit/test_streaming.mojo` gives.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from httpx._aio_client import AsyncClient
from httpx._exceptions import ErrorKind, kind_of
from httpx._io.deadline import Deadlines
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._models.url import URL
from httpx._transport.aio_http import AsyncHTTPTransport

from tests.support.testserver import TestServer


def _deadlines() -> Deadlines:
    return Deadlines.uniform(Optional[Float64](10.0))


def _stream(
    mut transport: AsyncHTTPTransport, server: TestServer, path: StringSpan
) raises -> Response:
    return transport.handle_stream(
        Request("GET", URL(server.url(path))), _deadlines()
    )


def _get(
    mut transport: AsyncHTTPTransport, server: TestServer, path: StringSpan
) raises -> Response:
    return transport.handle_request(
        Request("GET", URL(server.url(path))), _deadlines()
    )


def _client_stream(
    mut client: AsyncClient, server: TestServer, path: StringSpan
) raises -> Response:
    return client.stream("GET", server.url(path))


def _drain(mut response: Response) raises -> List[UInt8]:
    var out = List[UInt8]()
    var chunks = response.aiter_raw()
    while chunks.has_next():
        out.extend(Span(chunks.next()))
    return out^


def _count_chunks(mut response: Response) raises -> Int:
    var seen = 0
    var chunks = response.aiter_raw()
    while chunks.has_next():
        _ = chunks.next()
        seen += 1
    return seen


def _status_only(
    mut transport: AsyncHTTPTransport, server: TestServer, path: StringSpan
) raises -> Int:
    """Stream a response, look at the status line, and drop it unread.

    The dropping is the point, and it has to happen inside a function so that
    the response really is destroyed before the caller checks the pool.
    """
    var response = _stream(transport, server, path)
    return response.status_code


def test_an_async_streamed_response_arrives_before_its_body() raises:
    var server = TestServer()
    var transport = AsyncHTTPTransport()
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


def test_an_async_streamed_body_matches_the_eager_one() raises:
    """Two ways down to the same bytes, through two different read loops.

    The buffered path reads until the body ends and the streaming path stops
    after every piece and starts again, so a framing rule that only holds when
    the whole response is read in one go comes apart here.
    """
    var server = TestServer()
    var transport = AsyncHTTPTransport()
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


def test_an_async_chunked_body_streams_out_of_the_chunks() raises:
    var server = TestServer()
    var transport = AsyncHTTPTransport()
    var response = _stream(transport, server, "/chunked")
    var body = _drain(response)
    assert_equal(
        String(StringSpan(unsafe_from_utf8=Span(body))),
        "chunk one chunk two chunk three",
    )
    server.stop()


def test_an_async_streamed_body_comes_out_in_more_than_one_piece() raises:
    """What makes this worth having, and the test a quiet buffering would fail.

    A change that read the whole body before handing over the first chunk would
    still pass every other test in this file and would show up here as a count
    of one.
    """
    var server = TestServer()
    var transport = AsyncHTTPTransport()
    var response = _stream(transport, server, "/stream-bytes/65536")
    assert_true(_count_chunks(response) > 1)
    server.stop()


def test_trailers_arrive_on_an_async_streamed_response() raises:
    var server = TestServer()
    var transport = AsyncHTTPTransport()
    var response = _stream(transport, server, "/trailers")
    response.read()
    assert_equal(response.text(), "hello")
    assert_equal(response.trailers["x-checksum"], "abc123")
    server.stop()


def test_an_async_body_framed_by_the_close_streams_to_the_end() raises:
    """The framing with no length in it, which ends at end of stream.

    Worth having here rather than only on the synchronous path, because the
    async read loop tells a socket with nothing on it yet apart from a socket
    that has closed, and getting that wrong turns this body into either a hang
    or an empty one.
    """
    var server = TestServer()
    var transport = AsyncHTTPTransport()
    var response = _stream(transport, server, "/no-length")
    var body = _drain(response)
    assert_equal(
        String(StringSpan(unsafe_from_utf8=Span(body))),
        "this ends when the connection does",
    )
    server.stop()


def test_the_async_connection_stays_out_of_the_pool_until_the_body_ends() raises:
    var server = TestServer()
    var transport = AsyncHTTPTransport()
    var response = _stream(transport, server, "/bytes/64")

    assert_equal(transport.pool[].leased_count(), 1)
    assert_equal(transport.pool[].idle_count(), 0)

    response.read()

    assert_equal(transport.pool[].leased_count(), 0)
    assert_equal(transport.pool[].idle_count(), 1)
    server.stop()


def test_an_async_connection_returned_by_a_stream_is_used_again() raises:
    """The give back is a real return to the pool rather than a count going
    down. The server tells us which connection answered."""
    var server = TestServer()
    var transport = AsyncHTTPTransport()
    var first = _stream(transport, server, "/conn")
    first.read()
    var second = _get(transport, server, "/conn")

    assert_equal(first.headers["x-conn-id"], second.headers["x-conn-id"])
    assert_equal(transport.pool[].total_count(), 1)
    server.stop()


def test_closing_an_async_streamed_response_early_drops_the_connection() raises:
    var server = TestServer()
    var transport = AsyncHTTPTransport()
    var response = _stream(transport, server, "/bytes/4096")
    response.close()

    assert_equal(transport.pool[].leased_count(), 0)
    assert_equal(transport.pool[].idle_count(), 0)
    server.stop()


def test_dropping_an_async_streamed_response_gives_the_lease_back() raises:
    """Without the destructor on the source this is the test that fails.

    The socket would be closed by its own destructor but the pool would go on
    counting it as in use, and a program that abandoned a few responses would be
    told its pool was full when it was empty.
    """
    var server = TestServer()
    var transport = AsyncHTTPTransport()
    assert_equal(_status_only(transport, server, "/bytes/4096"), 200)

    assert_equal(transport.pool[].leased_count(), 0)
    assert_equal(transport.pool[].idle_count(), 0)
    server.stop()


def test_an_async_response_that_says_close_is_not_pooled_after_streaming() raises:
    var server = TestServer()
    var transport = AsyncHTTPTransport()
    var response = _stream(transport, server, "/close")
    response.read()

    assert_equal(response.text(), '{"closed": true}')
    assert_equal(transport.pool[].total_count(), 0)
    server.stop()


def test_an_async_streamed_body_can_only_be_read_once() raises:
    var server = TestServer()
    var transport = AsyncHTTPTransport()
    var response = _stream(transport, server, "/bytes/16")
    _ = _drain(response)

    var raised = False
    try:
        _ = response.aiter_raw()
    except e:
        raised = True
        assert_true(kind_of(e) == ErrorKind.STREAM_CONSUMED)
    assert_true(raised)
    server.stop()


def test_the_async_client_streams_a_response() raises:
    var server = TestServer()
    var client = AsyncClient()
    var response = _client_stream(client, server, "/chunked")
    var joined = String()
    var chunks = response.aiter_text(10)
    while chunks.has_next():
        joined += chunks.next()

    assert_equal(joined, "chunk one chunk two chunk three")
    client.close()
    server.stop()


def test_an_async_streamed_response_works_as_a_context_manager() raises:
    var server = TestServer()
    var client = AsyncClient()
    var body = String()
    with _client_stream(client, server, "/chunked") as response:
        assert_equal(response.status_code, 200)
        var chunks = response.aiter_lines()
        while chunks.has_next():
            body += chunks.next()
    assert_equal(body, "chunk one chunk two chunk three")
    client.close()
    server.stop()


def test_an_async_streamed_head_response_has_no_body() raises:
    """The one framing rule that cannot be read off the headers.

    The response says it has a length, there is nothing there anyway, and a
    client that trusted the header would sit here until the read deadline.
    """
    var server = TestServer()
    var client = AsyncClient()
    var request = client.build_request("HEAD", server.url("/bytes/128"))
    var response = _send_streaming(client, server, request^)
    response.read()

    assert_equal(response.status_code, 200)
    assert_equal(len(response.content()), 0)
    client.close()
    server.stop()


def _send_streaming(
    mut client: AsyncClient, server: TestServer, var request: Request
) raises -> Response:
    return client.send(request^, stream=True)


def test_an_async_streamed_body_counts_the_bytes_as_they_arrive() raises:
    """What a progress bar over a streamed download reads.

    Counted by the iterator rather than by the response, because the response
    gave the stream away and cannot see another byte after that.
    """
    var server = TestServer()
    var transport = AsyncHTTPTransport()
    var response = _stream(transport, server, "/bytes/512")
    var chunks = response.aiter_raw(128)
    var seen = 0
    while chunks.has_next():
        seen += len(chunks.next())
    assert_equal(seen, 512)
    assert_equal(chunks.num_bytes_downloaded(), 512)
    server.stop()


def test_aread_and_aclose_are_the_ordinary_ones() raises:
    """Both names exist so that ported code keeps its shape."""
    var server = TestServer()
    var client = AsyncClient()
    var response = _client_stream(client, server, "/bytes/32")
    response.aread()
    assert_equal(len(response.content()), 32)
    response.aclose()
    assert_true(response.is_closed)
    client.close()
    server.stop()


def test_aiter_bytes_reads_a_body_already_in_memory() raises:
    """The one iterator that works on a response that has been read.

    httpx behaves this way and it is the right behaviour: re-reading bytes that
    are sitting in memory costs nothing and asks nothing of the connection.
    """
    var server = TestServer()
    var client = AsyncClient()
    var response = _client_stream(client, server, "/chunked")
    response.aread()

    var joined = String()
    var chunks = response.aiter_bytes(4)
    while chunks.has_next():
        joined += String(StringSpan(unsafe_from_utf8=Span(chunks.next())))
    assert_equal(joined, "chunk one chunk two chunk three")
    client.close()
    server.stop()


def test_an_async_stream_to_an_https_url_is_refused() raises:
    """Refused the same way a buffered one is, and for the same reason.

    There is no async TLS handshake yet, and sending in the clear because the
    secure path is unfinished is not something this library does.
    """
    var client = AsyncClient()
    var raised = False
    try:
        _ = client.stream("GET", "https://example.com/")
    except e:
        raised = True
        assert_true("https" in String(e))
    assert_true(raised)
    client.close()
