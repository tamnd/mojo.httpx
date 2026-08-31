"""Tests for the IP literal parsers and writers.

Two things are being pinned down here. One is that every spelling of an address
reaches the same canonical string, because a client that treats `0177.0.0.1` and
`127.0.0.1` as two different hosts is a client whose allowlist can be walked
around. The other is that the parsers reject rather than guess, since a host
that is nearly an address is not an address, and resolving it as a name would
send the request somewhere nobody asked for.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from httpx._exceptions import is_invalid_url
from httpx._util.ip import (
    format_ipv6,
    looks_like_ipv4,
    parse_ipv4,
    parse_ipv6,
)


def _ipv6(text: StringSpan) raises -> String:
    return format_ipv6(parse_ipv6(text.as_bytes()))


def test_an_ipv6_address_is_written_the_rfc_5952_way() raises:
    # Lowercase hex, no leading zeros, and the longest run of zero groups as
    # `::`. Every one of these is the same address written differently, and all
    # of them have to come out the same or the connection pool keys them apart.
    assert_equal(_ipv6("::1"), "::1")
    assert_equal(_ipv6("0:0:0:0:0:0:0:1"), "::1")
    assert_equal(_ipv6("::0001"), "::1")
    assert_equal(
        _ipv6("2001:0DB8:0000:0000:0000:0000:1428:57ab"), "2001:db8::1428:57ab"
    )
    assert_equal(_ipv6("::"), "::")
    assert_equal(_ipv6("0:0:0:0:0:0:0:0"), "::")


def test_the_longest_run_of_zeros_is_the_one_that_is_collapsed() raises:
    # One group of zeros is written out rather than compressed, because `::`
    # standing for a single group saves nothing and gives two legal spellings.
    assert_equal(_ipv6("1:0:2:3:4:5:6:7"), "1:0:2:3:4:5:6:7")
    # Two runs of the same length go to the leftmost.
    assert_equal(_ipv6("1:0:0:2:0:0:3:4"), "1::2:0:0:3:4")
    assert_equal(_ipv6("1:0:0:2:0:0:0:3"), "1:0:0:2::3")


def test_a_trailing_dotted_quad_becomes_two_groups() raises:
    assert_equal(_ipv6("::1.2.3.4"), "::102:304")
    assert_equal(_ipv6("::ffff:192.168.0.1"), "::ffff:c0a8:1")
    assert_equal(_ipv6("1:2:3:4:5:6:1.2.3.4"), "1:2:3:4:5:6:102:304")


def test_an_ipv6_address_that_is_nearly_right_is_rejected() raises:
    var bad = [
        "1:2:3:4:5:6:7",
        "1:2:3:4:5:6:7:8:9",
        "1::2::3",
        ":1:2:3:4:5:6:7",
        "1:2:3:4:5:6:7:",
        "12345::",
        "::1.2.3",
        "::1.2.3.4.5",
        "::1.2.3.256",
        "::1.2.3.04",
        "::g",
        "",
    ]
    for i in range(len(bad)):
        with assert_raises():
            _ = parse_ipv6(bad[i].as_bytes())


def test_an_ipv6_failure_is_an_invalid_url() raises:
    # The caller is parsing a URL, so the kind has to say so rather than
    # surfacing as a generic error the caller has no branch for.
    try:
        _ = parse_ipv6(StringSpan("1:2:3").as_bytes())
        assert_true(False, "expected a rejection")
    except error:
        assert_true(is_invalid_url(error))


def test_every_spelling_of_an_address_reaches_the_same_quad() raises:
    # The C resolver has always taken all of these, so a check that only reads
    # the dotted form is a check that can be stepped around.
    assert_equal(parse_ipv4("127.0.0.1".as_bytes()), "127.0.0.1")
    assert_equal(parse_ipv4("0177.0.0.1".as_bytes()), "127.0.0.1")
    assert_equal(parse_ipv4("0x7f.0.0.1".as_bytes()), "127.0.0.1")
    assert_equal(parse_ipv4("0x7f.1".as_bytes()), "127.0.0.1")
    assert_equal(parse_ipv4("2130706433".as_bytes()), "127.0.0.1")
    assert_equal(parse_ipv4("0x7f000001".as_bytes()), "127.0.0.1")
    assert_equal(parse_ipv4("017700000001".as_bytes()), "127.0.0.1")


def test_fewer_than_four_parts_lets_the_last_one_carry_the_rest() raises:
    assert_equal(parse_ipv4("256".as_bytes()), "0.0.1.0")
    assert_equal(parse_ipv4("1.2.3".as_bytes()), "1.2.0.3")
    assert_equal(parse_ipv4("1.2".as_bytes()), "1.0.0.2")
    assert_equal(parse_ipv4("0".as_bytes()), "0.0.0.0")


def test_a_single_trailing_dot_does_not_change_the_address() raises:
    # `example.com.` and `example.com` are the same name, and the same has to
    # hold for an address or the two spellings are two hosts.
    assert_equal(parse_ipv4("1.2.3.4.".as_bytes()), "1.2.3.4")
    assert_equal(parse_ipv4("1.2.3.".as_bytes()), "1.2.0.3")
    assert_true(looks_like_ipv4("1.2.3.4.".as_bytes()))


def test_an_ipv4_address_that_does_not_fit_is_rejected() raises:
    var bad = [
        "1.2.3.4.5",
        "1.2.3.256",
        "256.1.1.1",
        "4294967296",
        "0x100000000",
        "1..2",
        "1.2..3",
        ".1.2.3",
    ]
    for i in range(len(bad)):
        with assert_raises():
            _ = parse_ipv4(bad[i].as_bytes())


def test_a_host_is_read_as_an_address_when_the_last_label_is_a_number() raises:
    # The test is on the last label only, which is what decides whether the
    # thing gets a DNS lookup or is dialled directly.
    assert_true(looks_like_ipv4("1.2.3.4".as_bytes()))
    assert_true(looks_like_ipv4("0x7f.1".as_bytes()))
    assert_true(looks_like_ipv4("foo.09".as_bytes()))
    assert_false(looks_like_ipv4("example.com".as_bytes()))
    assert_false(looks_like_ipv4("1.2.3.4a".as_bytes()))
    assert_false(looks_like_ipv4("".as_bytes()))


def test_a_number_too_large_for_an_address_is_still_a_number() raises:
    # This is the difference between `0xffffffff1` being an error and it being
    # a hostname somebody looks up. Overflowing has to leave it looking like an
    # address so the range check is the thing that turns it down.
    assert_true(looks_like_ipv4("0xffffffff1".as_bytes()))
    assert_true(looks_like_ipv4("foo.0XFfFfFfFfFfFfFfFfFfAcE123".as_bytes()))
    with assert_raises():
        _ = parse_ipv4("0xffffffff1".as_bytes())
    with assert_raises():
        _ = parse_ipv4("foo.0XFfFfFfFfFfFfFfFfFfAcE123".as_bytes())


def test_the_largest_address_still_parses() raises:
    assert_equal(parse_ipv4("4294967295".as_bytes()), "255.255.255.255")
    assert_equal(parse_ipv4("0xffffffff".as_bytes()), "255.255.255.255")
