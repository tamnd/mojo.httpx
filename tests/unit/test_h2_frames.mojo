"""Tests for the HTTP/2 frame layer.

Most of these are about input a friendly peer never produces. The frame header
itself is nine octets that cannot be wrong, so the interesting behaviour is all
in the checks around it: a length that exceeds what we advertised, padding that
claims more room than the frame has, a type that must be on a stream arriving on
the connection.

The padding cases get more attention than their size suggests, because the pad
length is counted inside the announced length and so a frame can describe a
payload that does not fit inside itself. Getting that wrong does not produce a
parse failure, it produces a body of the wrong length, which is a disagreement
about message boundaries and therefore the same class of bug as request
smuggling in HTTP/1.1.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from httpx._bytes import Bytes
from httpx._proto.h2.frames import (
    DEFAULT_MAX_FRAME_SIZE,
    ErrorCode,
    FLAG_ACK,
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FLAG_PADDED,
    FLAG_PRIORITY,
    FRAME_HEADER_SIZE,
    FrameHeader,
    FrameType,
    MAX_MAX_FRAME_SIZE,
    PREFACE,
    check_fixed_length,
    check_frame_length,
    check_on_connection,
    check_on_stream,
    parse_frame_header,
    parse_goaway,
    parse_priority,
    parse_window_update,
    strip_padding,
    strip_priority,
    write_frame_header,
)

comptime _DIGITS = StaticString("0123456789abcdef")


def _digit(byte: UInt8) -> Int:
    if byte >= UInt8(ord("a")):
        return Int(byte - UInt8(ord("a"))) + 10
    return Int(byte - UInt8(ord("0")))


def _octets(text: StringSpan) -> Bytes:
    var source = text.as_bytes()
    var out = Bytes()
    for i in range(0, len(source), 2):
        out.append(UInt8(_digit(source[i]) * 16 + _digit(source[i + 1])))
    return out^


def _hex(data: Bytes) -> String:
    var out = String()
    for i in range(len(data)):
        var high = Int(data[i] >> 4)
        var low = Int(data[i] & 0xF)
        out += _DIGITS[byte = high : high + 1]
        out += _DIGITS[byte = low : low + 1]
    return out^


def _header(
    length: Int, type: FrameType, flags: UInt8, stream_id: UInt32
) -> FrameHeader:
    return FrameHeader(length, type, flags, stream_id)


def test_the_preface_is_the_twenty_four_octets_the_rfc_prints() raises:
    assert_equal(PREFACE.byte_length(), 24)
    assert_equal(
        _hex(_octets("505249202a20485454502f322e300d0a0d0a534d0d0a0d0a")),
        _hex(Bytes(PREFACE.as_bytes())),
    )


def test_a_frame_header_round_trips() raises:
    var header = _header(
        0x123456, FrameType.HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 7
    )
    var out = Bytes()
    write_frame_header(header, out)

    assert_equal(len(out), FRAME_HEADER_SIZE)
    assert_equal(_hex(out), "1234560105" + "00000007")

    var back = parse_frame_header(out.as_span(), 0)
    assert_equal(back.length, 0x123456)
    assert_true(back.type == FrameType.HEADERS)
    assert_equal(back.flags, FLAG_END_HEADERS | FLAG_END_STREAM)
    assert_equal(back.stream_id, 7)
    assert_true(back.has(FLAG_END_STREAM))
    assert_false(back.has(FLAG_PADDED))


def test_the_reserved_bit_above_the_stream_id_is_ignored_not_refused() raises:
    # RFC 9113 section 4.1 requires a receiver to ignore it, so that it can be
    # given a meaning later without every existing implementation objecting.
    var data = _octets("000000" + "00" + "00" + "80000001")
    var header = parse_frame_header(data.as_span(), 0)
    assert_equal(header.stream_id, 1)


def test_a_frame_header_is_read_from_where_it_was_asked_for() raises:
    var data = _octets("ffff" + "000004" + "04" + "01" + "00000000")
    var header = parse_frame_header(data.as_span(), 2)
    assert_equal(header.length, 4)
    assert_true(header.type == FrameType.SETTINGS)
    assert_true(header.has(FLAG_ACK))


def test_a_frame_type_nobody_has_heard_of_keeps_its_value() raises:
    # RFC 9113 section 4.1. An unknown type is discarded by the connection, not
    # refused here, which is what leaves room for extensions.
    var data = _octets("000000" + "ef" + "00" + "00000000")
    var header = parse_frame_header(data.as_span(), 0)
    assert_equal(header.type.value, 0xEF)
    assert_equal(String(header.type.name()), "an unknown frame type")


def test_a_length_over_what_we_advertised_is_refused() raises:
    var at_limit = _header(DEFAULT_MAX_FRAME_SIZE, FrameType.DATA, 0, 1)
    check_frame_length(at_limit, DEFAULT_MAX_FRAME_SIZE)

    var over = _header(DEFAULT_MAX_FRAME_SIZE + 1, FrameType.DATA, 0, 1)
    with assert_raises():
        check_frame_length(over, DEFAULT_MAX_FRAME_SIZE)


def test_the_largest_length_the_field_can_say_is_still_checked() raises:
    # Three octets can announce sixteen megabytes, and the check has to happen
    # before the payload is read or it has already done what it was told.
    var huge = _header(MAX_MAX_FRAME_SIZE, FrameType.DATA, 0, 1)
    with assert_raises():
        check_frame_length(huge, DEFAULT_MAX_FRAME_SIZE)


def test_a_fixed_shape_frame_of_the_wrong_size_is_refused() raises:
    check_fixed_length(_header(4, FrameType.RST_STREAM, 0, 1), 4)
    with assert_raises():
        check_fixed_length(_header(5, FrameType.RST_STREAM, 0, 1), 4)
    with assert_raises():
        check_fixed_length(_header(0, FrameType.PING, 0, 0), 8)


def test_a_stream_frame_on_the_connection_is_refused() raises:
    check_on_stream(_header(0, FrameType.HEADERS, 0, 1))
    with assert_raises():
        check_on_stream(_header(0, FrameType.HEADERS, 0, 0))


def test_a_connection_frame_on_a_stream_is_refused() raises:
    check_on_connection(_header(0, FrameType.SETTINGS, 0, 0))
    with assert_raises():
        check_on_connection(_header(0, FrameType.SETTINGS, 0, 3))


def _padded(flags: UInt8, hexed: StringSpan) raises -> String:
    var payload = _octets(hexed)
    var header = _header(len(payload), FrameType.DATA, flags, 1)
    var out = Bytes()
    out.extend(strip_padding(header, payload.as_span()))
    return _hex(out)


def test_a_frame_without_the_padded_flag_is_left_alone() raises:
    assert_equal(_padded(0, "0561626364"), "0561626364")


def test_padding_and_the_octet_that_counts_it_both_come_off() raises:
    # Two of padding, so the pad length octet, then `abc`, then two zeros.
    assert_equal(_padded(FLAG_PADDED, "02" + "616263" + "0000"), "616263")


def test_padding_that_fills_the_frame_leaves_nothing() raises:
    assert_equal(_padded(FLAG_PADDED, "03" + "000000"), "")


def test_padding_that_does_not_fit_in_the_frame_is_refused() raises:
    # Four claimed with three octets to take it from. Clamping here would mean
    # reading a different number of body octets than the sender wrote, which is
    # a disagreement about where the message ends.
    with assert_raises():
        _ = _padded(FLAG_PADDED, "04" + "000000")


def test_a_padded_frame_with_no_room_for_the_pad_length_is_refused() raises:
    with assert_raises():
        _ = _padded(FLAG_PADDED, "")


def test_the_priority_block_comes_off_after_the_padding() raises:
    # RFC 9113 section 6.2 puts the pad length first and the padding last, with
    # the priority block between them, so the two have to be stripped in order.
    var payload = _octets("02" + "8000000305" + "616263" + "0000")
    var header = _header(
        len(payload), FrameType.HEADERS, FLAG_PADDED | FLAG_PRIORITY, 1
    )

    var inner = strip_padding(header, payload.as_span())
    var priority = parse_priority(inner, 0)
    assert_true(priority.exclusive)
    assert_equal(priority.depends_on, 3)
    assert_equal(priority.weight, 5)

    var out = Bytes()
    out.extend(strip_priority(header, inner))
    assert_equal(_hex(out), "616263")


def test_a_priority_flag_with_no_room_for_the_block_is_refused() raises:
    var payload = _octets("00000003")
    var header = _header(len(payload), FrameType.HEADERS, FLAG_PRIORITY, 1)
    with assert_raises():
        _ = strip_priority(header, payload.as_span())


def test_a_priority_block_without_the_exclusive_bit() raises:
    var payload = _octets("0000000f10")
    var priority = parse_priority(payload.as_span(), 0)
    assert_false(priority.exclusive)
    assert_equal(priority.depends_on, 15)
    assert_equal(priority.weight, 16)


def test_a_window_update_reads_the_low_thirty_one_bits() raises:
    var payload = _octets("8000ffff")
    var header = _header(4, FrameType.WINDOW_UPDATE, 0, 1)
    assert_equal(parse_window_update(header, payload.as_span()), 0xFFFF)


def test_a_window_update_of_nothing_is_refused() raises:
    # Not a thing a working peer sends, and a stream of them is our time spent
    # for no purpose.
    var payload = _octets("00000000")
    var header = _header(4, FrameType.WINDOW_UPDATE, 0, 1)
    with assert_raises():
        _ = parse_window_update(header, payload.as_span())


def test_goaway_carries_the_last_stream_the_code_and_any_debug_text() raises:
    var payload = _octets("00000005" + "00000001" + "6f6f7073")
    var frame = parse_goaway(payload.as_span())
    assert_equal(frame.last_stream_id, 5)
    assert_true(frame.error_code == ErrorCode.PROTOCOL_ERROR)
    assert_equal(frame.debug.to_string(), "oops")


def test_goaway_with_nothing_to_say_is_still_eight_octets() raises:
    var payload = _octets("00000000" + "00000000")
    var frame = parse_goaway(payload.as_span())
    assert_equal(frame.last_stream_id, 0)
    assert_true(frame.error_code == ErrorCode.NO_ERROR)
    assert_equal(len(frame.debug), 0)


def test_a_goaway_shorter_than_its_fixed_part_is_refused() raises:
    var payload = _octets("000000050000")
    with assert_raises():
        _ = parse_goaway(payload.as_span())


def test_an_error_code_nobody_has_heard_of_keeps_its_value() raises:
    var payload = _octets("00000000" + "0000ffff")
    var frame = parse_goaway(payload.as_span())
    assert_equal(frame.error_code.value, 0xFFFF)
    assert_equal(String(frame.error_code.name()), "an unknown error code")


def test_the_error_codes_are_the_numbers_the_rfc_gives_them() raises:
    assert_equal(ErrorCode.NO_ERROR.value, 0x0)
    assert_equal(ErrorCode.PROTOCOL_ERROR.value, 0x1)
    assert_equal(ErrorCode.FLOW_CONTROL_ERROR.value, 0x3)
    assert_equal(ErrorCode.FRAME_SIZE_ERROR.value, 0x6)
    assert_equal(ErrorCode.REFUSED_STREAM.value, 0x7)
    assert_equal(ErrorCode.ENHANCE_YOUR_CALM.value, 0xB)
    assert_equal(ErrorCode.HTTP_1_1_REQUIRED.value, 0xD)


def test_the_frame_types_are_the_numbers_the_rfc_gives_them() raises:
    assert_equal(FrameType.DATA.value, 0x0)
    assert_equal(FrameType.HEADERS.value, 0x1)
    assert_equal(FrameType.RST_STREAM.value, 0x3)
    assert_equal(FrameType.SETTINGS.value, 0x4)
    assert_equal(FrameType.PING.value, 0x6)
    assert_equal(FrameType.GOAWAY.value, 0x7)
    assert_equal(FrameType.WINDOW_UPDATE.value, 0x8)
    assert_equal(FrameType.CONTINUATION.value, 0x9)
