"""Tests that the four timeouts are enforced, not merely configurable.

A timeout that is carried around and never checked is worse than no timeout,
because the program that set it believes it is protected. So each phase gets a
test that provokes it through the whole stack, from a `Timeout` a caller could
have written down to the error that comes back out of the transport.

Three of the four are provoked with a budget that has already run out. That is
not a shortcut, it is the only way to test a connect, write or pool timeout
without depending on a slow network or a wedged peer, and what is being checked
is that the deadline is consulted at all on that path. The read timeout is the
one that can be provoked honestly, with a server that goes quiet, so it is
tested both ways: a server that stops talking must fail, and a server that
keeps dribbling must not.
"""

from std.testing import assert_equal, assert_true

from httpx._config import Timeout
from httpx._exceptions import (
    is_connect_timeout,
    is_pool_timeout,
    is_read_timeout,
    is_write_timeout,
)
from httpx._io.deadline import Deadlines
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._models.url import URL
from httpx._pool.limits import Limits
from httpx._transport.http import HTTPTransport

from tests.support.testserver import TestServer


def _send(
    mut transport: HTTPTransport,
    server: TestServer,
    path: StringSpan,
    timeout: Timeout,
) raises -> Response:
    """One GET to `server`, under `timeout`, with the server held alive.

    The server is passed in rather than used to build a URL at the call site
    because Mojo ends a value's life at its last use, and a test that did the
    latter would be connecting to a port that had already closed.
    """
    return transport.handle_request(
        Request("GET", URL(server.url(path))), timeout.deadlines()
    )


def test_a_read_timeout_fires_when_the_server_stops_talking() raises:
    var server = TestServer()
    var transport = HTTPTransport()
    var timeout = Timeout(
        Optional[Float64](5.0),
        Optional[Float64](0.3),
        Optional[Float64](5.0),
        Optional[Float64](5.0),
    )
    var raised = False
    try:
        _ = _send(transport, server, "/delay/3", timeout)
    except e:
        raised = True
        assert_true(is_read_timeout(e))
        assert_true("read" in String(e))
    assert_true(raised, "a silent server should have produced a read timeout")


def test_a_slow_but_steady_response_beats_the_read_timeout() raises:
    # The reason the read budget starts again on every read. This response takes
    # about a second to arrive and no single gap in it is longer than a twentieth
    # of that, so a read timeout of four tenths of a second must not fire. A read
    # timeout that covered the whole response would be a limit on how large a
    # download can be.
    var server = TestServer()
    var transport = HTTPTransport()
    var timeout = Timeout.uniform(Optional[Float64](0.4))
    var response = _send(transport, server, "/drip/20?delay=0.05", timeout)
    assert_equal(response.status_code, 200)
    assert_equal(len(response.content()), 20)


def test_a_spent_connect_budget_is_reported_as_a_connect_timeout() raises:
    var server = TestServer()
    var transport = HTTPTransport()
    var timeout = Timeout(
        Optional[Float64](0.0),
        Optional[Float64](5.0),
        Optional[Float64](5.0),
        Optional[Float64](5.0),
    )
    var raised = False
    try:
        _ = _send(transport, server, "/get", timeout)
    except e:
        raised = True
        assert_true(is_connect_timeout(e))
    assert_true(raised, "connecting with no time left should have failed")


def test_a_spent_write_budget_is_reported_as_a_write_timeout() raises:
    # Connect and read are given room on purpose, so that the only thing that
    # can fail is the write, and the error naming the write is the whole point.
    var server = TestServer()
    var transport = HTTPTransport()
    var timeout = Timeout(
        Optional[Float64](5.0),
        Optional[Float64](5.0),
        Optional[Float64](0.0),
        Optional[Float64](5.0),
    )
    var raised = False
    try:
        _ = _send(transport, server, "/get", timeout)
    except e:
        raised = True
        assert_true(is_write_timeout(e))
    assert_true(raised, "writing with no time left should have failed")


def test_a_spent_pool_budget_is_reported_as_a_pool_timeout() raises:
    # Distinct from a connect timeout because the wait was on this program
    # rather than on the network, and knowing which is what tells a user whether
    # to raise the limits or go and look at the server.
    var server = TestServer()
    var transport = HTTPTransport(Limits(5, 2, 30.0))
    var timeout = Timeout(
        Optional[Float64](5.0),
        Optional[Float64](5.0),
        Optional[Float64](5.0),
        Optional[Float64](0.0),
    )
    var raised = False
    try:
        _ = _send(transport, server, "/get", timeout)
    except e:
        raised = True
        assert_true(is_pool_timeout(e))
    assert_true(raised, "a spent pool budget should have failed")


def test_a_disabled_timeout_lets_a_slow_response_finish() raises:
    # No limit is a real setting, and it has to mean no limit rather than some
    # default that quietly reappears.
    var server = TestServer()
    var transport = HTTPTransport()
    var response = _send(transport, server, "/delay/1", Timeout.disabled())
    assert_equal(response.status_code, 200)


def test_an_ordinary_request_is_unaffected_by_the_default_timeout() raises:
    # The other half of every timeout test: the limits must not fire on a
    # response that arrives normally.
    var server = TestServer()
    var transport = HTTPTransport()
    var response = _send(transport, server, "/get", Timeout())
    assert_equal(response.status_code, 200)


def test_a_connection_that_timed_out_is_not_put_back_in_the_pool() raises:
    # A connection abandoned part way through a response has a server's half
    # written answer still coming down it. Handing that to the next request
    # would deliver somebody else's body.
    var server = TestServer()
    var transport = HTTPTransport()
    var timeout = Timeout.uniform(Optional[Float64](0.3))
    try:
        _ = _send(transport, server, "/delay/3", timeout)
    except:
        pass
    assert_equal(transport.pool.idle_count(), 0)
    assert_equal(transport.pool.leased_count(), 0)


def _send_with(
    mut transport: HTTPTransport,
    server: TestServer,
    path: StringSpan,
    deadlines: Deadlines,
) raises -> Response:
    return transport.handle_request(
        Request("GET", URL(server.url(path))), deadlines
    )


def test_deadlines_made_by_hand_still_reach_the_transport() raises:
    # Not everything goes through `Timeout`. The transport takes deadlines, so
    # a caller that builds them itself gets the same enforcement.
    var server = TestServer()
    var transport = HTTPTransport()
    var raised = False
    try:
        _ = _send_with(
            transport,
            server,
            "/delay/3",
            Deadlines.uniform(Optional[Float64](0.3)),
        )
    except e:
        raised = True
        assert_true(is_read_timeout(e))
    assert_true(raised, "a hand built deadline should be enforced too")
