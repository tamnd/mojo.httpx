"""Tests for the type that hides which protocol a connection speaks.

Two things to check and they are different in kind. The first is the choice
itself, which is a string comparison against what ALPN said and is tested by
calling it with the names a real server might send back. The second is that the
forwarding actually goes somewhere, and the only way to know that is to put a
real socket under it and watch the right protocol come out.

So the exchanges here are driven by hand against the cooperative loopback, one
in each protocol, and they are deliberately the plainest exchange each protocol
has. Anything harder is already covered where that state machine is tested, and
repeating it here would test the state machine again rather than the forwarding.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._bytes import Bytes
from httpx._io.deadline import Deadline
from httpx._io.socket import open_stream
from httpx._models.request import Request
from httpx._models.url import URL
from httpx._pool.connection import Connection, speaks_http2
from httpx._proto.h2.frames import (
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FRAME_HEADER_SIZE,
    PREFACE,
    FrameHeader,
    FrameType,
    parse_frame_header,
    write_frame_header,
)
from httpx._proto.h2.hpack import HpackEncoder
from httpx._proto.h2.table import HeaderField

from tests.support.loopback import Loopback, Peer


def _open(listener: Loopback, http2: Bool) raises -> Connection:
    """A connection over loopback, told which protocol to speak.

    Told rather than asked because loopback is plain and ALPN only happens
    inside a TLS handshake, so the negotiated answer on this socket is always
    empty. What ALPN does with each possible answer is checked separately, by
    calling the function that decides.
    """
    return Connection(
        open_stream(listener.addr, "loopback", Deadline.after(5.0)), http2
    )


def _frame[
    o: ImmOrigin
](
    type: FrameType, flags: UInt8, stream_id: UInt32, payload: Span[UInt8, o]
) raises -> List[UInt8]:
    var out = Bytes()
    write_frame_header(FrameHeader(len(payload), type, flags, stream_id), out)
    out.extend(payload)
    return out.take_list()


def _settings(mut peer: Peer) raises:
    """Take the preface and the client's settings, and answer with ours."""
    var expected = PREFACE.as_bytes()
    var seen = peer.recv_exactly(len(expected))
    if len(seen) != len(expected):
        raise Error("the client did not send the whole preface")
    _ = _frame_from(peer)
    var empty = Bytes()
    peer.send_bytes(
        Span(_frame(FrameType.SETTINGS, UInt8(0), 0, empty.as_span()))
    )


def _frame_from(mut peer: Peer) raises -> Tuple[FrameHeader, List[UInt8]]:
    var head = peer.recv_exactly(FRAME_HEADER_SIZE)
    if len(head) != FRAME_HEADER_SIZE:
        raise Error("the client did not send a whole frame header")
    var header = parse_frame_header(Span(head), 0)
    var payload = List[UInt8]()
    if header.length > 0:
        payload = peer.recv_exactly(header.length)
    return (header, payload^)


def _skip_to_headers(mut peer: Peer) raises:
    while True:
        var read = _frame_from(peer)
        if read[0].type == FrameType.HEADERS:
            return


def _block(var fields: List[HeaderField]) raises -> List[UInt8]:
    var encoder = HpackEncoder()
    var out = Bytes()
    encoder.encode(fields, out)
    return out.take_list()


def _ok_block() raises -> List[HeaderField]:
    var fields = List[HeaderField]()
    fields.append(HeaderField(String(":status"), String("200")))
    return fields^


def _trailer_block() raises -> List[HeaderField]:
    var fields = List[HeaderField]()
    fields.append(HeaderField(String("grpc-status"), String("0")))
    return fields^


def test_only_the_name_h2_means_http2() raises:
    # The near misses are the point. `h2c` is HTTP/2 over cleartext, which is a
    # different negotiation entirely, and `h2-14` is one of the drafts, which
    # differ from what shipped in ways that matter on the wire.
    assert_true(speaks_http2(String("h2")))
    assert_false(speaks_http2(String("http/1.1")))
    assert_false(speaks_http2(String("h2c")))
    assert_false(speaks_http2(String("h2-14")))
    assert_false(speaks_http2(String("H2")))


