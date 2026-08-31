"""Tests for the pool key.

Every test here is really the same question asked about a different pair of
URLs: may a connection opened for one carry a request for the other. The answer
being wrong in the strict direction costs a connection. The answer being wrong in
the lenient direction sends a request, and whatever credentials are on it, to a
server it was not meant for.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._exceptions import is_invalid_url, is_unsupported_protocol
from httpx._models.url import URL
from httpx._pool.origin import Origin, origin_for


def _origin(text: StringSpan) raises -> Origin:
    return origin_for(URL(text))


def _rejected(text: StringSpan) raises -> String:
    var url = URL(text)
    try:
        _ = origin_for(url)
    except e:
        return String(e)
    raise Error("expected this URL to have no origin to connect to")


def test_an_http_url_gives_its_host_and_port() raises:
    var origin = _origin("http://example.com:8080/some/path?q=1")
    assert_equal(origin.scheme, "http")
    assert_equal(origin.host, "example.com")
    assert_equal(origin.port, 8080)


def test_the_default_port_is_filled_in_for_http() raises:
    var origin = _origin("http://example.com/")
    assert_equal(origin.port, 80)


def test_the_default_port_is_filled_in_for_https() raises:
    var origin = _origin("https://example.com/")
    assert_equal(origin.port, 443)
    assert_true(origin.is_secure())


def test_a_default_port_and_an_explicit_one_are_the_same_origin() raises:
    # Otherwise a program that writes the port in some places and not others
    # quietly keeps two pools, and every other request pays for a new
    # connection.
    assert_true(
        _origin("https://example.com/") == _origin("https://example.com:443/")
    )


def test_the_path_and_query_are_not_part_of_the_origin() raises:
    assert_true(
        _origin("http://example.com/a?x=1")
        == _origin("http://example.com/b?y=2")
    )


def test_the_fragment_is_not_part_of_the_origin() raises:
    assert_true(
        _origin("http://example.com/#one") == _origin("http://example.com/#two")
    )


def test_userinfo_is_not_part_of_the_origin() raises:
    # Two requests to the same server with different credentials still share a
    # connection, which is correct: the credentials travel in the request, not
    # in the socket.
    assert_true(
        _origin("http://a:b@example.com/") == _origin("http://example.com/")
    )


def test_a_different_host_is_a_different_origin() raises:
    assert_true(
        _origin("http://example.com/") != _origin("http://example.org/")
    )


def test_a_different_port_is_a_different_origin() raises:
    assert_true(
        _origin("http://example.com/") != _origin("http://example.com:8080/")
    )


def test_http_and_https_on_one_host_are_different_origins() raises:
    # The one that would be tempting to collapse, since the host and the port
    # could match. Reusing a plaintext connection for an https request would
    # send the request in the clear.
    assert_true(
        _origin("http://example.com:443/")
        != _origin("https://example.com:443/")
    )


def test_host_casing_does_not_make_a_new_origin() raises:
    assert_true(
        _origin("http://EXAMPLE.com/") == _origin("http://example.com/")
    )


def test_an_internationalised_host_is_keyed_by_its_a_label() raises:
    # Whatever the user typed, the connection goes to the encoded name, so that
    # is what the pool has to be keyed by.
    var origin = _origin("http://ünicode.example/")
    assert_true(origin.host.startswith("xn--"))


def test_an_ipv6_host_keeps_its_brackets_off() raises:
    var origin = _origin("http://[::1]:8080/")
    assert_equal(origin.host, "::1")
    assert_equal(origin.port, 8080)


def test_a_relative_url_has_no_origin() raises:
    var url = URL("/just/a/path")
    var raised = False
    try:
        _ = origin_for(url)
    except e:
        raised = True
        assert_true(is_invalid_url(e))
    assert_true(raised)


def test_a_scheme_this_library_does_not_speak_is_rejected() raises:
    var url = URL("ftp://example.com/file")
    var raised = False
    try:
        _ = origin_for(url)
    except e:
        raised = True
        assert_true(is_unsupported_protocol(e))
    assert_true(raised)


def test_the_rejection_names_the_scheme() raises:
    # A user who typed the wrong scheme wants to be told which one, not that
    # something unspecified was unsupported.
    var message = _rejected("ftp://example.com/file")
    assert_true("ftp" in message)


def test_an_origin_prints_as_a_url_with_the_port_shown() raises:
    assert_equal(
        String(_origin("https://example.com/")), "https://example.com:443"
    )
