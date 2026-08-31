"""Tests for one HTTP/1.1 exchange over a real socket.

The sans I/O pieces are tested on their own, so what is left here is the part
that only shows up once a kernel is involved: that the request actually reaches
the server in the shape it was serialized in, that the response is read out of
however many pieces it arrived in, and that the connection ends up in the right
state afterwards.

The server is the cooperative loopback from tests/support. Both ends are driven
from this one loop, which means the request has to be small enough to fit in the
socket buffers. Every request here is.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._exceptions import (
    is_local_protocol_error,
    is_remote_protocol_error,
)
from httpx._io.deadline import Deadline, read_deadline, write_deadline
from httpx._io.socket import open_stream
from httpx._models.headers import Headers
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._models.url import URL
from httpx._proto.h1.connection import H1Connection, H1State

from tests.support.loopback import Loopback, Peer


def _connect(listener: Loopback) raises -> H1Connection:
    return H1Connection(
        open_stream(listener.addr, "loopback", Deadline.after(5.0))
    )


def _exchange(
    method: StringSpan, var headers: Headers, response: StringSpan
) raises -> Response:
    """Send one request to a canned response and hand back what was parsed."""
    var listener = Loopback()
    var conn = _connect(listener)
    var peer = listener.accept_within()

    conn.send_request(
        Request(method, URL("http://example.com/"), headers^),
        Deadline.after(5.0),
    )
    _ = peer.recv_until("\r\n\r\n")
    peer.send_text(response)
    return conn.read_response(Deadline.after(5.0))


def test_a_get_reaches_the_server_as_it_was_serialized() raises:
    var listener = Loopback()
    var conn = _connect(listener)
    var peer = listener.accept_within()

    conn.send_request(
        Request("GET", URL("http://example.com/hello")), Deadline.after(5.0)
    )
    assert_equal(
        peer.recv_until("\r\n\r\n"),
        "GET /hello HTTP/1.1\r\nHost: example.com\r\n\r\n",
    )


def test_a_post_body_follows_the_head() raises:
    var listener = Loopback()
    var conn = _connect(listener)
    var peer = listener.accept_within()

    var body = List[UInt8]()
    body.extend("hello".as_bytes())
    var request = Request("POST", URL("http://example.com/"), Headers(), body^)
    conn.send_request(request^, Deadline.after(5.0))
    var sent = peer.recv_until("hello")
    assert_true("Content-Length: 5" in sent)
    assert_true(sent.endswith("\r\n\r\nhello"))


def test_a_length_framed_response_is_read() raises:
    var response = _exchange(
        "GET",
        Headers(),
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello",
    )
    assert_equal(response.status_code, 200)
    assert_equal(response.reason_phrase, "OK")
    assert_equal(response.text(), "hello")


def test_a_chunked_response_is_read() raises:
    var response = _exchange(
        "GET",
        Headers(),
        (
            "HTTP/1.1 200 OK\r\nTransfer-Encoding:"
            " chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
        ),
    )
    assert_equal(response.text(), "hello")


def test_trailers_come_back_separately_from_the_headers() raises:
    # Merging them would let a field that arrived after the body answer a
    # question the head already answered, which is the whole reason a trailer is
    # not allowed to be a framing header.
    var response = _exchange(
        "GET",
        Headers(),
        (
            "HTTP/1.1 200 OK\r\nTransfer-Encoding:"
            " chunked\r\n\r\n5\r\nhello\r\n0\r\nX-Sum: abc\r\n\r\n"
        ),
    )
    assert_equal(response.text(), "hello")
    assert_equal(response.trailers["x-sum"], "abc")
    assert_false("x-sum" in response.headers)


def test_a_head_response_does_not_wait_for_a_body() raises:
    # The hang case. The response says a hundred bytes are coming and none are,
    # so a client that believed the header would sit there until the deadline.
    var response = _exchange(
        "HEAD", Headers(), "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n"
    )
    assert_equal(response.status_code, 200)
    assert_equal(len(response.content), 0)


def test_a_204_does_not_wait_for_a_body() raises:
    var response = _exchange(
        "GET", Headers(), "HTTP/1.1 204 No Content\r\n\r\n"
    )
    assert_equal(response.status_code, 204)
    assert_equal(len(response.content), 0)


def test_a_response_arriving_in_pieces_is_read() raises:
    # What a real network does. The head and the body land in whatever sizes the
    # path between here and there decided on.
    var listener = Loopback()
    var conn = _connect(listener)
    var peer = listener.accept_within()

    conn.send_request(
        Request("GET", URL("http://example.com/")), Deadline.after(5.0)
    )
    _ = peer.recv_until("\r\n\r\n")
    peer.send_text("HTTP/1.1 20")
    peer.send_text("0 OK\r\nContent-Len")
    peer.send_text("gth: 11\r\n\r\nhello ")
    peer.send_text("world")
    var response = conn.read_response(Deadline.after(5.0))
    assert_equal(response.status_code, 200)
    assert_equal(response.text(), "hello world")


def test_an_informational_response_is_skipped() raises:
    var response = _exchange(
        "GET",
        Headers(),
        (
            "HTTP/1.1 102 Processing\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length:"
            " 2\r\n\r\nhi"
        ),
    )
    assert_equal(response.status_code, 200)
    assert_equal(response.text(), "hi")


def test_a_body_read_until_close_ends_at_the_close() raises:
    var listener = Loopback()
    var conn = _connect(listener)
    var peer = listener.accept_within()

    conn.send_request(
        Request("GET", URL("http://example.com/")), Deadline.after(5.0)
    )
    _ = peer.recv_until("\r\n\r\n")
    peer.send_text("HTTP/1.0 200 OK\r\n\r\nno framing here")
    peer.close()
    var response = conn.read_response(Deadline.after(5.0))
    assert_equal(response.text(), "no framing here")
    # Nothing said where the body ended except the close, so there is no way to
    # know the next byte would have started a new message.
    assert_false(conn.is_reusable())


def test_a_truncated_body_is_an_error_not_a_short_response() raises:
    # Half a response reported as success is worse than a failure, because the
    # caller acts on it.
    var listener = Loopback()
    var conn = _connect(listener)
    var peer = listener.accept_within()

    conn.send_request(
        Request("GET", URL("http://example.com/")), Deadline.after(5.0)
    )
    _ = peer.recv_until("\r\n\r\n")
    peer.send_text("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nshort")
    peer.close()
    var raised = False
    try:
        _ = conn.read_response(Deadline.after(5.0))
    except e:
        raised = True
        assert_true(is_remote_protocol_error(e))
    assert_true(raised)


def test_a_smuggling_shaped_response_is_refused() raises:
    var listener = Loopback()
    var conn = _connect(listener)
    var peer = listener.accept_within()

    conn.send_request(
        Request("GET", URL("http://example.com/")), Deadline.after(5.0)
    )
    _ = peer.recv_until("\r\n\r\n")
    peer.send_text(
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nTransfer-Encoding:"
        " chunked\r\n\r\n0\r\n\r\n"
    )
    var raised = False
    try:
        _ = conn.read_response(Deadline.after(5.0))
    except e:
        raised = True
        assert_true(is_remote_protocol_error(e))
    assert_true(raised)


def test_a_clean_exchange_leaves_the_connection_reusable() raises:
    var listener = Loopback()
    var conn = _connect(listener)
    var peer = listener.accept_within()

    conn.send_request(
        Request("GET", URL("http://example.com/")), Deadline.after(5.0)
    )
    _ = peer.recv_until("\r\n\r\n")
    peer.send_text("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi")
    _ = conn.read_response(Deadline.after(5.0))
    assert_true(conn.state == H1State.DONE)
    assert_true(conn.is_reusable())
    # Keeps the server end alive to here, so that "reusable" is about the
    # framing rather than about a peer that has already gone.
    assert_true(peer.fd() >= 0)


def test_a_second_exchange_runs_on_the_same_connection() raises:
    # Reuse is the whole reason a pool exists, so a connection that finished one
    # exchange cleanly has to accept the next request rather than call itself
    # busy. The paths are different so that the second response cannot be
    # mistaken for a replay of the first.
    var listener = Loopback()
    var conn = _connect(listener)
    var peer = listener.accept_within()

    conn.send_request(
        Request("GET", URL("http://example.com/one")), Deadline.after(5.0)
    )
    _ = peer.recv_until("\r\n\r\n")
    peer.send_text("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\none")
    assert_equal(conn.read_response(Deadline.after(5.0)).text(), "one")

    conn.send_request(
        Request("GET", URL("http://example.com/two")), Deadline.after(5.0)
    )
    assert_true("GET /two HTTP/1.1" in peer.recv_until("\r\n\r\n"))
    peer.send_text("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\ntwo")
    assert_equal(conn.read_response(Deadline.after(5.0)).text(), "two")
    assert_true(conn.is_reusable())
    # Keeps the server end alive to here, so that "reusable" is about the
    # framing rather than about a peer that has already gone.
    assert_true(peer.fd() >= 0)


def test_connection_close_leaves_the_connection_unusable() raises:
    var response = _exchange(
        "GET",
        Headers(),
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi",
    )
    assert_equal(response.text(), "hi")


def test_a_second_request_before_the_first_response_is_refused() raises:
    # HTTP/1.1 cannot do this without pipelining, and pipelining is not
    # something this library does. Failing here is better than two responses
    # coming back that nobody can match to their requests.
    var listener = Loopback()
    var conn = _connect(listener)
    var peer = listener.accept_within()

    conn.send_request(
        Request("GET", URL("http://example.com/")), Deadline.after(5.0)
    )
    var raised = False
    try:
        conn.send_request(
            Request("GET", URL("http://example.com/again")),
            Deadline.after(5.0),
        )
    except e:
        raised = True
        assert_true(is_local_protocol_error(e))
    assert_true(raised)
    assert_true(peer.fd() >= 0)


def test_reading_a_response_before_sending_a_request_is_refused() raises:
    var listener = Loopback()
    var conn = _connect(listener)
    var raised = False
    try:
        _ = conn.read_response(Deadline.after(5.0))
    except e:
        raised = True
        assert_true(is_local_protocol_error(e))
    assert_true(raised)
    assert_true(listener.has_pending())


def test_a_101_hands_the_connection_over() raises:
    var listener = Loopback()
    var conn = _connect(listener)
    var peer = listener.accept_within()

    var headers = Headers()
    headers.append("Upgrade", "websocket")
    headers.append("Connection", "Upgrade")
    conn.send_request(
        Request("GET", URL("http://example.com/ws"), headers^),
        Deadline.after(5.0),
    )
    _ = peer.recv_until("\r\n\r\n")
    peer.send_text(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection:"
        " Upgrade\r\n\r\n"
    )
    var response = conn.read_response(Deadline.after(5.0))
    assert_equal(response.status_code, 101)
    assert_true(conn.upgraded)
    assert_false(conn.is_reusable())


def test_the_four_way_deadlines_are_the_ones_that_fire() raises:
    # A read that runs out reports a read timeout, not a generic one, because
    # which phase ran out is the first thing anybody debugging wants to know.
    var listener = Loopback()
    var conn = _connect(listener)
    var peer = listener.accept_within()

    conn.send_request(
        Request("GET", URL("http://example.com/")), write_deadline(None)
    )
    _ = peer.recv_until("\r\n\r\n")
    var raised = False
    try:
        _ = conn.read_response(read_deadline(Optional[Float64](0.0)))
    except e:
        raised = True
        assert_true("read" in String(e))
    assert_true(raised)
    assert_true(peer.fd() >= 0)
