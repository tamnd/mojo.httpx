from std.testing import assert_equal, assert_false, assert_true

from httpx._exceptions import (
    ErrorKind,
    is_connect_timeout,
    is_decoding_error,
    is_http_error,
    is_network_error,
    is_protocol_error,
    is_proxy_error,
    is_request_error,
    is_status_error,
    is_stream_error,
    is_timeout,
    is_transport_error,
    kind_from_name,
    kind_of,
    message_of,
    new_error,
)


def test_kind_round_trips_through_the_message() raises:
    var e = new_error(ErrorKind.CONNECT_TIMEOUT, "no route to host")
    assert_equal(String(e), "ConnectTimeout: no route to host")
    assert_true(kind_of(e) == ErrorKind.CONNECT_TIMEOUT)
    assert_equal(message_of(e), "no route to host")


def test_a_node_matches_itself() raises:
    # `except ConnectTimeout` catches a ConnectTimeout, so matches() has to be
    # reflexive or every leaf predicate would be wrong.
    assert_true(ErrorKind.CONNECT_TIMEOUT.matches(ErrorKind.CONNECT_TIMEOUT))
    assert_true(ErrorKind.TIMEOUT.matches(ErrorKind.TIMEOUT))


def test_leaves_match_every_ancestor() raises:
    var k = ErrorKind.READ_TIMEOUT
    assert_true(k.matches(ErrorKind.TIMEOUT))
    assert_true(k.matches(ErrorKind.TRANSPORT_ERROR))
    assert_true(k.matches(ErrorKind.REQUEST_ERROR))
    assert_true(k.matches(ErrorKind.HTTP_ERROR))


def test_leaves_match_no_sibling() raises:
    var k = ErrorKind.READ_TIMEOUT
    assert_false(k.matches(ErrorKind.CONNECT_TIMEOUT))
    assert_false(k.matches(ErrorKind.WRITE_TIMEOUT))
    assert_false(k.matches(ErrorKind.POOL_TIMEOUT))
    assert_false(k.matches(ErrorKind.NETWORK_ERROR))
    assert_false(k.matches(ErrorKind.PROTOCOL_ERROR))
    assert_false(k.matches(ErrorKind.HTTP_STATUS_ERROR))


def test_the_whole_lattice_is_consistent() raises:
    """Every leaf satisfies all of its ancestors and none of its siblings.

    This is the test that keeps the nibble encoding honest. Adding a kind with
    a bad value shows up here rather than as a predicate that quietly returns
    the wrong answer three milestones later.
    """
    var leaves = [
        ErrorKind.CONNECT_TIMEOUT,
        ErrorKind.READ_TIMEOUT,
        ErrorKind.WRITE_TIMEOUT,
        ErrorKind.POOL_TIMEOUT,
        ErrorKind.CONNECT_ERROR,
        ErrorKind.READ_ERROR,
        ErrorKind.WRITE_ERROR,
        ErrorKind.CLOSE_ERROR,
        ErrorKind.LOCAL_PROTOCOL_ERROR,
        ErrorKind.REMOTE_PROTOCOL_ERROR,
    ]
    # Each leaf paired with the one interior node it belongs to.
    var parents = [
        ErrorKind.TIMEOUT,
        ErrorKind.TIMEOUT,
        ErrorKind.TIMEOUT,
        ErrorKind.TIMEOUT,
        ErrorKind.NETWORK_ERROR,
        ErrorKind.NETWORK_ERROR,
        ErrorKind.NETWORK_ERROR,
        ErrorKind.NETWORK_ERROR,
        ErrorKind.PROTOCOL_ERROR,
        ErrorKind.PROTOCOL_ERROR,
    ]
    var groups = [
        ErrorKind.TIMEOUT,
        ErrorKind.NETWORK_ERROR,
        ErrorKind.PROTOCOL_ERROR,
    ]

    for i in range(len(leaves)):
        var leaf = leaves[i]
        # Its own parent and every node above it.
        assert_true(leaf.matches(parents[i]))
        assert_true(leaf.matches(ErrorKind.TRANSPORT_ERROR))
        assert_true(leaf.matches(ErrorKind.REQUEST_ERROR))
        assert_true(leaf.matches(ErrorKind.HTTP_ERROR))
        # No other group.
        for j in range(len(groups)):
            if groups[j] != parents[i]:
                assert_false(leaf.matches(groups[j]))
        # No other leaf.
        for j in range(len(leaves)):
            if i != j:
                assert_false(leaf.matches(leaves[j]))


