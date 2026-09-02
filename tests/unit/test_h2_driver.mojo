"""Tests for HTTP/2 over a real socket.

The state machine is tested on its own, so what is left here is the part that
only shows up once a kernel is involved: that the preface and our settings
actually reach the server, that a response reassembles out of however many reads
it arrived in, and that a peer which goes quiet is broken out of by a deadline
rather than waited on forever.

The server is the cooperative loopback from tests/support, driven by hand. There
is no HTTP/2 server here and there should not be: every frame these tests send is
one somebody wrote on purpose, including the ones that are wrong.

The shape of every test is the same and it is forced by there being one thread. A
request head goes out without the client reading anything, so the server side can
take it and queue its whole answer, and only then does the client read. Nothing
here ever has both sides waiting.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from httpx._bytes import Bytes
from httpx._io.deadline import Deadline
from httpx._io.socket import open_stream
from httpx._models.headers import Headers
from httpx._models.request import Request
from httpx._models.stream import ByteSource, erase_source
from httpx._models.url import URL
from httpx._proto.h2.driver import H2Driver
from httpx._proto.h2.frames import (
    FLAG_ACK,
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FRAME_HEADER_SIZE,
    PREFACE,
    ErrorCode,
    FrameHeader,
    FrameType,
    parse_frame_header,
    write_frame_header,
    write_uint32,
)
from httpx._proto.h2.hpack import HpackDecoder, HpackEncoder
from httpx._proto.h2.table import HeaderField

from tests.support.loopback import Loopback, Peer


def _connect(listener: Loopback) raises -> H2Driver:
    return H2Driver(open_stream(listener.addr, "loopback", Deadline.after(5.0)))


def _get(url: StringSpan = "https://example.com/") raises -> Request:
    return Request("GET", URL(url))


struct _TwoPieces(ByteSource, Movable):
    """A body handed over in two pieces, so its length is not known up front."""

    var _at: Int

    def __init__(out self):
        self._at = 0

    def read_chunk(mut self) raises -> List[UInt8]:
        var out = List[UInt8]()
        if self._at == 0:
            out.extend("up".as_bytes())
        elif self._at == 1:
            out.extend("load".as_bytes())
        self._at += 1
        return out^

    def close(mut self):
        self._at = 2

    def trailers(self) -> Headers:
        return Headers()


def _frame[
    o: ImmOrigin
](
    type: FrameType, flags: UInt8, stream_id: UInt32, payload: Span[UInt8, o]
) raises -> List[UInt8]:
    var out = Bytes()
    write_frame_header(FrameHeader(len(payload), type, flags, stream_id), out)
    out.extend(payload)
    return out.take_list()


def _settings_frame() raises -> List[UInt8]:
    var empty = Bytes()
    return _frame(FrameType.SETTINGS, UInt8(0), 0, empty.as_span())


def _encoded(var fields: List[HeaderField]) raises -> List[UInt8]:
    """One header block, from an encoder that starts fresh every time.

    Safe even for a second block on the same connection, because an encoder with
    an empty table never names a dynamic entry, and the static table it does name
    is the same sixty one rows on both sides forever.
    """
    var encoder = HpackEncoder()
    var block = Bytes()
    encoder.encode(fields, block)
    return block.take_list()


def _response_frame(
    stream_id: UInt32, var fields: List[HeaderField], end_stream: Bool
) raises -> List[UInt8]:
    var block = _encoded(fields^)
    var flags = FLAG_END_HEADERS
    if end_stream:
        flags |= FLAG_END_STREAM
    return _frame(FrameType.HEADERS, flags, stream_id, Span(block))


def _ok(status: String = String("200")) raises -> List[HeaderField]:
    var fields = List[HeaderField]()
    fields.append(HeaderField(String(":status"), status.copy()))
    fields.append(HeaderField(String("content-type"), String("text/plain")))
    return fields^


def _read_preface(mut peer: Peer) raises:
    var expected = PREFACE.as_bytes()
    var seen = peer.recv_exactly(len(expected))
    if len(seen) != len(expected):
        raise Error("the client did not send the whole preface")


def _read_frame(mut peer: Peer) raises -> Tuple[FrameHeader, List[UInt8]]:
    var head = peer.recv_exactly(FRAME_HEADER_SIZE)
    if len(head) != FRAME_HEADER_SIZE:
        raise Error("the client did not send a whole frame header")
    var header = parse_frame_header(Span(head), 0)
    var payload = List[UInt8]()
    if header.length > 0:
        payload = peer.recv_exactly(header.length)
    return (header, payload^)


def _greet(mut peer: Peer) raises:
    """Take the preface and the client's settings, and answer with ours.

    Called after the request has gone out rather than before it, because a
    client is entitled to send on stream one straight after the preface and
    these tests want the assertion to be about the request rather than about a
    handshake that had not finished.
    """
    _read_preface(peer)
    _ = _read_frame(peer)
    peer.send_bytes(Span(_settings_frame()))


def _skip_to_headers(mut peer: Peer) raises -> Tuple[FrameHeader, List[UInt8]]:
    """Read past anything housekeeping to the next request head."""
    while True:
        var read = _read_frame(peer)
        if read[0].type == FrameType.HEADERS:
            return read^


def _request_head(mut peer: Peer) raises -> List[HeaderField]:
    var read = _skip_to_headers(peer)
    var decoder = HpackDecoder()
    return decoder.decode(Span(read[1]))


def _has(fields: List[HeaderField], name: StringSpan) -> Bool:
    for i in range(len(fields)):
        if fields[i].name == name:
            return True
    return False


def _value(fields: List[HeaderField], name: StringSpan) -> String:
    for i in range(len(fields)):
        if fields[i].name == name:
            return fields[i].value.copy()
    return String()


def _nothing_more(mut peer: Peer) -> Bool:
    """Whether the client sent nothing else, for tests about an absence.

    A seventh of a second is far longer than a loopback write takes and short
    enough that a handful of these does not become the slow part of a run.
    """
    try:
        return len(peer.recv_exactly(1, ms=150)) == 0
    except:
        return True


def test_h2_the_preface_and_our_settings_go_out_first() raises:
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var request = _get()
    driver.send_request(request, Deadline.after(5.0))

    var expected = PREFACE.as_bytes()
    var seen = peer.recv_exactly(len(expected))
    assert_equal(len(seen), len(expected))
    for i in range(len(expected)):
        assert_equal(seen[i], expected[i])

    var read = _read_frame(peer)
    assert_true(read[0].type == FrameType.SETTINGS)
    assert_equal(read[0].stream_id, 0)
    assert_false(read[0].has(FLAG_ACK))


def test_h2_a_request_goes_out_on_stream_one() raises:
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var request = _get()
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)

    var read = _read_frame(peer)
    assert_true(read[0].type == FrameType.HEADERS)
    assert_equal(read[0].stream_id, 1)
    assert_true(read[0].has(FLAG_END_HEADERS))
    # A GET has no body, so the head is the whole request and the stream is
    # finished on our side the moment it goes out.
    assert_true(read[0].has(FLAG_END_STREAM))


def test_h2_the_pseudo_headers_come_first_and_names_are_lowered() raises:
    # RFC 9113 section 8.3. An upper case letter in a field name makes the whole
    # message malformed, so a header the caller wrote as X-Mixed-Case has to go
    # out lowered or the request fails for a reason nothing in their code shows.
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var headers = Headers()
    headers.append("X-Mixed-Case", "yes")
    var request = Request("GET", URL("https://example.com/a?b=c"), headers^)
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)

    var fields = _request_head(peer)
    assert_equal(fields[0].name, ":method")
    assert_equal(fields[0].value, "GET")
    assert_equal(_value(fields, ":scheme"), "https")
    assert_equal(_value(fields, ":authority"), "example.com")
    assert_equal(_value(fields, ":path"), "/a?b=c")
    assert_true(_has(fields, "x-mixed-case"))
    assert_false(_has(fields, "X-Mixed-Case"))


def test_h2_hop_by_hop_headers_are_left_off() raises:
    # RFC 9113 section 8.2.2. A server that receives one has to treat the whole
    # message as malformed, so passing one on is a request that fails somewhere
    # the caller cannot see.
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var headers = Headers()
    headers.append("Connection", "keep-alive")
    headers.append("Transfer-Encoding", "chunked")
    headers.append("X-Kept", "yes")
    var request = Request("GET", URL("https://example.com/"), headers^)
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)

    var fields = _request_head(peer)
    assert_false(_has(fields, "connection"))
    assert_false(_has(fields, "transfer-encoding"))
    assert_true(_has(fields, "x-kept"))


def test_h2_a_host_header_becomes_the_authority() raises:
    # Sending both invites the two to disagree, which is a request smuggling
    # primitive rather than a redundancy.
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var headers = Headers()
    headers.append("Host", "elsewhere.example")
    var request = Request("GET", URL("https://example.com/"), headers^)
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)

    var fields = _request_head(peer)
    assert_false(_has(fields, "host"))
    assert_equal(_value(fields, ":authority"), "example.com")


def test_h2_a_body_in_hand_declares_its_length() raises:
    # Optional in HTTP/2, where END_STREAM is what frames a body, and not
    # optional at all once a front end has to proxy the request to an HTTP/1.1
    # origin: with no length the only framing left for that hop is chunked,
    # which is the framing origins handle worst. Three of the four servers in
    # the interop suite dropped the body of a POST that arrived without one.
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var content: List[UInt8] = [1, 2, 3]
    var request = Request(
        "POST", URL("https://example.com/"), Headers(), content^
    )
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)

    var fields = _request_head(peer)
    assert_equal(_value(fields, "content-length"), "3")


def test_h2_a_request_with_no_body_declares_no_length() raises:
    # A GET with Content-Length: 0 is legal and makes some servers and more WAFs
    # treat the request as suspicious, which is the same call the HTTP/1.1
    # writer makes.
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var request = _get()
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)

    var fields = _request_head(peer)
    assert_false(_has(fields, "content-length"))


def test_h2_a_streamed_body_declares_no_length() raises:
    # There is no length to declare until the source has run out, and no chunked
    # encoding in HTTP/2 to declare one later with, so the field is left off and
    # END_STREAM is what says the body is over.
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var request = Request.streaming(
        "POST", URL("https://example.com/"), erase_source(_TwoPieces())
    )
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)

    var fields = _request_head(peer)
    assert_false(_has(fields, "content-length"))


def test_h2_a_caller_s_own_content_length_is_not_repeated() raises:
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var headers = Headers()
    headers.append("Content-Length", "3")
    var content: List[UInt8] = [1, 2, 3]
    var request = Request(
        "POST", URL("https://example.com/"), headers^, content^
    )
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)

    var fields = _request_head(peer)
    var seen = 0
    for i in range(len(fields)):
        if fields[i].name == "content-length":
            seen += 1
    # Two of them is a malformed message under RFC 9113 section 8.1.1, so this
    # is not a matter of tidiness.
    assert_equal(seen, 1)
    assert_equal(_value(fields, "content-length"), "3")


def test_h2_a_content_length_that_disagrees_with_the_body_is_refused() raises:
    # The same answer the HTTP/1.1 writer gives, because the request is the same
    # request and finding out locally beats finding out as a stream reset.
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var headers = Headers()
    headers.append("Content-Length", "7")
    var content: List[UInt8] = [1, 2, 3]
    var request = Request(
        "POST", URL("https://example.com/"), headers^, content^
    )
    with assert_raises():
        driver.send_request(request, Deadline.after(5.0))
    _ = peer^


def test_h2_a_response_head_comes_back() raises:
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var request = _get()
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)
    _ = _skip_to_headers(peer)

    peer.send_bytes(Span(_response_frame(1, _ok(), end_stream=True)))
    var head = driver.start_response(Deadline.after(5.0))

    assert_equal(head.status_code, 200)
    assert_equal(head.http_version, "HTTP/2")
    assert_equal(head.headers.get("content-type"), "text/plain")


def test_h2_there_is_no_reason_phrase() raises:
    # It was dropped from the protocol. Inventing one from the status code would
    # be putting words in a server's mouth.
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var request = _get()
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)
    _ = _skip_to_headers(peer)

    peer.send_bytes(Span(_response_frame(1, _ok(String("404")), True)))
    var head = driver.start_response(Deadline.after(5.0))

    assert_equal(head.status_code, 404)
    assert_equal(head.reason_phrase, "")


def test_h2_a_body_arrives_in_the_pieces_it_was_sent_in() raises:
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var request = _get()
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)
    _ = _skip_to_headers(peer)

    peer.send_bytes(Span(_response_frame(1, _ok(), end_stream=False)))
    var first: List[UInt8] = [104, 105]
    peer.send_bytes(Span(_frame(FrameType.DATA, UInt8(0), 1, Span(first))))
    var second: List[UInt8] = [33]
    peer.send_bytes(
        Span(_frame(FrameType.DATA, FLAG_END_STREAM, 1, Span(second)))
    )

    _ = driver.start_response(Deadline.after(5.0))

    var one = driver.read_chunk(Deadline.after(5.0))
    assert_equal(len(one), 2)
    assert_equal(one[0], 104)

    var two = driver.read_chunk(Deadline.after(5.0))
    assert_equal(len(two), 1)
    assert_equal(two[0], 33)

    assert_equal(len(driver.read_chunk(Deadline.after(5.0))), 0)


def test_h2_a_finished_exchange_leaves_the_connection_idle() raises:
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var request = _get()
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)
    _ = _skip_to_headers(peer)

    peer.send_bytes(Span(_response_frame(1, _ok(), end_stream=True)))
    _ = driver.start_response(Deadline.after(5.0))
    assert_equal(len(driver.read_chunk(Deadline.after(5.0))), 0)

    assert_true(driver.is_idle())
    assert_true(driver.is_reusable())
    # Keeps the server end alive to here, so that "reusable" is about the
    # protocol rather than about a peer that has already gone.
    assert_true(peer.fd() >= 0)


def test_h2_a_second_request_goes_on_the_next_stream() raises:
    # Identifiers go up by two and never come down, so a number is never reused
    # even after the stream it named has finished.
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var first = _get()
    driver.send_request(first, Deadline.after(5.0))
    _greet(peer)
    _ = _skip_to_headers(peer)

    peer.send_bytes(Span(_response_frame(1, _ok(), end_stream=True)))
    _ = driver.start_response(Deadline.after(5.0))
    _ = driver.read_chunk(Deadline.after(5.0))

    var second = _get()
    driver.send_request(second, Deadline.after(5.0))
    var read = _skip_to_headers(peer)
    assert_equal(read[0].stream_id, 3)


def test_h2_a_whole_exchange_comes_back_as_a_response() raises:
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var request = _get()
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)
    _ = _skip_to_headers(peer)

    peer.send_bytes(Span(_response_frame(1, _ok(), end_stream=False)))
    var body: List[UInt8] = [104, 101, 108, 108, 111]
    peer.send_bytes(
        Span(_frame(FrameType.DATA, FLAG_END_STREAM, 1, Span(body)))
    )

    var head = driver.start_response(Deadline.after(5.0))
    assert_equal(head.status_code, 200)

    var content = List[UInt8]()
    while True:
        var chunk = driver.read_chunk(Deadline.after(5.0))
        if len(chunk) == 0:
            break
        content.extend(chunk^)
    assert_equal(len(content), 5)
    assert_equal(content[0], 104)


def test_h2_a_request_body_goes_out_as_data() raises:
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var content: List[UInt8] = [1, 2, 3]
    var request = Request(
        "POST", URL("https://example.com/"), Headers(), content^
    )
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)

    var head = _read_frame(peer)
    assert_true(head[0].type == FrameType.HEADERS)
    assert_false(head[0].has(FLAG_END_STREAM))

    var body = _read_frame(peer)
    assert_true(body[0].type == FrameType.DATA)
    assert_equal(body[0].length, 3)
    assert_equal(body[1][0], 1)

    # The end comes as its own empty DATA frame rather than riding on the last
    # one, because a body handed over in pieces gives no way to know which piece
    # was the last until it is asked for another and there is not one.
    var end = _read_frame(peer)
    assert_true(end[0].type == FrameType.DATA)
    assert_equal(end[0].length, 0)
    assert_true(end[0].has(FLAG_END_STREAM))


def test_h2_a_window_that_never_opens_is_broken_out_of_by_the_deadline() raises:
    # The zero window stall. Nothing in the protocol says how long to put up with
    # a peer that advertises a window and never opens it, so the write deadline
    # decides, the same as any other way a peer can go quiet.
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    driver.conn.send_window.available = 0

    var content: List[UInt8] = [1, 2, 3]
    var request = Request(
        "POST", URL("https://example.com/"), Headers(), content^
    )
    with assert_raises():
        driver.send_request(request, Deadline.after(0.3))

    # The head went out and the body did not, which is what a stall looks like
    # from the other side.
    _greet(peer)
    var head = _read_frame(peer)
    assert_true(head[0].type == FrameType.HEADERS)
    assert_false(head[0].has(FLAG_END_STREAM))
    assert_true(_nothing_more(peer))


def test_h2_a_window_update_lets_a_stalled_body_finish() raises:
    # The other half of the same loop. Waiting for window is a wait for a frame,
    # so what ends it is one arriving rather than a timer being generous.
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    driver.conn.send_window.available = 0

    var payload = Bytes()
    write_uint32(1024, payload)
    peer.send_bytes(
        Span(_frame(FrameType.WINDOW_UPDATE, UInt8(0), 0, payload.as_span()))
    )

    var content: List[UInt8] = [1, 2, 3]
    var request = Request(
        "POST", URL("https://example.com/"), Headers(), content^
    )
    driver.send_request(request, Deadline.after(5.0))

    _read_preface(peer)
    var settings = _read_frame(peer)
    assert_true(settings[0].type == FrameType.SETTINGS)

    var head = _read_frame(peer)
    assert_true(head[0].type == FrameType.HEADERS)

    var body = _read_frame(peer)
    assert_true(body[0].type == FrameType.DATA)
    assert_equal(body[0].length, 3)


def test_h2_a_reset_stream_is_reported_rather_than_waited_on() raises:
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var request = _get()
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)
    _ = _skip_to_headers(peer)

    var payload = Bytes()
    write_uint32(ErrorCode.REFUSED_STREAM.value, payload)
    peer.send_bytes(
        Span(_frame(FrameType.RST_STREAM, UInt8(0), 1, payload.as_span()))
    )

    with assert_raises():
        _ = driver.start_response(Deadline.after(5.0))


def test_h2_a_goaway_that_excludes_our_stream_is_reported() raises:
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var request = _get()
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)
    _ = _skip_to_headers(peer)

    # Last stream zero, so stream one is not one this server will ever answer.
    var payload = Bytes()
    write_uint32(0, payload)
    write_uint32(ErrorCode.NO_ERROR.value, payload)
    peer.send_bytes(
        Span(_frame(FrameType.GOAWAY, UInt8(0), 0, payload.as_span()))
    )

    with assert_raises():
        _ = driver.start_response(Deadline.after(5.0))
    assert_false(driver.is_reusable())
    # Keeps the server end alive to here, so that the connection being finished
    # is about the GOAWAY rather than about a socket that has gone.
    assert_true(peer.fd() >= 0)


def test_h2_a_server_that_stops_mid_frame_is_reported() raises:
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var request = _get()
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)
    _ = _skip_to_headers(peer)

    # A frame header promising sixty four octets, and then nothing.
    var out = Bytes()
    write_frame_header(FrameHeader(64, FrameType.HEADERS, UInt8(0), 1), out)
    peer.send_bytes(out.as_span())
    peer.half_close()

    with assert_raises():
        _ = driver.start_response(Deadline.after(5.0))


def test_h2_a_response_with_no_status_is_refused() raises:
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var request = _get()
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)
    _ = _skip_to_headers(peer)

    var fields = List[HeaderField]()
    fields.append(HeaderField(String("content-type"), String("text/plain")))
    peer.send_bytes(Span(_response_frame(1, fields^, end_stream=True)))

    with assert_raises():
        _ = driver.start_response(Deadline.after(5.0))


def test_h2_a_header_before_the_status_is_refused() raises:
    # RFC 9113 section 8.3. It matters because an intermediary joining the two
    # halves back into HTTP/1.1 would produce a different message from the one a
    # receiver that ignored the order saw.
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var request = _get()
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)
    _ = _skip_to_headers(peer)

    var fields = List[HeaderField]()
    fields.append(HeaderField(String("content-type"), String("text/plain")))
    fields.append(HeaderField(String(":status"), String("200")))
    peer.send_bytes(Span(_response_frame(1, fields^, end_stream=True)))

    with assert_raises():
        _ = driver.start_response(Deadline.after(5.0))


def test_h2_a_status_that_is_not_three_digits_is_refused() raises:
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var request = _get()
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)
    _ = _skip_to_headers(peer)

    var fields = List[HeaderField]()
    fields.append(HeaderField(String(":status"), String("2xx")))
    peer.send_bytes(Span(_response_frame(1, fields^, end_stream=True)))

    with assert_raises():
        _ = driver.start_response(Deadline.after(5.0))


def test_h2_an_unknown_pseudo_header_in_a_response_is_refused() raises:
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var request = _get()
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)
    _ = _skip_to_headers(peer)

    var fields = List[HeaderField]()
    fields.append(HeaderField(String(":status"), String("200")))
    fields.append(HeaderField(String(":made-up"), String("yes")))
    peer.send_bytes(Span(_response_frame(1, fields^, end_stream=True)))

    with assert_raises():
        _ = driver.start_response(Deadline.after(5.0))


def test_h2_trailers_end_the_body_and_are_kept() raises:
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var request = _get()
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)
    _ = _skip_to_headers(peer)

    peer.send_bytes(Span(_response_frame(1, _ok(), end_stream=False)))
    var body: List[UInt8] = [104, 105]
    peer.send_bytes(Span(_frame(FrameType.DATA, UInt8(0), 1, Span(body))))

    var trailers = List[HeaderField]()
    trailers.append(HeaderField(String("x-checksum"), String("abc")))
    peer.send_bytes(Span(_response_frame(1, trailers^, end_stream=True)))

    _ = driver.start_response(Deadline.after(5.0))
    assert_equal(len(driver.read_chunk(Deadline.after(5.0))), 2)
    assert_equal(len(driver.read_chunk(Deadline.after(5.0))), 0)
    assert_equal(driver.take_trailers().get("x-checksum"), "abc")


def test_h2_a_pseudo_header_in_trailers_is_refused() raises:
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var request = _get()
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)
    _ = _skip_to_headers(peer)

    peer.send_bytes(Span(_response_frame(1, _ok(), end_stream=False)))
    var body: List[UInt8] = [104, 105]
    peer.send_bytes(Span(_frame(FrameType.DATA, UInt8(0), 1, Span(body))))

    var trailers = List[HeaderField]()
    trailers.append(HeaderField(String(":status"), String("200")))
    peer.send_bytes(Span(_response_frame(1, trailers^, end_stream=True)))

    _ = driver.start_response(Deadline.after(5.0))
    assert_equal(len(driver.read_chunk(Deadline.after(5.0))), 2)
    with assert_raises():
        _ = driver.read_chunk(Deadline.after(5.0))


def test_h2_a_ping_is_answered_while_a_caller_waits_on_a_response() raises:
    # Nothing above this asked for the ping and nothing above it is told about
    # the answer. A connection that only responds when its caller happens to be
    # reading is one a server is entitled to give up on.
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var request = _get()
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)
    _ = _skip_to_headers(peer)

    var opaque: List[UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
    peer.send_bytes(Span(_frame(FrameType.PING, UInt8(0), 0, Span(opaque))))
    peer.send_bytes(Span(_response_frame(1, _ok(), end_stream=True)))

    var head = driver.start_response(Deadline.after(5.0))
    assert_equal(head.status_code, 200)

    # The settings acknowledgement comes first, then the ping answer.
    var acked = _read_frame(peer)
    assert_true(acked[0].type == FrameType.SETTINGS)
    assert_true(acked[0].has(FLAG_ACK))

    var pong = _read_frame(peer)
    assert_true(pong[0].type == FrameType.PING)
    assert_true(pong[0].has(FLAG_ACK))
    assert_equal(pong[1][0], 1)
    assert_equal(pong[1][7], 8)


def test_h2_a_frame_for_another_stream_is_stepped_over() raises:
    # An update for a stream that has finished arrives all the time, because the
    # server had it in flight before it knew. A caller waiting on its own stream
    # should never learn that it happened.
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var request = _get()
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)
    _ = _skip_to_headers(peer)

    var payload = Bytes()
    write_uint32(1024, payload)
    peer.send_bytes(
        Span(_frame(FrameType.WINDOW_UPDATE, UInt8(0), 1, payload.as_span()))
    )
    peer.send_bytes(Span(_response_frame(1, _ok(), end_stream=True)))

    var head = driver.start_response(Deadline.after(5.0))
    assert_equal(head.status_code, 200)


def test_h2_a_second_request_before_the_first_is_answered_is_refused() raises:
    # One at a time, for now. A synchronous caller has no way to be waiting on
    # two responses, so a second request here is a bug rather than multiplexing.
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var first = _get()
    driver.send_request(first, Deadline.after(5.0))
    _greet(peer)

    var second = _get()
    with assert_raises():
        driver.send_request(second, Deadline.after(5.0))


def test_h2_body_bytes_before_any_response_headers_are_refused() raises:
    var listener = Loopback()
    var driver = _connect(listener)
    var peer = listener.accept_within()

    var request = _get()
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)
    _ = _skip_to_headers(peer)

    var body: List[UInt8] = [104, 105]
    peer.send_bytes(Span(_frame(FrameType.DATA, UInt8(0), 1, Span(body))))

    with assert_raises():
        _ = driver.start_response(Deadline.after(5.0))
