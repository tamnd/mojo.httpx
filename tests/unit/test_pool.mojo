"""Tests for the connection pool, against a real server.

The pool is the first thing in this library that cannot be tested by handing it
bytes. Whether a connection was reused, whether the server closed one while it
sat idle, and whether the pool noticed, are all questions about two processes
rather than about a parser, so these run against `tests/server/server.py`.

Reuse is observable because that server puts an id on every response saying
which connection carried it. Without that, a test can only check that requests
succeed, which they do whether or not the pool is doing anything at all.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._exceptions import is_connect_error
from httpx._io.deadline import Deadlines
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._models.url import URL
from httpx._pool.limits import Limits
from httpx._pool.pool import ConnectionPool
from httpx._stream.config import TlsConfig

from tests.support.testserver import TestServer


def _pool(var limits: Limits) raises -> ConnectionPool:
    return ConnectionPool(limits^)


def _deadlines() -> Deadlines:
    """Generous but finite. A hang in the pool should fail the test, not the
    suite."""
    return Deadlines.uniform(Optional[Float64](10.0))


def _request(
    mut pool: ConnectionPool,
    server: TestServer,
    method: StringSpan,
    path: StringSpan,
    var content: List[UInt8] = List[UInt8](),
) raises -> Response:
    """One request to `server`, with the server held alive for the whole call.

    The server is a parameter rather than something a test inlines into the URL
    because Mojo ends a value's life at its last use. A test that built the URL
    and then made the request would have shut the server down between the two,
    and the request would fail to connect to a port that had just closed.
    """
    return pool.handle_request(
        Request(method, URL(server.url(path)), content=content^), _deadlines()
    )


def _get(
    mut pool: ConnectionPool, server: TestServer, path: StringSpan
) raises -> Response:
    return _request(pool, server, "GET", path)


def _conn_id(response: Response) raises -> String:
    return response.headers["x-conn-id"]


def test_a_request_through_the_pool_gets_an_answer() raises:
    var server = TestServer()
    var pool = _pool(Limits())
    var response = _get(pool, server, "/get")
    assert_equal(response.status_code, 200)
    assert_true('"method": "GET"' in response.text())


def test_the_connection_is_kept_for_the_next_request() raises:
    var server = TestServer()
    var pool = _pool(Limits())
    var response = _get(pool, server, "/get")
    assert_equal(response.status_code, 200)
    assert_equal(pool.idle_count(), 1)
    assert_equal(pool.leased_count(), 0)


def test_a_second_request_reuses_the_first_connection() raises:
    # The whole point of the pool. The server's id is the only thing that can
    # tell this apart from opening a second connection and closing the first.
    var server = TestServer()
    var pool = _pool(Limits())
    var first = _get(pool, server, "/conn")
    var second = _get(pool, server, "/conn")
    assert_equal(_conn_id(first), _conn_id(second))
    assert_equal(pool.total_count(), 1)


def test_many_requests_in_a_row_all_share_one_connection() raises:
    var server = TestServer()
    var pool = _pool(Limits())
    var first = _get(pool, server, "/conn")
    var id = _conn_id(first)
    for _ in range(5):
        assert_equal(_conn_id(_get(pool, server, "/conn")), id)
    assert_equal(pool.total_count(), 1)


def test_a_connection_close_response_is_not_pooled() raises:
    # A server that said it is closing has closed. Keeping the connection would
    # mean the next request fails on a socket that was never coming back.
    var server = TestServer()
    var pool = _pool(Limits())
    var response = _get(pool, server, "/close")
    assert_equal(response.status_code, 200)
    assert_equal(pool.idle_count(), 0)
    assert_equal(pool.total_count(), 0)


def test_a_request_after_a_close_opens_a_new_connection() raises:
    var server = TestServer()
    var pool = _pool(Limits())
    var first = _get(pool, server, "/close")
    var second = _get(pool, server, "/conn")
    assert_true(_conn_id(first) != _conn_id(second))


def test_a_body_framed_by_the_close_is_not_pooled() raises:
    # No Content-Length and no chunking means the close is the framing, so the
    # connection is spent by the time the body is complete.
    var server = TestServer()
    var pool = _pool(Limits())
    var response = _get(pool, server, "/no-length")
    assert_equal(response.text(), "this ends when the connection does")
    assert_equal(pool.idle_count(), 0)


def test_zero_keepalive_connections_means_a_new_connection_every_time() raises:
    var server = TestServer()
    var pool = _pool(Limits(10, 0, 5.0))
    var first = _get(pool, server, "/conn")
    assert_equal(pool.idle_count(), 0)
    var second = _get(pool, server, "/conn")
    assert_true(_conn_id(first) != _conn_id(second))


def test_an_expired_connection_is_replaced_rather_than_reused() raises:
    # An expiry of zero makes every idle connection stale the instant it lands,
    # which is the same code path a five second expiry takes five seconds to
    # reach.
    var server = TestServer()
    var pool = _pool(Limits(10, 5, 0.0))
    var first = _get(pool, server, "/conn")
    assert_equal(pool.idle_count(), 1)
    var second = _get(pool, server, "/conn")
    assert_true(_conn_id(first) != _conn_id(second))
    assert_equal(pool.total_count(), 1)


def test_an_unexpired_connection_is_reused() raises:
    # The other half of the expiry test. Without this one, an expiry check that
    # discarded everything would still pass.
    var server = TestServer()
    var pool = _pool(Limits(10, 5, 60.0))
    var first = _get(pool, server, "/conn")
    var second = _get(pool, server, "/conn")
    assert_equal(_conn_id(first), _conn_id(second))


def test_the_keepalive_limit_evicts_the_oldest_idle_connection() raises:
    # Three servers, so three origins, and room to keep two connections. The
    # first origin's connection is the one that goes.
    var one = TestServer()
    var two = TestServer()
    var three = TestServer()
    var pool = _pool(Limits(10, 2, 60.0))

    var first = _get(pool, one, "/conn")
    _ = _get(pool, two, "/conn")
    assert_equal(pool.idle_count(), 2)
    _ = _get(pool, three, "/conn")
    assert_equal(pool.idle_count(), 2)

    # The connection to the first server was the oldest when room had to be made
    # for the third, so going back to it opens a new one rather than finding the
    # old one waiting.
    var again = _get(pool, one, "/conn")
    assert_equal(pool.idle_count(), 2)
    assert_true(_conn_id(again) != _conn_id(first))


def test_the_total_limit_evicts_an_idle_connection_to_make_room() raises:
    # One connection allowed in total, and two origins to reach. The pool has to
    # give up the idle one rather than refuse the request.
    var one = TestServer()
    var two = TestServer()
    var pool = _pool(Limits(1, 5, 60.0))

    _ = _get(pool, one, "/conn")
    assert_equal(pool.total_count(), 1)
    var response = _get(pool, two, "/conn")
    assert_equal(response.status_code, 200)
    assert_equal(pool.total_count(), 1)


def test_different_origins_do_not_share_a_connection() raises:
    var one = TestServer()
    var two = TestServer()
    var pool = _pool(Limits())
    _ = _get(pool, one, "/conn")
    _ = _get(pool, two, "/conn")
    assert_equal(pool.idle_count(), 2)


def test_closing_the_pool_drops_every_idle_connection() raises:
    var server = TestServer()
    var pool = _pool(Limits())
    _ = _get(pool, server, "/get")
    assert_equal(pool.idle_count(), 1)
    pool.close()
    assert_equal(pool.idle_count(), 0)
    assert_equal(pool.total_count(), 0)


def test_a_pooled_connection_the_server_closed_is_not_handed_out() raises:
    # The failure a pool exists to prevent. The server goes away while the
    # connection sits idle, and the next request has to notice rather than write
    # a request into a socket that is already gone.
    var server = TestServer()
    var pool = _pool(Limits())
    var url = server.url("/get")
    _ = _get(pool, server, "/get")
    assert_equal(pool.idle_count(), 1)

    server.stop()
    var raised = False
    try:
        _ = pool.handle_request(Request("GET", URL(url)), _deadlines())
    except e:
        raised = True
        # A connect failure, because the pool discarded the dead connection and
        # tried to open a new one. A protocol error here would mean it had used
        # the dead one.
        assert_true(is_connect_error(e))
    assert_true(raised)
    assert_equal(pool.idle_count(), 0)


def test_a_post_with_a_body_goes_through_the_pool() raises:
    var server = TestServer()
    var pool = _pool(Limits())
    var body = List[UInt8]()
    body.extend("hello pool".as_bytes())
    var response = _request(pool, server, "POST", "/post", body^)
    assert_equal(response.status_code, 200)
    assert_true("hello pool" in response.text())
    assert_equal(pool.idle_count(), 1)


def test_a_chunked_response_still_leaves_the_connection_reusable() raises:
    var server = TestServer()
    var pool = _pool(Limits())
    var response = _get(pool, server, "/chunked")
    assert_equal(response.text(), "chunk one chunk two chunk three")
    assert_equal(pool.idle_count(), 1)
    var next = _get(pool, server, "/conn")
    assert_equal(next.status_code, 200)
    assert_equal(pool.total_count(), 1)


def test_trailers_arrive_separately_from_the_headers() raises:
    var server = TestServer()
    var pool = _pool(Limits())
    var response = _get(pool, server, "/trailers")
    assert_equal(response.text(), "hello")
    assert_equal(response.trailers["x-checksum"], "abc123")
    assert_false("x-checksum" in response.headers)


def test_a_head_response_through_the_pool_does_not_wait_for_a_body() raises:
    # The server sends a Content-Length describing a body it will not send. A
    # client that believed it would sit here until the deadline.
    var server = TestServer()
    var pool = _pool(Limits())
    var response = _request(pool, server, "HEAD", "/get")
    assert_equal(response.status_code, 200)
    assert_equal(len(response.content()), 0)
    assert_true(Int(response.headers["content-length"]) > 0)


def test_a_204_through_the_pool_does_not_wait_for_a_body() raises:
    var server = TestServer()
    var pool = _pool(Limits())
    var response = _get(pool, server, "/status/204")
    assert_equal(response.status_code, 204)
    assert_equal(len(response.content()), 0)
    assert_equal(pool.idle_count(), 1)


def test_an_error_status_is_a_response_and_not_a_failure() raises:
    # The pool's job ends at delivering what the server said. Turning a 404 into
    # an exception is a decision for the layer that knows what the caller asked
    # for.
    var server = TestServer()
    var pool = _pool(Limits())
    var response = _get(pool, server, "/status/418")
    assert_equal(response.status_code, 418)
    assert_equal(pool.idle_count(), 1)


def test_a_plain_connection_stays_http1_even_when_http2_is_offered() raises:
    # There is no handshake on a plain connection, so there is nothing for the
    # offer to happen in. A pool that took the flag as an instruction would send
    # a preface to a server expecting a request line, which is a protocol error
    # rather than a downgrade.
    var server = TestServer()
    var tls = TlsConfig()
    tls.http2 = True
    var pool = ConnectionPool(Limits(), tls=tls^)
    var response = _get(pool, server, "/get")
    assert_equal(response.status_code, 200)
    assert_equal(response.http_version, "HTTP/1.1")
    assert_equal(pool.idle_count(), 1)


def test_a_url_with_no_route_to_it_never_reaches_the_network() raises:
    var pool = _pool(Limits())
    var raised = False
    try:
        _ = pool.handle_request(
            Request("GET", URL("ftp://example.invalid/x")), _deadlines()
        )
    except:
        raised = True
    assert_true(raised)
    assert_equal(pool.total_count(), 0)
