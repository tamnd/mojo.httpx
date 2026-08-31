"""Tests for the staggered connect race.

The interesting cases are all about a list where some addresses do not work.
A listener on loopback is the address that answers, and a port that was bound
and released is the address that does not, which is refused immediately and so
exercises the failure path without waiting for anything.

Nothing here asserts on how long the race took. The timing is the part that
varies between machines, and a test that pins it down is a test that fails for
reasons that have nothing to do with the code.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._exceptions import is_connect_error, is_connect_timeout
from httpx._ffi.netdb import SockAddr
from httpx._io.connect import connect_to_addresses, connect_to_host
from httpx._io.deadline import Deadline, connect_deadline
from httpx._io.dns import Resolver

from tests.support.loopback import Loopback, dead_address


def test_a_single_working_address_connects() raises:
    var listener = Loopback()
    var addresses: List[SockAddr] = [listener.addr]
    var stream = connect_to_addresses(
        Span(addresses), "loopback", Deadline.after(5.0)
    )
    assert_true(stream.is_open())
    assert_true(listener.has_pending())


def test_an_empty_list_of_addresses_is_an_error_not_a_wait() raises:
    var raised = False
    try:
        _ = connect_to_addresses(
            Span(List[SockAddr]()), "nowhere", Deadline.after(5.0)
        )
    except e:
        raised = True
        assert_true(is_connect_error(e))
        assert_true("nowhere" in String(e))
    assert_true(raised)


def test_a_dead_first_address_does_not_stop_the_second_from_winning() raises:
    # The whole point of the race. Serially this would still work, so what the
    # test pins down is that the failure of the first attempt is collected
    # rather than raised.
    var listener = Loopback()
    var addresses: List[SockAddr] = [dead_address(), listener.addr]
    var stream = connect_to_addresses(
        Span(addresses), "loopback", Deadline.after(5.0)
    )
    assert_true(stream.is_open())
    assert_true(listener.has_pending())


def test_a_working_first_address_wins_before_the_second_is_started() raises:
    # A connect to loopback finishes in well under the attempt delay, so the
    # second listener must never see a connection. If the stagger were not
    # there, both would.
    var winner = Loopback()
    var spare = Loopback()
    var addresses: List[SockAddr] = [winner.addr, spare.addr]
    var stream = connect_to_addresses(
        Span(addresses), "loopback", Deadline.after(5.0)
    )
    assert_true(stream.is_open())
    assert_true(winner.has_pending())
    assert_false(spare.has_pending())


def test_every_address_failing_reports_all_of_them() raises:
    # One error naming both, because "connection refused" on its own does not
    # say which of the two addresses was refused, and in the usual case they are
    # of different families.
    var first = dead_address()
    var second = dead_address()
    var addresses: List[SockAddr] = [first, second]
    var raised = False
    try:
        _ = connect_to_addresses(
            Span(addresses), "all dead", Deadline.after(5.0)
        )
    except e:
        raised = True
        assert_true(is_connect_error(e))
        assert_true("all dead" in String(e))
    assert_true(raised)


def test_a_single_failing_address_reports_the_reason_on_its_own() raises:
    # With one attempt there is nothing to disambiguate, so the message is the
    # errno text rather than a list with one entry in it.
    var addresses: List[SockAddr] = [dead_address()]
    var raised = False
    try:
        _ = connect_to_addresses(
            Span(addresses), "just one", Deadline.after(5.0)
        )
    except e:
        raised = True
        assert_false("\n" in String(e))
    assert_true(raised)


def test_a_race_with_no_time_left_raises_a_connect_timeout() raises:
    var listener = Loopback()
    var addresses: List[SockAddr] = [listener.addr]
    var raised = False
    try:
        _ = connect_to_addresses(
            Span(addresses),
            "loopback",
            connect_deadline(Optional[Float64](0.0)),
        )
    except e:
        raised = True
        assert_true(is_connect_timeout(e))
    assert_true(raised)


def test_connecting_by_name_resolves_and_then_races() raises:
    var listener = Loopback()
    var resolver = Resolver()
    var stream = connect_to_host(
        resolver, "localhost", listener.port, Deadline.after(5.0)
    )
    assert_true(stream.is_open())
    assert_equal(resolver.cached_count(), 1)
    # Keeps the listener alive to the end of the test. Mojo drops a value after
    # its last use, and a listener dropped at the line that read its port would
    # have closed before anything connected to it.
    assert_true(listener.has_pending())


def test_a_name_whose_addresses_all_fail_is_forgotten() raises:
    # So the retry gets a fresh answer. A stale record is the most likely reason
    # for every address of a host that used to work suddenly refusing.
    var listener = Loopback()
    var port = listener.port
    listener.close()

    var resolver = Resolver()
    var raised = False
    try:
        _ = connect_to_host(resolver, "localhost", port, Deadline.after(5.0))
    except e:
        raised = True
        assert_true(is_connect_error(e))
    assert_true(raised)
    assert_equal(resolver.cached_count(), 0)


def test_a_name_that_connects_stays_in_the_cache() raises:
    # The other half of the rule above. Forgetting on success would throw the
    # cache away on every request.
    var listener = Loopback()
    var resolver = Resolver()
    _ = connect_to_host(
        resolver, "localhost", listener.port, Deadline.after(5.0)
    )
    assert_equal(resolver.cached_count(), 1)
    assert_true(listener.has_pending())


def test_the_winner_is_the_connection_the_server_actually_accepted() raises:
    # Not just any open descriptor. A race that returned a socket belonging to
    # an attempt it had already given up on would pass every assertion above.
    var listener = Loopback()
    var addresses: List[SockAddr] = [dead_address(), listener.addr]
    var stream = connect_to_addresses(
        Span(addresses), "loopback", Deadline.after(5.0)
    )
    var peer = listener.accept_within()
    stream.write("ping".as_bytes(), Deadline.after(5.0))
    assert_equal(peer.recv_until("ping"), "ping")
