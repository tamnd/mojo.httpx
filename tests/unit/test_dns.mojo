"""Tests for name resolution, its cache, and the Happy Eyeballs ordering.

Nothing here touches the network. Every name used is either a literal address or
`localhost`, which resolves out of the hosts file, so the suite gives the same
answer on a laptop, in a container with no DNS, and on a plane.

The ordering tests build their address lists out of real resolved loopback
addresses rather than made up bytes, because the thing being ordered has to be
something `connect` would accept.
"""

from std.ffi import c_int
from std.testing import assert_equal, assert_true

from httpx._exceptions import is_connect_error
from httpx._ffi.netdb import AF_UNSPEC, SockAddr, resolve
from httpx._ffi.socket import AF_INET, AF_INET6
from httpx._io.dns import (
    MAX_CACHE_ENTRIES,
    Resolver,
    sort_for_happy_eyeballs,
)

from tests.support.loopback import has_ipv6_loopback


def _one(host: StringSpan, family: c_int) raises -> SockAddr:
    var found = resolve(host, 80, family)
    if len(found) == 0:
        raise Error("no address for " + String(host))
    return found[0]


def _families(addresses: List[SockAddr]) -> String:
    """The list as a string of 6s and 4s, so a failed ordering assertion reads
    as the thing that went wrong rather than as two lists of address bytes."""
    var out = String()
    for i in range(len(addresses)):
        if addresses[i].family == AF_INET6:
            out += "6"
        elif addresses[i].family == AF_INET:
            out += "4"
        else:
            out += "?"
    return out^


def test_an_address_written_out_is_not_looked_up() raises:
    # And is not cached either, because caching a literal caches a parse.
    var resolver = Resolver()
    var found = resolver.lookup("127.0.0.1", 8080)
    assert_true(len(found) >= 1)
    assert_equal(found[0].port(), UInt16(8080))
    assert_equal(resolver.cached_count(), 0)


def test_an_ipv6_literal_resolves_to_an_ipv6_address() raises:
    var resolver = Resolver()
    var found = resolver.lookup("::1", 443)
    assert_true(len(found) >= 1)
    assert_true(found[0].is_ipv6())
    assert_equal(found[0].port(), UInt16(443))


def test_a_name_resolves_and_is_remembered() raises:
    var resolver = Resolver()
    var found = resolver.lookup("localhost", 80)
    assert_true(len(found) >= 1)
    assert_equal(resolver.cached_count(), 1)


def test_the_second_lookup_of_a_name_comes_from_the_cache() raises:
    # The observable difference is the size of the table, since a hit and a miss
    # return the same addresses. What is being checked is that a hit does not
    # store a second copy of what it just found.
    var resolver = Resolver()
    var first = resolver.lookup("localhost", 80)
    var second = resolver.lookup("localhost", 80)
    assert_equal(resolver.cached_count(), 1)
    assert_equal(len(first), len(second))
    assert_equal(first[0].port(), second[0].port())


def test_the_same_name_on_two_ports_is_two_entries() raises:
    # The port is part of the address, not decoration on it, so a client talking
    # to 80 and 443 on one host must not get the first port's addresses back for
    # the second.
    var resolver = Resolver()
    _ = resolver.lookup("localhost", 80)
    _ = resolver.lookup("localhost", 443)
    assert_equal(resolver.cached_count(), 2)
    assert_equal(resolver.lookup("localhost", 443)[0].port(), UInt16(443))


def test_forgetting_a_host_makes_the_next_lookup_resolve_again() raises:
    var resolver = Resolver()
    _ = resolver.lookup("localhost", 80)
    assert_equal(resolver.cached_count(), 1)
    resolver.forget("localhost", 80)
    assert_equal(resolver.cached_count(), 0)
    _ = resolver.lookup("localhost", 80)
    assert_equal(resolver.cached_count(), 1)


def test_forgetting_a_host_that_was_never_looked_up_does_nothing() raises:
    var resolver = Resolver()
    _ = resolver.lookup("localhost", 80)
    resolver.forget("localhost", 443)
    assert_equal(resolver.cached_count(), 1)


def test_clearing_empties_the_cache() raises:
    var resolver = Resolver()
    _ = resolver.lookup("localhost", 80)
    _ = resolver.lookup("localhost", 443)
    resolver.clear()
    assert_equal(resolver.cached_count(), 0)


