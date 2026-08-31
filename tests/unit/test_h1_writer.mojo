"""Tests for request serialization.

Most of these assert on the exact bytes. That is usually a brittle way to test,
and here it is the point: what goes on the wire is an interface, servers and
proxies do react to the details, and a change that reorders the headers or drops
the space after a colon is a change somebody should have to look at.

The injection tests are the ones with teeth. A header value carrying a newline
becomes a second request at the far end, and a library that lets one through has
handed the caller's server to whoever supplied the value.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._exceptions import is_local_protocol_error
from httpx._models.headers import Headers
from httpx._models.request import Request
from httpx._models.url import URL
from httpx._proto.h1.writer import (
    TargetForm,
    chunk,
    framing_headers,
    request_target,
    serialize_head,
    terminal_chunk,
)


def _text(data: List[UInt8]) raises -> String:
    return String(StringSpan(from_utf8=Span(data)))


def _head(
    method: StringSpan,
    url: StringSpan,
    var headers: Headers = Headers(),
    form: TargetForm = TargetForm.ORIGIN,
) raises -> String:
    var request = Request(method, URL(url), headers^)
    return _text(serialize_head(request, form))


def _framing(
    method: StringSpan, var headers: Headers, length: Optional[Int]
) raises -> Headers:
    return framing_headers(method, headers, length)


def test_a_plain_get_serializes() raises:
    assert_equal(
        _head("GET", "http://example.com/"),
        "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n",
    )


def test_the_path_and_query_both_go_in_the_target() raises:
    assert_equal(
        _head("GET", "http://example.com/a/b?c=1&d=2"),
        "GET /a/b?c=1&d=2 HTTP/1.1\r\nHost: example.com\r\n\r\n",
    )


def test_an_empty_path_becomes_a_slash() raises:
    # A request line with an empty target is malformed, and a URL with no path
    # is not.
    assert_equal(
        _head("GET", "http://example.com"),
        "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n",
    )


def test_the_fragment_is_not_sent() raises:
    # It is for the client only, and sending it leaks where in a page a user
    # was to the server and to every log on the way.
    assert_equal(
        _head("GET", "http://example.com/a#section"),
        "GET /a HTTP/1.1\r\nHost: example.com\r\n\r\n",
    )


def test_a_default_port_is_not_in_the_host_header() raises:
    assert_equal(
        _head("GET", "http://example.com:80/"),
        "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n",
    )


def test_a_non_default_port_is_in_the_host_header() raises:
    assert_equal(
        _head("GET", "http://example.com:8080/"),
        "GET / HTTP/1.1\r\nHost: example.com:8080\r\n\r\n",
    )


def test_the_https_default_port_is_not_in_the_host_header() raises:
    assert_equal(
        _head("GET", "https://example.com:443/"),
        "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n",
    )


def test_credentials_in_the_url_do_not_reach_the_host_header() raises:
    # They would end up in the access log of every hop, which is not where a
    # password belongs.
    assert_equal(
        _head("GET", "http://user:pass@example.com/"),
        "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n",
    )


def test_the_method_is_uppercased() raises:
    assert_true(_head("get", "http://example.com/").startswith("GET / "))


def test_host_comes_first_and_then_the_headers_in_order() raises:
    var headers = Headers()
    headers.append("Accept", "*/*")
    headers.append("User-Agent", "test")
    assert_equal(
        _head("GET", "http://example.com/", headers^),
        (
            "GET / HTTP/1.1\r\nHost: example.com\r\nAccept: */*\r\nUser-Agent:"
            " test\r\n\r\n"
        ),
    )


def test_header_casing_is_sent_as_the_caller_wrote_it() raises:
    # Lookups do not care, but a few servers and more than a few WAFs do, and
    # normalising would make this library's requests stand out.
    var headers = Headers()
    headers.append("X-CamelCase", "v")
    assert_true(
        "X-CamelCase: v" in _head("GET", "http://example.com/", headers^)
    )


def test_a_host_header_the_caller_set_is_not_overridden() raises:
    # Setting it deliberately is how a caller reaches a virtual host through an
    # address that does not resolve to it, which is a real thing people do.
    var headers = Headers()
    headers.append("Host", "other.example")
    var head = _head("GET", "http://example.com/", headers^)
    assert_true("Host: other.example" in head)
    assert_false("Host: example.com" in head)


def test_a_duplicate_header_is_sent_twice() raises:
    var headers = Headers()
    headers.append("X-A", "1")
    headers.append("X-A", "2")
    var head = _head("GET", "http://example.com/", headers^)
    assert_true("X-A: 1\r\nX-A: 2" in head)


def test_an_absolute_target_is_used_for_a_proxy() raises:
    assert_equal(
        _head("GET", "http://example.com/a", Headers(), TargetForm.ABSOLUTE),
        "GET http://example.com/a HTTP/1.1\r\nHost: example.com\r\n\r\n",
    )


def test_an_absolute_target_keeps_a_non_default_port() raises:
    assert_true(
        "GET http://example.com:8080/a HTTP/1.1"
        in _head(
            "GET", "http://example.com:8080/a", Headers(), TargetForm.ABSOLUTE
        )
    )


def test_an_authority_target_is_used_for_connect() raises:
    # The port is there even though it is the scheme default, because there is
    # no scheme in an authority target to take a default from.
    assert_equal(
        request_target(URL("https://example.com/"), TargetForm.AUTHORITY),
        "example.com:443",
    )


def test_an_asterisk_target_is_just_an_asterisk() raises:
    assert_equal(
        request_target(URL("http://example.com/whatever"), TargetForm.ASTERISK),
        "*",
    )


def test_a_get_with_no_body_gets_no_content_length() raises:
    # Legal either way, and a GET with a length is the shape that makes some
    # servers wait for a body and some WAFs get interested.
    var framing = _framing("GET", Headers(), None)
    assert_equal(len(framing), 0)


def test_a_post_with_no_body_gets_an_explicit_zero() raises:
    var framing = _framing("POST", Headers(), None)
    assert_equal(framing["content-length"], "0")


def test_a_body_gets_a_content_length() raises:
    var framing = _framing("POST", Headers(), Optional[Int](7))
    assert_equal(framing["content-length"], "7")


def test_a_content_length_the_caller_set_is_left_alone() raises:
    var headers = Headers()
    headers.append("Content-Length", "7")
    var framing = _framing("POST", headers^, Optional[Int](7))
    assert_equal(len(framing), 0)


def test_a_content_length_that_disagrees_with_the_body_is_refused() raises:
    # The client side of the same desync this library refuses to accept from a
    # server. Sending it would be shipping the bug rather than having it.
    var headers = Headers()
    headers.append("Content-Length", "3")
    var raised = False
    try:
        _ = _framing("POST", headers^, Optional[Int](7))
    except e:
        raised = True
        assert_true(is_local_protocol_error(e))
    assert_true(raised)


def test_setting_both_framing_headers_is_refused() raises:
    var headers = Headers()
    headers.append("Content-Length", "3")
    headers.append("Transfer-Encoding", "chunked")
    var raised = False
    try:
        _ = _framing("POST", headers^, Optional[Int](3))
    except e:
        raised = True
        assert_true(is_local_protocol_error(e))
    assert_true(raised)


def test_a_caller_who_set_chunked_gets_no_content_length_added() raises:
    var headers = Headers()
    headers.append("Transfer-Encoding", "chunked")
    var framing = _framing("POST", headers^, None)
    assert_equal(len(framing), 0)


def test_a_chunk_is_sized_in_lowercase_hex() raises:
    var body = List[UInt8]()
    for _ in range(26):
        body.append(UInt8(ord("x")))
    var out = _text(chunk(Span(body)))
    assert_true(out.startswith("1a\r\n"))
    assert_true(out.endswith("\r\n"))


def test_a_small_chunk_is_sized_in_one_digit() raises:
    assert_equal(_text(chunk("hello".as_bytes())), "5\r\nhello\r\n")


def test_an_empty_chunk_is_not_written_at_all() raises:
    # On the wire it would be indistinguishable from the terminal chunk, so
    # writing one would end the body in the middle of it.
    assert_equal(_text(chunk(Span(List[UInt8]()))), "")


def test_the_terminal_chunk_ends_the_body() raises:
    assert_equal(_text(terminal_chunk(Headers())), "0\r\n\r\n")


def test_the_terminal_chunk_carries_trailers() raises:
    var trailers = Headers()
    trailers.append("X-Sum", "abc")
    assert_equal(_text(terminal_chunk(trailers)), "0\r\nX-Sum: abc\r\n\r\n")


def test_a_newline_in_a_header_value_never_reaches_the_wire() raises:
    # The header injection case. If this ever passes silently the library has
    # handed the caller's server to whoever supplied the value.
    var headers = Headers()
    var raised = False
    try:
        headers.append("X-A", "one\r\nX-Injected: yes")
    except:
        raised = True
    assert_true(raised)


def test_a_newline_in_a_header_name_never_reaches_the_wire() raises:
    var headers = Headers()
    var raised = False
    try:
        headers.append("X-A\r\nX-Injected", "yes")
    except:
        raised = True
    assert_true(raised)


def test_a_newline_in_the_method_never_reaches_the_wire() raises:
    var raised = False
    try:
        _ = Request("GET / HTTP/1.1\r\n", URL("http://example.com/"))
    except e:
        raised = True
        assert_true(is_local_protocol_error(e))
    assert_true(raised)