def test_stream_errors_are_not_http_errors() raises:
    # httpx2 keeps StreamError outside HTTPError on purpose: it means the
    # calling code has a bug, not that the network misbehaved. Catching
    # HTTPError must not swallow it.
    var e = new_error(ErrorKind.RESPONSE_NOT_READ, "call read() first")
    assert_true(is_stream_error(e))
    assert_false(is_http_error(e))
    assert_false(is_request_error(e))
    assert_false(is_transport_error(e))


def test_status_errors_are_http_but_not_transport() raises:
    var e = new_error(ErrorKind.HTTP_STATUS_ERROR, "404 Not Found for GET /x")
    assert_true(is_http_error(e))
    assert_true(is_status_error(e))
    assert_false(is_request_error(e))
    assert_false(is_transport_error(e))
    assert_false(is_timeout(e))


def test_unknown_errors_satisfy_nothing() raises:
    # An error from somewhere else in the program must never be mistaken for
    # one of ours, or a retry loop will retry something it should not.
    var e = Error("something else entirely")
    assert_true(kind_of(e) == ErrorKind.UNKNOWN)
    assert_false(is_http_error(e))
    assert_false(is_timeout(e))
    assert_false(is_transport_error(e))
    assert_false(is_stream_error(e))
    assert_false(is_status_error(e))
    # Nothing is lost when we cannot identify it.
    assert_equal(message_of(e), "something else entirely")


def test_a_colon_in_the_message_is_not_read_as_a_name() raises:
    # "no route: host down" has a colon but no leading kind name, and must not
    # be parsed as a kind called "no route".
    var e = Error("no route: host down")
    assert_true(kind_of(e) == ErrorKind.UNKNOWN)


def test_names_round_trip() raises:
    var kinds = [
        ErrorKind.HTTP_ERROR,
        ErrorKind.REQUEST_ERROR,
        ErrorKind.TRANSPORT_ERROR,
        ErrorKind.TIMEOUT,
        ErrorKind.CONNECT_TIMEOUT,
        ErrorKind.READ_TIMEOUT,
        ErrorKind.WRITE_TIMEOUT,
        ErrorKind.POOL_TIMEOUT,
        ErrorKind.NETWORK_ERROR,
        ErrorKind.CONNECT_ERROR,
        ErrorKind.READ_ERROR,
        ErrorKind.WRITE_ERROR,
        ErrorKind.CLOSE_ERROR,
        ErrorKind.PROTOCOL_ERROR,
        ErrorKind.LOCAL_PROTOCOL_ERROR,
        ErrorKind.REMOTE_PROTOCOL_ERROR,
        ErrorKind.PROXY_ERROR,
        ErrorKind.UNSUPPORTED_PROTOCOL,
        ErrorKind.DECODING_ERROR,
        ErrorKind.TOO_MANY_REDIRECTS,
        ErrorKind.INVALID_URL,
        ErrorKind.HTTP_STATUS_ERROR,
        ErrorKind.STREAM_ERROR,
        ErrorKind.STREAM_CONSUMED,
        ErrorKind.STREAM_CLOSED,
        ErrorKind.RESPONSE_NOT_READ,
        ErrorKind.REQUEST_NOT_READ,
        ErrorKind.COOKIE_CONFLICT,
        ErrorKind.INVALID_HEADER,
    ]
    for k in kinds:
        # Every kind has a distinct name, and that name maps back to it. If two
        # kinds ever share a name the round trip breaks here.
        assert_true(kind_from_name(k.name()) == k)
        # And it survives a trip through an actual raised error.
        assert_true(kind_of(new_error(k, "detail")) == k)


def test_predicates_agree_with_the_hierarchy() raises:
    var timeout = new_error(ErrorKind.POOL_TIMEOUT, "pool exhausted")
    assert_true(is_timeout(timeout))
    assert_false(is_network_error(timeout))
    assert_false(is_protocol_error(timeout))

    var network = new_error(ErrorKind.CONNECT_ERROR, "connection refused")
    assert_true(is_network_error(network))
    assert_true(is_transport_error(network))
    assert_false(is_timeout(network))
    assert_false(is_connect_timeout(network))

    var proxy = new_error(ErrorKind.PROXY_ERROR, "407 from proxy")
    assert_true(is_proxy_error(proxy))
    assert_true(is_transport_error(proxy))
    assert_false(is_network_error(proxy))

    var decoding = new_error(ErrorKind.DECODING_ERROR, "corrupt gzip stream")
    assert_true(is_decoding_error(decoding))
    assert_true(is_request_error(decoding))
    assert_false(is_transport_error(decoding))
