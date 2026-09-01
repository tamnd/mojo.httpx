"""Tests for the one line helpers.

`httpx.get(url)` and the eight beside it. Each builds a client, sends one
request and closes the client, so what is tested here is that every argument
survives that trip: the ones describing the request, and the three describing
the connection it goes out on.

The connection arguments are the reason these are not a thinner copy of the
client tests. `verify`, `cert` and `trust_env` configure a client the caller
cannot reach, so a helper that dropped one would send the request against the
wrong trust store and nothing outside the call would be able to tell.

Every test that talks to the server calls `server.stop()` at the end and passes
the server into a helper rather than naming it once. Mojo ends a value's life at
its last use, so a test that stopped mentioning the server halfway through would
shut it down while a request was still in flight.
"""

from std.testing import assert_equal, assert_false, assert_true

import httpx
from httpx._auth import basic_auth
from httpx._config import Timeout
from httpx._models.cookies import Cookies
from httpx._models.headers import Headers
from httpx._models.json import Json
from httpx._models.response import Response
from httpx._models.stream import ByteSource, ByteStream, erase_source
from httpx._models.url import QueryParams
from httpx._stream.config import ClientCert, SSLVerify
from tests.support.loopback import Loopback
from tests.support.testserver import TestServer


def _anything(server: TestServer) -> String:
    return server.url("/anything")


def _echoed(response: Response, field: StringSpan) raises -> String:
    """One quoted top level field out of the echo the test server wrote.

    Read by hand rather than decoded, the same way the client tests do it, and
    the search is over a lowercased copy so a test does not have to know which
    capitalisation the client sent a header under.
    """
    var text = response.text()
    var lowered = text.lower()
    var needle = String('"', String(field).lower(), '": "')
    var at = lowered.find(needle)
    if at < 0:
        return String()
    var start = at + needle.byte_length()
    var end = text.find('"', start)
    if end < 0:
        return String()
    return String(text[byte=start:end])


def _tls_url(listener: Loopback) -> String:
    """An https URL with a listener behind it that never speaks TLS.

    The connect succeeds, because something is listening, and the TLS setup is
    what fails. That is what makes a trust store argument observable without
    running a TLS server: the error names the file that could not be loaded, and
    it is raised before a single handshake byte moves.
    """
    return String("https://127.0.0.1:", listener.port, "/")


# Every verb, and the method it puts on the wire.


def test_every_verb_helper_sends_its_own_method() raises:
    var server = TestServer()
    assert_equal(_echoed(httpx.get(_anything(server)), "method"), "GET")
    assert_equal(_echoed(httpx.post(_anything(server)), "method"), "POST")
    assert_equal(_echoed(httpx.put(_anything(server)), "method"), "PUT")
    assert_equal(_echoed(httpx.patch(_anything(server)), "method"), "PATCH")
    assert_equal(_echoed(httpx.delete(_anything(server)), "method"), "DELETE")
    assert_equal(_echoed(httpx.options(_anything(server)), "method"), "OPTIONS")
    server.stop()


def test_the_head_helper_gets_the_headers_and_no_body() raises:
    var server = TestServer()
    var r = httpx.head(_anything(server))
    assert_equal(r.status_code, 200)
    # A `HEAD` answer carries the headers of the `GET` it stands in for and none
    # of the body, so a helper that read the announced length would hang here
    # rather than return.
    assert_equal(len(r.content()), 0)
    assert_true(r.headers.get("content-type").startswith("application/json"))
    server.stop()


def test_the_request_helper_sends_whatever_method_it_is_given() raises:
    var server = TestServer()
    var r = httpx.request("PUT", _anything(server))
    assert_equal(_echoed(r, "method"), "PUT")
    server.stop()


# The arguments that describe the request.


def test_a_helper_takes_params_headers_and_cookies() raises:
    var server = TestServer()
    var headers = Headers()
    headers["X-Marker"] = "here"
    var cookies = Cookies()
    cookies.set("session", "abc")
    var r = httpx.get(
        _anything(server),
        params=QueryParams().add("q", "mojo"),
        headers=headers^,
        cookies=cookies^,
    )
    var seen = r.text()
    assert_true('"q": ["mojo"]' in seen)
    assert_equal(_echoed(r, "x-marker"), "here")
    assert_equal(_echoed(r, "cookie"), "session=abc")
    server.stop()


def test_a_helper_takes_a_body() raises:
    var server = TestServer()
    var payload = Json.object()
    payload.set("name", "widget")
    var sent = httpx.post(server.url("/echo"), json=payload^)
    assert_equal(sent.text(), '{"name":"widget"}')

    var formed = httpx.put(
        _anything(server), data=QueryParams().add("a", "1").add("b", "2")
    )
    assert_equal(_echoed(formed, "data"), "a=1&b=2")

    var written = httpx.patch(server.url("/echo"), text="plain")
    assert_equal(written.text(), "plain")
    server.stop()


