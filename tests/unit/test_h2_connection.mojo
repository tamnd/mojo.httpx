"""Tests for the connection, driven by handing it frames.

Every test here is a sequence rather than a single frame, which is the whole
reason the connection has no socket in it. A settings change that resizes windows
mid transfer, a header block interrupted on another stream, a reset that arrives
after the response it was racing: none of those are one frame, and against
something that also owned a socket none of them would be three lines.

The frames are built by hand rather than by a helper that writes correct ones,
because most of what is being checked is what happens when they are not correct.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from httpx._bytes import Bytes
from httpx._proto.h2.connection import (
    H2Connection,
    H2EventKind,
    PING_SIZE,
    RST_STREAM_SIZE,
    WINDOW_UPDATE_SIZE,
)
from httpx._proto.h2.frames import (
    DEFAULT_WINDOW_SIZE,
    ErrorCode,
    FLAG_ACK,
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FLAG_PADDED,
    FRAME_HEADER_SIZE,
    FrameHeader,
    FrameType,
    PREFACE,
    parse_frame_header,
    write_uint32,
)
from httpx._proto.h2.hpack import HpackEncoder
from httpx._proto.h2.settings import (
    SETTING_INITIAL_WINDOW_SIZE,
    SETTING_MAX_CONCURRENT_STREAMS,
    Settings,
)
from httpx._proto.h2.stream import StreamState
from httpx._proto.h2.table import HeaderField


def _head(
    length: Int, type: FrameType, flags: UInt8, stream_id: UInt32
) -> FrameHeader:
    return FrameHeader(length, type, flags, stream_id)


def _bytes(var values: List[UInt8]) -> Bytes:
    return Bytes(values^)


def _setting(identifier: UInt32, value: UInt32) -> Bytes:
    var out = Bytes()
    out.append(UInt8((identifier >> 8) & 0xFF))
    out.append(UInt8(identifier & 0xFF))
    write_uint32(value, out)
    return out^


def _response_block(mut encoder: HpackEncoder, status: String) raises -> Bytes:
    var fields = List[HeaderField]()
    fields.append(HeaderField(String(":status"), status))
    var out = Bytes()
    encoder.encode(fields, out)
    return out^


def _request_fields() raises -> List[HeaderField]:
    var fields = List[HeaderField]()
    fields.append(HeaderField(String(":method"), String("GET")))
    fields.append(HeaderField(String(":scheme"), String("https")))
    fields.append(HeaderField(String(":authority"), String("example.com")))
    fields.append(HeaderField(String(":path"), String("/")))
    return fields^


def _started() raises -> H2Connection:
    var conn = H2Connection()
    conn.start()
    _ = conn.take_outbound()
    return conn^


def _open_one(mut conn: H2Connection) raises -> UInt32:
    var id = conn.send_headers(_request_fields(), end_stream=True)
    _ = conn.take_outbound()
    return id


def test_starting_sends_the_preface_and_then_settings() raises:
    var conn = H2Connection()
    conn.start()
    var out = conn.take_outbound()

    var preface = PREFACE.as_bytes()
    assert_equal(len(out) > len(preface), True)
    for i in range(len(preface)):
        assert_equal(out[i], preface[i])

    # The preface is not a frame, so the first frame header starts after it.
    var header = parse_frame_header(out.as_span(), len(preface))
    assert_true(header.type == FrameType.SETTINGS)
    assert_equal(header.stream_id, 0)
    assert_false(header.has(FLAG_ACK))


def test_the_opening_settings_turn_push_off() raises:
    # Not a preference. A client with nowhere to put a pushed response has
    # nothing to do with one but pay for it, so it is refused in the first frame
    # rather than declined once one arrives.
    var conn = H2Connection()
    assert_false(conn.settings.enable_push)


def test_a_header_list_bound_is_always_advertised() raises:
    # The RFC default is no bound at all, which is the HPACK bomb with the
    # safety off. A number is always sent, and the same number bounds our own
    # decoder, which is what makes it a promise rather than a hint.
    var conn = H2Connection()
    assert_true(conn.settings.max_header_list_size > 0)
    assert_equal(
        conn.decoder.max_header_list_size, conn.settings.max_header_list_size
    )


def test_a_response_head_over_the_advertised_bound_is_refused() raises:
    var conn = H2Connection(max_concurrent_streams=4)
    conn.start()
    _ = conn.take_outbound()
    conn.decoder.max_header_list_size = 40
    var id = _open_one(conn)

    var encoder = HpackEncoder()
    var fields = List[HeaderField]()
    fields.append(HeaderField(String(":status"), String("200")))
    fields.append(
        HeaderField(String("x-big"), String("0123456789012345678901234567890"))
    )
    var block = Bytes()
    encoder.encode(fields, block)

    with assert_raises():
        _ = conn.receive_frame(
            _head(len(block), FrameType.HEADERS, FLAG_END_HEADERS, id),
            block.as_span(),
        )


def test_taking_the_outbound_bytes_leaves_nothing_behind() raises:
    var conn = H2Connection()
    conn.start()
    assert_true(len(conn.take_outbound()) > 0)
    assert_equal(len(conn.take_outbound()), 0)


def test_a_settings_frame_is_acknowledged() raises:
    var conn = _started()
    var payload = _setting(SETTING_INITIAL_WINDOW_SIZE, 1000)
    var event = conn.receive_frame(
        _head(len(payload), FrameType.SETTINGS, UInt8(0), 0), payload.as_span()
    )
    assert_true(event.kind == H2EventKind.SETTINGS_CHANGED)
    assert_equal(conn.peer_settings.initial_window_size, 1000)

    var out = conn.take_outbound()
    var header = parse_frame_header(out.as_span(), 0)
    assert_true(header.type == FrameType.SETTINGS)
    assert_true(header.has(FLAG_ACK))
    assert_equal(header.length, 0)


def test_an_acknowledgement_of_our_settings_is_not_acknowledged_back() raises:
    # Acknowledging an acknowledgement is how two peers keep each other busy
    # forever, so the ACK flag is looked at before anything else is done.
    var conn = _started()
    var event = conn.receive_frame(
        _head(0, FrameType.SETTINGS, FLAG_ACK, 0), Bytes().as_span()
    )
    assert_true(event.kind == H2EventKind.SETTINGS_ACKED)
    assert_true(conn.settings_acked)
    assert_equal(len(conn.take_outbound()), 0)


def test_a_new_initial_window_size_shifts_the_windows_of_open_streams() raises:
    # RFC 9113 section 6.9.2. The setting shifts each stream window by the
    # difference rather than setting it, so octets already granted survive.
    var conn = _started()
    var id = _open_one(conn)
    assert_equal(conn.stream_state(id) == StreamState.HALF_CLOSED_LOCAL, True)

    var payload = _setting(
        SETTING_INITIAL_WINDOW_SIZE, DEFAULT_WINDOW_SIZE + 100
    )
    _ = conn.receive_frame(
        _head(len(payload), FrameType.SETTINGS, UInt8(0), 0), payload.as_span()
    )
    assert_equal(conn.streams[0].send.available, DEFAULT_WINDOW_SIZE + 100)


def test_the_connection_window_is_not_touched_by_the_initial_size_setting() raises:
    # The easiest thing in flow control to get wrong, and it only shows up
    # against servers that change the setting once streams are already open.
    var conn = _started()
    _ = _open_one(conn)

    var payload = _setting(SETTING_INITIAL_WINDOW_SIZE, 1000)
    _ = conn.receive_frame(
        _head(len(payload), FrameType.SETTINGS, UInt8(0), 0), payload.as_span()
    )
    assert_equal(conn.send_window.available, DEFAULT_WINDOW_SIZE)


def test_a_ping_is_echoed_back_unchanged() raises:
    var conn = _started()
    var payload = _bytes([1, 2, 3, 4, 5, 6, 7, 8])
    var event = conn.receive_frame(
        _head(PING_SIZE, FrameType.PING, UInt8(0), 0), payload.as_span()
    )
    assert_true(event.kind == H2EventKind.NOTHING)

    var out = conn.take_outbound()
    var header = parse_frame_header(out.as_span(), 0)
    assert_true(header.type == FrameType.PING)
    assert_true(header.has(FLAG_ACK))
    for i in range(PING_SIZE):
        assert_equal(out[FRAME_HEADER_SIZE + i], payload[i])


def test_a_ping_acknowledgement_is_not_echoed() raises:
    var conn = _started()
    var payload = _bytes([1, 2, 3, 4, 5, 6, 7, 8])
    var event = conn.receive_frame(
        _head(PING_SIZE, FrameType.PING, FLAG_ACK, 0), payload.as_span()
    )
    assert_true(event.kind == H2EventKind.PING_ACKED)
    assert_equal(len(conn.take_outbound()), 0)


def test_a_ping_of_the_wrong_length_is_refused() raises:
    var conn = _started()
    var payload = _bytes([1, 2, 3, 4])
    with assert_raises():
        _ = conn.receive_frame(
            _head(4, FrameType.PING, UInt8(0), 0), payload.as_span()
        )


def test_a_ping_on_a_stream_is_refused() raises:
    # PING is about the connection, and carrying one on a stream would leave it
    # ambiguous whether it applied to that stream alone.
    var conn = _started()
    var payload = _bytes([1, 2, 3, 4, 5, 6, 7, 8])
    with assert_raises():
        _ = conn.receive_frame(
            _head(PING_SIZE, FrameType.PING, UInt8(0), 1), payload.as_span()
        )


def test_a_goaway_closes_the_connection_to_new_streams() raises:
    var conn = _started()
    assert_true(conn.is_open())

    var payload = Bytes()
    write_uint32(0, payload)
    write_uint32(ErrorCode.NO_ERROR.value, payload)
    var event = conn.receive_frame(
        _head(len(payload), FrameType.GOAWAY, UInt8(0), 0), payload.as_span()
    )
    assert_true(event.kind == H2EventKind.GOAWAY)
    assert_false(conn.is_open())

    with assert_raises():
        _ = conn.send_headers(_request_fields(), end_stream=True)


def test_a_window_update_on_stream_zero_opens_the_connection_window() raises:
    var conn = _started()
    var payload = Bytes()
    write_uint32(500, payload)
    _ = conn.receive_frame(
        _head(WINDOW_UPDATE_SIZE, FrameType.WINDOW_UPDATE, UInt8(0), 0),
        payload.as_span(),
    )
    assert_equal(conn.send_window.available, DEFAULT_WINDOW_SIZE + 500)


def test_a_window_update_of_zero_is_refused() raises:
    var conn = _started()
    var payload = Bytes()
    write_uint32(0, payload)
    with assert_raises():
        _ = conn.receive_frame(
            _head(WINDOW_UPDATE_SIZE, FrameType.WINDOW_UPDATE, UInt8(0), 0),
            payload.as_span(),
        )


def test_a_window_update_on_a_finished_stream_is_discarded() raises:
    # The peer had it in flight before it knew the stream had ended. Refusing it
    # would make ending a stream a race the peer always loses.
    var conn = _started()
    var id = _open_one(conn)
    conn.send_rst_stream(id, ErrorCode.CANCEL)
    _ = conn.take_outbound()

    var payload = Bytes()
    write_uint32(500, payload)
    var event = conn.receive_frame(
        _head(WINDOW_UPDATE_SIZE, FrameType.WINDOW_UPDATE, UInt8(0), id),
        payload.as_span(),
    )
    assert_true(event.kind == H2EventKind.NOTHING)


def test_a_push_promise_is_refused() raises:
    var conn = _started()
    _ = _open_one(conn)
    var payload = Bytes()
    write_uint32(2, payload)
    with assert_raises():
        _ = conn.receive_frame(
            _head(len(payload), FrameType.PUSH_PROMISE, FLAG_END_HEADERS, 1),
            payload.as_span(),
        )


def test_an_unknown_frame_type_is_discarded_rather_than_refused() raises:
    # RFC 9113 section 4.1. Refusing would make this implementation the reason a
    # later specification could not add one.
    var conn = _started()
    var payload = _bytes([9, 9, 9])
    var event = conn.receive_frame(
        _head(3, FrameType(0x63), UInt8(0), 0), payload.as_span()
    )
    assert_true(event.kind == H2EventKind.NOTHING)


def test_a_frame_over_the_size_we_advertised_is_refused() raises:
    var conn = _started()
    var over = conn.settings.max_frame_size + 1
    with assert_raises():
        _ = conn.receive_frame(
            _head(over, FrameType.DATA, UInt8(0), 1), Bytes().as_span()
        )


def test_a_response_arrives_as_headers_and_data() raises:
    var conn = _started()
    var id = _open_one(conn)

    var encoder = HpackEncoder()
    var block = _response_block(encoder, String("200"))
    var event = conn.receive_frame(
        _head(len(block), FrameType.HEADERS, FLAG_END_HEADERS, id),
        block.as_span(),
    )
    assert_true(event.kind == H2EventKind.HEADERS)
    assert_equal(event.stream_id, id)
    assert_false(event.end_stream)
    assert_equal(event.fields[0].name, ":status")
    assert_equal(event.fields[0].value, "200")

    var body = _bytes([104, 105])
    var second = conn.receive_frame(
        _head(2, FrameType.DATA, FLAG_END_STREAM, id), body.as_span()
    )
    assert_true(second.kind == H2EventKind.DATA)
    assert_true(second.end_stream)
    assert_equal(len(second.data), 2)
    assert_equal(second.data[0], 104)


def test_a_finished_stream_is_dropped_rather_than_kept() raises:
    # A connection that remembered every stream it had opened would grow for as
    # long as it stayed up, and a peer that wanted it to grow faster only has to
    # make requests.
    var conn = _started()
    var id = _open_one(conn)
    assert_equal(len(conn.streams), 1)

    var encoder = HpackEncoder()
    var block = _response_block(encoder, String("204"))
    _ = conn.receive_frame(
        _head(
            len(block),
            FrameType.HEADERS,
            FLAG_END_HEADERS | FLAG_END_STREAM,
            id,
        ),
        block.as_span(),
    )
    assert_equal(len(conn.streams), 0)


def test_a_header_block_split_across_a_continuation_arrives_whole() raises:
    var conn = _started()
    var id = _open_one(conn)

    var encoder = HpackEncoder()
    var block = _response_block(encoder, String("200"))
    var cut = 1

    var first = Bytes()
    first.extend(block.as_span()[:cut])
    var event = conn.receive_frame(
        _head(len(first), FrameType.HEADERS, UInt8(0), id), first.as_span()
    )
    assert_true(event.kind == H2EventKind.NOTHING)

    var rest = Bytes()
    rest.extend(block.as_span()[cut:])
    var second = conn.receive_frame(
        _head(len(rest), FrameType.CONTINUATION, FLAG_END_HEADERS, id),
        rest.as_span(),
    )
    assert_true(second.kind == H2EventKind.HEADERS)
    assert_equal(second.fields[0].value, "200")


def test_a_frame_on_another_stream_during_a_header_block_is_refused() raises:
    # RFC 9113 section 6.10. Without this the two bounds on block size mean
    # nothing, since a peer could hold one open while doing as it liked.
    var conn = _started()
    var id = _open_one(conn)

    var encoder = HpackEncoder()
    var block = _response_block(encoder, String("200"))
    _ = conn.receive_frame(
        _head(len(block), FrameType.HEADERS, UInt8(0), id), block.as_span()
    )

    var payload = _bytes([1, 2, 3, 4, 5, 6, 7, 8])
    with assert_raises():
        _ = conn.receive_frame(
            _head(PING_SIZE, FrameType.PING, UInt8(0), 0), payload.as_span()
        )


def test_a_reset_closes_the_stream_and_is_counted() raises:
    var conn = _started()
    var id = _open_one(conn)

    var payload = Bytes()
    write_uint32(ErrorCode.CANCEL.value, payload)
    var event = conn.receive_frame(
        _head(RST_STREAM_SIZE, FrameType.RST_STREAM, UInt8(0), id),
        payload.as_span(),
    )
    assert_true(event.kind == H2EventKind.STREAM_RESET)
    assert_true(event.error_code == ErrorCode.CANCEL)
    assert_equal(len(conn.streams), 0)
    assert_equal(conn.resets.consecutive(), 1)


def test_a_response_that_gets_through_clears_the_run_of_resets() raises:
    var conn = _started()
    var first = _open_one(conn)

    var payload = Bytes()
    write_uint32(ErrorCode.CANCEL.value, payload)
    _ = conn.receive_frame(
        _head(RST_STREAM_SIZE, FrameType.RST_STREAM, UInt8(0), first),
        payload.as_span(),
    )
    assert_equal(conn.resets.consecutive(), 1)

    var second = _open_one(conn)
    var encoder = HpackEncoder()
    var block = _response_block(encoder, String("200"))
    _ = conn.receive_frame(
        _head(
            len(block),
            FrameType.HEADERS,
            FLAG_END_HEADERS | FLAG_END_STREAM,
            second,
        ),
        block.as_span(),
    )
    assert_equal(conn.resets.consecutive(), 0)


def test_a_run_of_resets_stops_the_connection() raises:
    # The client side of CVE-2023-44487: a server that resets everything and a
    # client that keeps opening more is a loop that finishes nothing.
    var conn = _started()
    var payload = Bytes()
    write_uint32(ErrorCode.REFUSED_STREAM.value, payload)

    with assert_raises():
        for _ in range(conn.resets.max_consecutive + 1):
            var id = _open_one(conn)
            _ = conn.receive_frame(
                _head(RST_STREAM_SIZE, FrameType.RST_STREAM, UInt8(0), id),
                payload.as_span(),
            )


def test_a_response_on_a_stream_we_never_opened_is_refused() raises:
    var conn = _started()
    var encoder = HpackEncoder()
    var block = _response_block(encoder, String("200"))
    with assert_raises():
        _ = conn.receive_frame(
            _head(len(block), FrameType.HEADERS, FLAG_END_HEADERS, 99),
            block.as_span(),
        )


def test_a_response_on_an_even_stream_is_refused() raises:
    var conn = _started()
    _ = _open_one(conn)
    var encoder = HpackEncoder()
    var block = _response_block(encoder, String("200"))
    with assert_raises():
        _ = conn.receive_frame(
            _head(len(block), FrameType.HEADERS, FLAG_END_HEADERS, 2),
            block.as_span(),
        )


def test_body_bytes_are_charged_to_the_connection_window_with_their_padding() raises:
    # RFC 9113 section 6.9.1 charges the frame and not its contents. Padding is
    # chosen by the sender, so a receiver that charged only what it kept would be
    # letting the sender decide what its own padding cost.
    var conn = _started()
    var id = _open_one(conn)

    # One pad length octet, two octets of body, three of padding.
    var payload = _bytes([3, 104, 105, 0, 0, 0])
    var event = conn.receive_frame(
        _head(len(payload), FrameType.DATA, FLAG_PADDED, id), payload.as_span()
    )
    assert_equal(len(event.data), 2)
    assert_equal(
        conn.recv_window.allowed(), conn.recv_window.capacity() - len(payload)
    )


def test_a_peer_that_sends_past_the_connection_window_is_refused() raises:
    var conn = _started()
    var id = _open_one(conn)
    var over = conn.recv_window.capacity() + 1
    with assert_raises():
        _ = conn.receive_frame(
            _head(over, FrameType.DATA, UInt8(0), id), Bytes().as_span()
        )


def test_nothing_is_returned_to_the_peer_until_enough_has_been_consumed() raises:
    var conn = _started()
    var id = _open_one(conn)
    conn.acknowledge(id, 10)
    assert_equal(len(conn.take_outbound()), 0)


def test_consuming_half_the_window_returns_it() raises:
    var conn = _started()
    var id = _open_one(conn)
    conn.acknowledge(id, conn.recv_window.capacity() // 2 + 1)

    var out = conn.take_outbound()
    var header = parse_frame_header(out.as_span(), 0)
    assert_true(header.type == FrameType.WINDOW_UPDATE)
    assert_equal(header.stream_id, 0)


def test_acknowledging_a_stream_that_has_gone_still_returns_connection_window() raises:
    # The stream finished while its last bytes were still being read. There is
    # nothing to give the stream and the connection window still matters.
    var conn = _started()
    var id = _open_one(conn)
    conn.send_rst_stream(id, ErrorCode.CANCEL)
    _ = conn.take_outbound()

    conn.acknowledge(id, conn.recv_window.capacity() // 2 + 1)
    var out = conn.take_outbound()
    var header = parse_frame_header(out.as_span(), 0)
    assert_true(header.type == FrameType.WINDOW_UPDATE)
    assert_equal(header.stream_id, 0)


def test_a_request_goes_out_as_one_headers_frame() raises:
    var conn = _started()
    var id = conn.send_headers(_request_fields(), end_stream=True)
    assert_equal(id, 1)

    var out = conn.take_outbound()
    var header = parse_frame_header(out.as_span(), 0)
    assert_true(header.type == FrameType.HEADERS)
    assert_equal(header.stream_id, 1)
    assert_true(header.has(FLAG_END_HEADERS))
    assert_true(header.has(FLAG_END_STREAM))
    assert_equal(len(out), FRAME_HEADER_SIZE + header.length)


def test_a_large_request_head_is_split_across_continuations() raises:
    # The peer's SETTINGS_MAX_FRAME_SIZE is the limit here, not ours. Ours
    # bounds what it may send us and says nothing about what it will accept.
    var conn = _started()
    conn.peer_settings.max_frame_size = 20

    var fields = _request_fields()
    fields.append(
        HeaderField(String("x-long"), String("abcdefghijklmnopqrstuvwxyz"))
    )
    _ = conn.send_headers(fields^, end_stream=True)

    var out = conn.take_outbound()
    var first = parse_frame_header(out.as_span(), 0)
    assert_true(first.type == FrameType.HEADERS)
    assert_false(first.has(FLAG_END_HEADERS))
    assert_equal(first.length, 20)

    var second = parse_frame_header(
        out.as_span(), FRAME_HEADER_SIZE + first.length
    )
    assert_true(second.type == FrameType.CONTINUATION)
    assert_equal(second.stream_id, 1)


def test_our_streams_are_numbered_upwards_by_two() raises:
    var conn = _started()
    assert_equal(conn.send_headers(_request_fields(), end_stream=True), 1)
    assert_equal(conn.send_headers(_request_fields(), end_stream=True), 3)
    assert_equal(conn.send_headers(_request_fields(), end_stream=True), 5)


def test_a_body_goes_out_as_far_as_the_window_allows() raises:
    var conn = _started()
    var id = conn.send_headers(_request_fields(), end_stream=False)
    _ = conn.take_outbound()

    var body = _bytes([1, 2, 3, 4, 5])
    assert_equal(conn.send_data(id, body.as_span(), end_stream=True), 5)

    var out = conn.take_outbound()
    var header = parse_frame_header(out.as_span(), 0)
    assert_true(header.type == FrameType.DATA)
    assert_true(header.has(FLAG_END_STREAM))
    assert_equal(header.length, 5)


def test_a_shut_window_sends_nothing_rather_than_failing() raises:
    # Zero is a normal answer. The caller waits for a WINDOW_UPDATE, and how
    # long that is worth waiting for is a deadline, which does not live here.
    var conn = _started()
    var id = conn.send_headers(_request_fields(), end_stream=False)
    _ = conn.take_outbound()
    conn.streams[0].send.available = 0

    var body = _bytes([1, 2, 3])
    assert_equal(conn.send_data(id, body.as_span(), end_stream=True), 0)
    assert_equal(len(conn.take_outbound()), 0)


def test_ending_a_stream_with_nothing_left_sends_an_empty_frame() raises:
    # A body handed over in pieces gives no way to know which piece was the last
    # until there is not another one, so the end arrives with nothing to carry.
    var conn = _started()
    var id = conn.send_headers(_request_fields(), end_stream=False)
    _ = conn.take_outbound()

    var nothing = Bytes()
    assert_equal(conn.send_data(id, nothing.as_span(), end_stream=True), 0)

    var out = conn.take_outbound()
    var header = parse_frame_header(out.as_span(), 0)
    assert_true(header.type == FrameType.DATA)
    assert_equal(header.length, 0)
    assert_true(header.has(FLAG_END_STREAM))


def test_a_shut_window_does_not_stop_a_stream_being_ended() raises:
    # The one thing a closed window has no say in. Flow control counts octets
    # and there are none, so a client with a shut window can still say it has
    # finished, which is what stops a request hanging on a body it has already
    # sent all of.
    var conn = _started()
    var id = conn.send_headers(_request_fields(), end_stream=False)
    _ = conn.take_outbound()
    conn.streams[0].send.available = 0

    var nothing = Bytes()
    assert_equal(conn.send_data(id, nothing.as_span(), end_stream=True), 0)

    var out = conn.take_outbound()
    var header = parse_frame_header(out.as_span(), 0)
    assert_true(header.type == FrameType.DATA)
    assert_true(header.has(FLAG_END_STREAM))


def test_a_body_larger_than_the_window_goes_out_in_pieces() raises:
    var conn = _started()
    var id = conn.send_headers(_request_fields(), end_stream=False)
    _ = conn.take_outbound()
    conn.streams[0].send.available = 2

    var body = _bytes([1, 2, 3, 4, 5])
    assert_equal(conn.send_data(id, body.as_span(), end_stream=True), 2)

    # End of stream was asked for and not given, because only part of the body
    # went out and a stream cannot end halfway through what it was carrying.
    var out = conn.take_outbound()
    var header = parse_frame_header(out.as_span(), 0)
    assert_false(header.has(FLAG_END_STREAM))


def test_a_body_is_charged_to_both_windows() raises:
    var conn = _started()
    var id = conn.send_headers(_request_fields(), end_stream=False)
    _ = conn.take_outbound()

    var body = _bytes([1, 2, 3, 4, 5])
    _ = conn.send_data(id, body.as_span(), end_stream=False)
    assert_equal(conn.send_window.available, DEFAULT_WINDOW_SIZE - 5)
    assert_equal(conn.streams[0].send.available, DEFAULT_WINDOW_SIZE - 5)


def test_a_body_on_a_stream_that_is_not_open_is_our_own_mistake() raises:
    var conn = _started()
    var body = _bytes([1, 2, 3])
    with assert_raises():
        _ = conn.send_data(7, body.as_span(), end_stream=True)


def test_the_peers_concurrency_limit_is_respected() raises:
    var conn = _started()
    var payload = _setting(SETTING_MAX_CONCURRENT_STREAMS, 2)
    _ = conn.receive_frame(
        _head(len(payload), FrameType.SETTINGS, UInt8(0), 0), payload.as_span()
    )
    assert_equal(conn.concurrency(), 2)

    _ = conn.send_headers(_request_fields(), end_stream=True)
    _ = conn.send_headers(_request_fields(), end_stream=True)
    assert_equal(conn.concurrency(), 0)

    with assert_raises():
        _ = conn.send_headers(_request_fields(), end_stream=True)


def test_our_own_limit_applies_when_the_peer_has_no_opinion() raises:
    # UNLIMITED from the peer means it has no opinion, not that we have none.
    var conn = H2Connection(max_concurrent_streams=3)
    conn.start()
    _ = conn.take_outbound()
    assert_equal(conn.concurrency(), 3)


def test_resetting_a_stream_ourselves_drops_it_and_says_so() raises:
    var conn = _started()
    var id = _open_one(conn)
    conn.send_rst_stream(id, ErrorCode.CANCEL)

    assert_equal(len(conn.streams), 0)
    var out = conn.take_outbound()
    var header = parse_frame_header(out.as_span(), 0)
    assert_true(header.type == FrameType.RST_STREAM)
    assert_equal(header.stream_id, id)
    assert_equal(header.length, RST_STREAM_SIZE)


def test_a_goaway_we_send_names_the_highest_stream_we_opened() raises:
    var conn = _started()
    _ = _open_one(conn)
    _ = _open_one(conn)
    conn.send_goaway(ErrorCode.NO_ERROR)

    var out = conn.take_outbound()
    var header = parse_frame_header(out.as_span(), 0)
    assert_true(header.type == FrameType.GOAWAY)
    assert_equal(header.length, 8)
    assert_equal(out[FRAME_HEADER_SIZE + 3], 3)


def test_a_priority_frame_is_accepted_and_does_nothing() raises:
    # RFC 9113 section 5.3.1 withdraws the scheme, so acting on the values would
    # be implementing something the specification has taken back. Peers still
    # send them, so refusing is not an option either.
    var conn = _started()
    var id = _open_one(conn)
    var payload = _bytes([0, 0, 0, 0, 16])
    var event = conn.receive_frame(
        _head(5, FrameType.PRIORITY, UInt8(0), id), payload.as_span()
    )
    assert_true(event.kind == H2EventKind.NOTHING)


def test_a_headers_frame_on_stream_zero_is_refused() raises:
    var conn = _started()
    with assert_raises():
        _ = conn.receive_frame(
            _head(0, FrameType.HEADERS, FLAG_END_HEADERS, 0), Bytes().as_span()
        )