def test_a_server_that_said_nothing_about_alpn_gets_http1() raises:
    # Empty covers a plain connection and a TLS one where the server ignored the
    # offer, and the answer has to be the same for both.
    assert_false(speaks_http2(String()))


def test_a_connection_reports_which_protocol_it_holds() raises:
    var listener = Loopback()
    var h1 = _open(listener, False)
    var first = listener.accept_within()
    assert_false(h1.is_http2())

    var h2 = _open(listener, True)
    var second = listener.accept_within()
    assert_true(h2.is_http2())

    # Keeps both server ends alive to here, so that neither socket is closed
    # underneath a connection still being asked about.
    assert_true(first.fd() >= 0)
    assert_true(second.fd() >= 0)


def test_a_new_connection_of_either_kind_is_idle() raises:
    var listener = Loopback()
    var h1 = _open(listener, False)
    var first = listener.accept_within()
    var h2 = _open(listener, True)
    var second = listener.accept_within()

    assert_true(h1.is_idle())
    assert_true(h2.is_idle())
    assert_true(first.fd() >= 0)
    assert_true(second.fd() >= 0)


def test_an_http1_exchange_goes_through_unchanged() raises:
    var listener = Loopback()
    var conn = _open(listener, False)
    var peer = listener.accept_within()

    var request = Request("GET", URL("http://example.com/hello"))
    conn.send_request(request, Deadline.after(5.0))
    assert_equal(
        peer.recv_until("\r\n\r\n"),
        "GET /hello HTTP/1.1\r\nHost: example.com\r\n\r\n",
    )

    peer.send_text(
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi",
    )
    var head = conn.start_response(Deadline.after(5.0))
    assert_equal(head.status_code, 200)
    assert_equal(head.http_version, "HTTP/1.1")
    var body = conn.read_chunk(Deadline.after(5.0))
    assert_equal(String(StringSpan(from_utf8=Span(body))), "hi")


def test_an_http2_exchange_goes_out_as_frames() raises:
    # The request never reaches the wire as text, which is the whole point of
    # the forwarding being real rather than a translation.
    var listener = Loopback()
    var conn = _open(listener, True)
    var peer = listener.accept_within()

    var request = Request("GET", URL("https://example.com/hello"))
    conn.send_request(request, Deadline.after(5.0))

    _settings(peer)
    _skip_to_headers(peer)
    peer.send_bytes(
        Span(
            _frame(
                FrameType.HEADERS,
                FLAG_END_HEADERS | FLAG_END_STREAM,
                1,
                Span(_block(_ok_block())),
            )
        )
    )

    var head = conn.start_response(Deadline.after(5.0))
    assert_equal(head.status_code, 200)
    assert_equal(head.http_version, "HTTP/2")
    assert_equal(len(conn.read_chunk(Deadline.after(5.0))), 0)


def test_an_http2_body_and_its_trailers_come_back_through() raises:
    # `read_chunk` and `take_trailers` are what a streaming response reads
    # through, so both have to reach the driver rather than the h1 side.
    var listener = Loopback()
    var conn = _open(listener, True)
    var peer = listener.accept_within()

    var request = Request("GET", URL("https://example.com/"))
    conn.send_request(request, Deadline.after(5.0))

    _settings(peer)
    _skip_to_headers(peer)
    peer.send_bytes(
        Span(
            _frame(
                FrameType.HEADERS,
                FLAG_END_HEADERS,
                1,
                Span(_block(_ok_block())),
            )
        )
    )
    var text = String("hello")
    peer.send_bytes(Span(_frame(FrameType.DATA, UInt8(0), 1, text.as_bytes())))
    peer.send_bytes(
        Span(
            _frame(
                FrameType.HEADERS,
                FLAG_END_HEADERS | FLAG_END_STREAM,
                1,
                Span(_block(_trailer_block())),
            )
        )
    )

    _ = conn.start_response(Deadline.after(5.0))
    var chunk = conn.read_chunk(Deadline.after(5.0))
    assert_equal(String(StringSpan(from_utf8=Span(chunk))), "hello")
    assert_equal(len(conn.read_chunk(Deadline.after(5.0))), 0)
    assert_equal(conn.take_trailers()["grpc-status"], "0")