struct _TwoPieces(ByteSource, Movable):
    """A body handed over in two pieces, so it has to go out chunked."""

    var _at: Int

    def __init__(out self):
        self._at = 0

    def read_chunk(mut self) raises -> List[UInt8]:
        var out = List[UInt8]()
        if self._at == 0:
            out.extend("up".as_bytes())
        elif self._at == 1:
            out.extend("load".as_bytes())
        self._at += 1
        return out^

    def close(mut self):
        self._at = 2

    def trailers(self) -> Headers:
        return Headers()


def test_a_helper_takes_a_streaming_body() raises:
    var server = TestServer()
    var r = httpx.request(
        "POST",
        server.url("/post"),
        content_stream=Optional[ByteStream](erase_source(_TwoPieces())),
    )
    var seen = r.text()
    # Chunked rather than length framed, which is the only framing available
    # when the size is unknown at the time the head is written. Seeing it here
    # is how we know the stream went through as a stream rather than being
    # collected first.
    assert_true('"Transfer-Encoding": "chunked"' in seen)
    assert_true('"data": "upload"' in seen)
    server.stop()


def test_a_helper_does_not_follow_a_redirect_unless_asked() raises:
    var server = TestServer()
    var left = httpx.get(server.url("/redirect/1"))
    assert_equal(left.status_code, 302)
    assert_equal(left.history_count(), 0)

    var followed = httpx.get(server.url("/redirect/1"), follow_redirects=True)
    assert_equal(followed.status_code, 200)
    assert_equal(followed.history_count(), 1)
    server.stop()


def test_a_helper_takes_an_auth_scheme() raises:
    var server = TestServer()
    var refused = httpx.get(server.url("/basic-auth/alice/s3cret"))
    assert_equal(refused.status_code, 401)

    var allowed = httpx.get(
        server.url("/basic-auth/alice/s3cret"),
        auth=basic_auth("alice", "s3cret"),
    )
    assert_equal(allowed.status_code, 200)
    server.stop()


def test_a_helper_takes_a_timeout() raises:
    var server = TestServer()
    var raised = False
    try:
        _ = httpx.get(
            server.url("/delay/2"),
            timeout=Timeout.uniform(Optional[Float64](0.25)),
        )
    except e:
        raised = True
        assert_true("Timeout" in String(e))
    assert_true(raised)
    server.stop()


# The arguments that describe the connection.


def test_a_ca_bundle_given_to_a_helper_reaches_the_connection() raises:
    # The reason these three arguments are on the helpers at all. Without them a
    # caller talking to a private CA would have to give up the one line form on
    # their first request.
    var listener = Loopback()
    var raised = False
    try:
        _ = httpx.get(
            _tls_url(listener),
            verify=SSLVerify.from_file(String("/tmp/no-such-bundle-here.pem")),
        )
    except e:
        raised = True
        assert_true("no-such-bundle-here.pem" in String(e))
    assert_true(raised)
    _ = listener^


def test_a_client_certificate_given_to_a_helper_is_loaded() raises:
    var listener = Loopback()
    var raised = False
    try:
        _ = httpx.post(
            _tls_url(listener),
            cert=ClientCert(String("/tmp/no-such-client-cert.pem")),
        )
    except e:
        raised = True
        assert_true("no-such-client-cert.pem" in String(e))
    assert_true(raised)
    _ = listener^


def test_turning_verification_off_from_a_helper_skips_the_trust_store() raises:
    # Not a TLS test. What it pins is that `verify=` is honoured rather than
    # ignored, which shows up as the failure moving off the trust store and onto
    # a listener that never answers a handshake. The timeout is short because
    # that listener never will.
    var listener = Loopback()
    var raised = False
    try:
        _ = httpx.get(
            _tls_url(listener),
            verify=SSLVerify.off(),
            timeout=Timeout.uniform(Optional[Float64](0.5)),
        )
    except e:
        raised = True
        assert_false("certificate" in String(e))
    assert_true(raised)
    _ = listener^


def test_trust_env_is_taken_and_leaves_a_plain_request_alone() raises:
    # What `trust_env` gates is which environment variables the trust store
    # search reads, and that is covered at the config layer in `test_tls.mojo`
    # where it can be checked without a live socket and without a test mutating
    # the environment out from under the rest of the suite. Here it is enough
    # that the argument is accepted and that turning it off does not disturb a
    # request which never builds a TLS context.
    var server = TestServer()
    var r = httpx.get(_anything(server), trust_env=False)
    assert_equal(r.status_code, 200)
    server.stop()