def test_a_zero_ttl_turns_the_cache_off() raises:
    # For the caller who wants every request to see whatever DNS says now.
    var resolver = Resolver(0)
    _ = resolver.lookup("localhost", 80)
    _ = resolver.lookup("localhost", 80)
    assert_equal(resolver.cached_count(), 0)


def test_the_cache_stops_growing_at_its_limit() raises:
    # A client walking a list of hosts must not be able to grow this without
    # bound. Ports stand in for hosts here so the test does no resolution.
    var resolver = Resolver()
    for port in range(1, MAX_CACHE_ENTRIES + 20):
        _ = resolver.lookup("localhost", UInt16(port))
    assert_equal(resolver.cached_count(), MAX_CACHE_ENTRIES)


def test_a_name_that_does_not_resolve_raises_a_connect_error() raises:
    # `.invalid` is reserved by RFC 2606 precisely so this cannot accidentally
    # start working one day.
    var resolver = Resolver()
    var raised = False
    try:
        _ = resolver.lookup("nothing.invalid", 80)
    except e:
        raised = True
        assert_true(is_connect_error(e))
    assert_true(raised)
    assert_equal(resolver.cached_count(), 0)


def test_an_empty_host_raises_rather_than_resolving_to_anything() raises:
    var resolver = Resolver()
    var raised = False
    try:
        _ = resolver.lookup("", 80)
    except:
        raised = True
    assert_true(raised)


def test_the_families_alternate_starting_with_ipv6() raises:
    var six = _one("::1", AF_INET6)
    var four = _one("127.0.0.1", AF_INET)
    var mixed: List[SockAddr] = [four, four, six, six]
    assert_equal(_families(sort_for_happy_eyeballs(mixed^)), "6464")


def test_the_longer_family_keeps_its_tail() raises:
    # Three IPv6 and one IPv4 is the ordinary shape of a large site's answer.
    # The two IPv6 addresses with nothing to alternate with go on the end rather
    # than being dropped.
    var six = _one("::1", AF_INET6)
    var four = _one("127.0.0.1", AF_INET)
    assert_equal(
        _families(sort_for_happy_eyeballs([six, six, six, four])),
        "6466",
    )
    assert_equal(
        _families(sort_for_happy_eyeballs([four, four, four, six])),
        "6444",
    )


def test_one_family_on_its_own_comes_back_unchanged() raises:
    var four = _one("127.0.0.1", AF_INET)
    var only: List[SockAddr] = [four.with_port(1), four.with_port(2)]
    var ordered = sort_for_happy_eyeballs(only^)
    assert_equal(ordered[0].port(), UInt16(1))
    assert_equal(ordered[1].port(), UInt16(2))


def test_the_order_within_a_family_is_preserved() raises:
    # The resolver already sorted each family by RFC 6724, and throwing that
    # away would be replacing a good answer with an arbitrary one. Ports stand
    # in for distinct addresses.
    var six = _one("::1", AF_INET6)
    var four = _one("127.0.0.1", AF_INET)
    var mixed: List[SockAddr] = [
        six.with_port(1),
        four.with_port(2),
        six.with_port(3),
        four.with_port(4),
    ]
    var ordered = sort_for_happy_eyeballs(mixed^)
    assert_equal(ordered[0].port(), UInt16(1))
    assert_equal(ordered[1].port(), UInt16(2))
    assert_equal(ordered[2].port(), UInt16(3))
    assert_equal(ordered[3].port(), UInt16(4))


def test_ordering_an_empty_list_gives_an_empty_list() raises:
    assert_equal(len(sort_for_happy_eyeballs(List[SockAddr]())), 0)


def test_a_family_we_do_not_know_goes_last_rather_than_being_dropped() raises:
    # A resolver returning something unexpected should cost a worse position in
    # the race, not a failed request.
    var four = _one("127.0.0.1", AF_INET)
    var odd = SockAddr(
        four.bytes, four.length, c_int(99), four.socktype, four.protocol
    )
    assert_equal(
        _families(sort_for_happy_eyeballs([odd, four, four])),
        "44?",
    )


def test_a_dual_stack_name_is_ordered_when_the_machine_has_ipv6() raises:
    # Skips rather than fails where there is no IPv6 loopback, because a CI
    # container without IPv6 configured is a fact about the container.
    if not has_ipv6_loopback():
        return
    var resolver = Resolver()
    var found = resolver.lookup("localhost", 80)
    var families = _families(found)
    # Whatever the machine has, IPv6 cannot come after IPv4 of the same rank.
    if "6" in families and "4" in families:
        assert_true(families.startswith("6"))
