"""Tests for the `SETTINGS` frame.

The interesting half is the three parameters with ranges, because those are the
ones where a peer can hand us a number that is legal to write down and not legal
to act on. The other half is what happens to a setting we have never heard of,
which has to be ignored rather than refused, and is the reason the identifier
space cannot be treated as closed.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from httpx._bytes import Bytes
from httpx._proto.h2.frames import (
    DEFAULT_MAX_FRAME_SIZE,
    DEFAULT_WINDOW_SIZE,
    FLAG_ACK,
    FrameHeader,
    FrameType,
    MAX_MAX_FRAME_SIZE,
    MAX_WINDOW,
    MIN_MAX_FRAME_SIZE,
)
from httpx._proto.h2.settings import (
    SETTING_ENABLE_PUSH,
    SETTING_HEADER_TABLE_SIZE,
    SETTING_INITIAL_WINDOW_SIZE,
    SETTING_MAX_CONCURRENT_STREAMS,
    SETTING_MAX_FRAME_SIZE,
    SETTING_MAX_HEADER_LIST_SIZE,
    SETTING_SIZE,
    Settings,
    UNLIMITED,
    apply_settings,
    check_settings_length,
    write_settings,
)
from httpx._proto.h2.table import DEFAULT_TABLE_SIZE


def _settings_header(length: Int, flags: UInt8) -> FrameHeader:
    return FrameHeader(length, FrameType.SETTINGS, flags, 0)


def test_the_defaults_are_the_ones_the_rfc_gives() raises:
    # A connection where neither side sends a SETTINGS parameter still has to
    # agree about every one of them, so these numbers are the protocol and not
    # a choice.
    var settings = Settings()
    assert_equal(settings.header_table_size, DEFAULT_TABLE_SIZE)
    assert_true(settings.enable_push)
    assert_equal(settings.max_concurrent_streams, UNLIMITED)
    assert_equal(settings.initial_window_size, DEFAULT_WINDOW_SIZE)
    assert_equal(settings.max_frame_size, DEFAULT_MAX_FRAME_SIZE)
    assert_equal(settings.max_header_list_size, UNLIMITED)


def test_each_parameter_is_taken() raises:
    var settings = Settings()
    settings.apply(SETTING_HEADER_TABLE_SIZE, 8192)
    settings.apply(SETTING_ENABLE_PUSH, 0)
    settings.apply(SETTING_MAX_CONCURRENT_STREAMS, 100)
    settings.apply(SETTING_INITIAL_WINDOW_SIZE, 1048576)
    settings.apply(SETTING_MAX_FRAME_SIZE, 32768)
    settings.apply(SETTING_MAX_HEADER_LIST_SIZE, 16384)

    assert_equal(settings.header_table_size, 8192)
    assert_false(settings.enable_push)
    assert_equal(settings.max_concurrent_streams, 100)
    assert_equal(settings.initial_window_size, 1048576)
    assert_equal(settings.max_frame_size, 32768)
    assert_equal(settings.max_header_list_size, 16384)


def test_a_setting_nobody_has_heard_of_is_ignored() raises:
    # RFC 9113 section 6.5.3. Refusing would make this implementation the
    # reason a peer could not adopt a new one.
    var settings = Settings()
    settings.apply(0xABCD, 12345)
    settings.apply(0xFFFF, 0)
    assert_equal(settings.max_frame_size, DEFAULT_MAX_FRAME_SIZE)


def test_enable_push_is_a_flag_and_nothing_else() raises:
    var settings = Settings()
    settings.apply(SETTING_ENABLE_PUSH, 0)
    assert_false(settings.enable_push)
    settings.apply(SETTING_ENABLE_PUSH, 1)
    assert_true(settings.enable_push)
    with assert_raises():
        settings.apply(SETTING_ENABLE_PUSH, 2)


def test_an_initial_window_over_what_a_window_holds_is_refused() raises:
    var settings = Settings()
    settings.apply(SETTING_INITIAL_WINDOW_SIZE, UInt32(MAX_WINDOW))
    assert_equal(settings.initial_window_size, MAX_WINDOW)
    with assert_raises():
        settings.apply(SETTING_INITIAL_WINDOW_SIZE, UInt32(MAX_WINDOW) + 1)


def test_a_max_frame_size_outside_its_range_is_refused() raises:
    var settings = Settings()
    settings.apply(SETTING_MAX_FRAME_SIZE, UInt32(MIN_MAX_FRAME_SIZE))
    settings.apply(SETTING_MAX_FRAME_SIZE, UInt32(MAX_MAX_FRAME_SIZE))
    assert_equal(settings.max_frame_size, MAX_MAX_FRAME_SIZE)

    # The floor matters as much as the ceiling. A tiny maximum would force
    # every header block into a long run of CONTINUATION frames, which costs us
    # to reassemble and costs the peer almost nothing to ask for.
    with assert_raises():
        settings.apply(SETTING_MAX_FRAME_SIZE, UInt32(MIN_MAX_FRAME_SIZE) - 1)
    with assert_raises():
        settings.apply(SETTING_MAX_FRAME_SIZE, UInt32(MAX_MAX_FRAME_SIZE) + 1)


def _payload(pairs: List[Tuple[UInt32, UInt32]]) -> Bytes:
    var out = Bytes()
    for i in range(len(pairs)):
        var identifier = pairs[i][0]
        var value = pairs[i][1]
        out.append(UInt8((identifier >> 8) & 0xFF))
        out.append(UInt8(identifier & 0xFF))
        out.append(UInt8((value >> 24) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8(value & 0xFF))
    return out^


def test_a_payload_of_several_settings_applies_all_of_them() raises:
    var pairs = List[Tuple[UInt32, UInt32]]()
    pairs.append((SETTING_MAX_CONCURRENT_STREAMS, UInt32(250)))
    pairs.append((SETTING_INITIAL_WINDOW_SIZE, UInt32(65535)))
    pairs.append((SETTING_MAX_FRAME_SIZE, UInt32(16384)))

    var payload = _payload(pairs)
    assert_equal(len(payload), 3 * SETTING_SIZE)

    var settings = Settings()
    apply_settings(settings, payload.as_span())
    assert_equal(settings.max_concurrent_streams, 250)
    assert_equal(settings.initial_window_size, 65535)
    assert_equal(settings.max_frame_size, 16384)


def test_the_same_setting_twice_takes_the_last_one() raises:
    # RFC 9113 section 6.5 allows the repeat and says the last wins, which
    # applying in order gives for free.
    var pairs = List[Tuple[UInt32, UInt32]]()
    pairs.append((SETTING_MAX_CONCURRENT_STREAMS, UInt32(10)))
    pairs.append((SETTING_MAX_CONCURRENT_STREAMS, UInt32(20)))

    var settings = Settings()
    apply_settings(settings, _payload(pairs).as_span())
    assert_equal(settings.max_concurrent_streams, 20)


def test_a_settings_payload_that_is_not_whole_settings_is_refused() raises:
    check_settings_length(_settings_header(0, 0))
    check_settings_length(_settings_header(SETTING_SIZE * 3, 0))
    with assert_raises():
        check_settings_length(_settings_header(SETTING_SIZE * 3 - 1, 0))
    with assert_raises():
        check_settings_length(_settings_header(1, 0))


def test_an_acknowledgement_carries_nothing() raises:
    check_settings_length(_settings_header(0, FLAG_ACK))
    with assert_raises():
        check_settings_length(_settings_header(SETTING_SIZE, FLAG_ACK))


def test_what_we_announce_reads_back_as_what_we_meant() raises:
    var ours = Settings()
    ours.header_table_size = 8192
    ours.enable_push = False
    ours.initial_window_size = 1048576
    ours.max_frame_size = 32768
    ours.max_header_list_size = 65536

    var payload = Bytes()
    write_settings(ours, payload)
    assert_equal(len(payload) % SETTING_SIZE, 0)

    var theirs = Settings()
    apply_settings(theirs, payload.as_span())
    assert_equal(theirs.header_table_size, 8192)
    assert_false(theirs.enable_push)
    assert_equal(theirs.initial_window_size, 1048576)
    assert_equal(theirs.max_frame_size, 32768)
    assert_equal(theirs.max_header_list_size, 65536)

    # Not announced, because it bounds streams the peer opens towards us and
    # with push disabled there are none.
    assert_equal(theirs.max_concurrent_streams, UNLIMITED)


def test_an_unset_header_list_size_is_not_announced_as_a_number() raises:
    var ours = Settings()
    var with_limit = Bytes()
    write_settings(ours, with_limit)

    ours.max_header_list_size = 4096
    var and_now = Bytes()
    write_settings(ours, and_now)

    assert_equal(len(and_now) - len(with_limit), SETTING_SIZE)
