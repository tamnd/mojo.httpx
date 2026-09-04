"""A request going out through a forward proxy.

Two halves. `Proxy` itself is checked directly, because what it does to a URL
with a password in it is a security property and not something to infer from a
passing integration test. Then the rest go through a real proxy process to a real
server, which is the only way to find out that the request line we write is one a
proxy accepts.

The proxy answers with `X-Proxy-Target`, `X-Proxy-Auth` and `X-Proxy-Conn`, and
the server echoes what it was asked, so between the two of them a test can see
the whole hop. `tests/server/proxy.py` explains what each of them means.

Every call that touches the proxy or the server goes through a helper taking both
as parameters. Mojo ends a value's life at its last use, so building the URL
inline and then sending the request tears the processes down first and fails with
a connection refused on a port that existed a moment ago.
"""

from std.testing import assert_equal, assert_raises, assert_true

from httpx._aio_client import AsyncClient
from httpx._client import Client
from httpx._models.headers import Headers
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._models.url import URL
from httpx._pool.proxy import Proxy, proxy_basic_auth, route_through
from httpx._proto.h1.writer import TargetForm

from tests.support.testproxy import TestProxy
from tests.support.testserver import TestServer


def _client(proxy: TestProxy) raises -> Client:
    return Client(proxy=Optional[Proxy](Proxy(proxy.url())))


def _get(
    mut client: Client, proxy: TestProxy, server: TestServer, path: StringSpan
) raises -> Response:
    """One request through `proxy` to `server`.

    `proxy` is borrowed and unused. It is in the signature so that the process
    stays alive for the length of the call, which is the whole point.
    """
    return client.get(server.url(path))


def _post(
    mut client: Client,
    proxy: TestProxy,
    server: TestServer,
    path: StringSpan,
    text: StringSpan,
) raises -> Response:
    return client.post(server.url(path), text=text)


def _aget(
    mut client: AsyncClient,
    proxy: TestProxy,
    server: TestServer,
    path: StringSpan,
) raises -> Response:
    return client.get(server.url(path))


def _tunnel_client(proxy: TestProxy) raises -> Client:
    """A client that reaches the https test server through `proxy`.

    `verify` names the test certificate rather than turning verification off.
    A tunnelled handshake that is not checked would look the same whether it
    reached the server or stopped at the proxy, which is the one thing these
    tests are for.
    """
    return Client(
        proxy=Optional[Proxy](Proxy(proxy.url())),
        verify=TestServer.tls_verify(),
    )


def test_a_proxy_url_keeps_no_credentials() raises:
    """The property this type exists for. A URL with a password in it ends up in
    request lines, in logs and in whatever a user pastes into an issue, so the
    password comes out of the URL and goes into a header."""
    var proxy = Proxy("http://tam:hunter2@proxy.example:3128")
    assert_equal(String(proxy.url), "http://proxy.example:3128/")
    assert_equal(proxy.url.username(), "")
    assert_equal(proxy.url.password(), "")
    assert_equal(
        proxy.headers["Proxy-Authorization"],
        proxy_basic_auth("tam", "hunter2"),
    )


def test_writing_a_proxy_out_does_not_print_the_header() raises:
    """`write_to` is what an error message and a debug print both reach for, and
    either of those carrying a credential is the bug this guards."""
    var proxy = Proxy("http://tam:hunter2@proxy.example:3128")
    var shown = String(proxy)
    assert_equal(shown, "http://proxy.example:3128/")
    assert_true(shown.find("hunter2") < 0)


def test_a_proxy_without_credentials_sets_no_header() raises:
    var proxy = Proxy("http://proxy.example:3128/")
    assert_true("Proxy-Authorization" not in proxy.headers)
    assert_equal(String(proxy.url), "http://proxy.example:3128/")


def test_an_explicit_header_wins_over_the_url() raises:
    """Somebody who wrote the header meant it. Credentials in a URL are usually
    there because an environment variable put them there."""
    var headers = Headers()
    headers["Proxy-Authorization"] = "Bearer opaque"
    var proxy = Proxy("http://tam:hunter2@proxy.example:3128", headers^)
    assert_equal(proxy.headers["Proxy-Authorization"], "Bearer opaque")
    assert_equal(String(proxy.url), "http://proxy.example:3128/")


def test_a_scheme_that_is_not_a_proxy_scheme_is_refused() raises:
    """SOCKS is a later milestone and is not this code path. Accepting the
    scheme and then speaking HTTP at a SOCKS port would fail somewhere much
    further down, with a message about a malformed response."""
    with assert_raises(contains="not a proxy scheme"):
        _ = Proxy("socks5://proxy.example:1080")


def test_a_proxied_request_asks_for_the_whole_url() raises:
    """The request line a proxy needs. `tests/server/proxy.py` refuses an origin
    form target with a 400 rather than guessing, so a 200 here is proof the
    absolute form went out."""
    var server = TestServer()
    var proxy = TestProxy()
    var client = _client(proxy)
    var response = _get(client, proxy, server, "/get")
    assert_equal(response.status_code, 200)
    assert_equal(response.headers["x-proxy-target"], server.url("/get"))
    client.close()


def test_the_body_comes_back_through_the_proxy_unchanged() raises:
    var server = TestServer()
    var proxy = TestProxy()
    var client = _client(proxy)
    var response = _get(client, proxy, server, "/get")
    var body = response.json()
    assert_equal(body["method"].as_string(), "GET")
    client.close()


def test_the_host_header_still_names_the_server() raises:
    """Absolute form in the request line does not mean the `Host` header is the
    proxy. RFC 9112 says the two have to agree about the origin, and a proxy that
    forwarded a `Host` naming itself would produce a request the server routes to
    the wrong virtual host."""
    var server = TestServer()
    var proxy = TestProxy()
    var client = _client(proxy)
    var response = _get(client, proxy, server, "/headers")
    var seen = response.json()["headers"]
    assert_equal(seen["Host"].as_string(), server.authority())
    client.close()


def test_credentials_in_the_proxy_url_go_out_as_a_header() raises:
    var server = TestServer()
    var proxy = TestProxy("tam:hunter2")
    var client = Client(
        proxy=Optional[Proxy](Proxy(proxy.url_with("tam", "hunter2")))
    )
    var response = _get(client, proxy, server, "/get")
    assert_equal(response.status_code, 200)
    assert_equal(
        response.headers["x-proxy-auth"], proxy_basic_auth("tam", "hunter2")
    )
    client.close()


def test_a_proxy_that_wants_credentials_answers_407_without_them() raises:
    """Not an exception. A 407 is a response like any other, and a caller who
    wants it to raise has `raise_for_status`. This is also the check that the
    proxy under the test is really demanding anything."""
    var server = TestServer()
    var proxy = TestProxy("tam:hunter2")
    var client = _client(proxy)
    var response = _get(client, proxy, server, "/get")
    assert_equal(response.status_code, 407)
    assert_true("proxy-authenticate" in response.headers)
    client.close()


def test_the_proxy_credential_does_not_reach_the_server() raises:
    """`Proxy-Authorization` is for the hop in front and is consumed there. A
    client that sent it as `Authorization`, or a proxy that forwarded it, would
    be handing the proxy's password to whatever server the request was aimed
    at."""
    var server = TestServer()
    var proxy = TestProxy("tam:hunter2")
    var client = Client(
        proxy=Optional[Proxy](Proxy(proxy.url_with("tam", "hunter2")))
    )
    var response = _get(client, proxy, server, "/headers")
    var seen = response.json()["headers"]
    assert_true("Proxy-Authorization" not in seen)
    assert_true("Authorization" not in seen)
    client.close()


def test_two_targets_share_one_connection_to_the_proxy() raises:
    """The reason the proxy is a property of the pool rather than of a request.
    Every request through a proxy goes to the same address, so the second one to
    a different server should still find the first one's connection idle."""
    var server = TestServer()
    var proxy = TestProxy()
    var client = _client(proxy)
    var first = _get(client, proxy, server, "/get")
    var second = _get(client, proxy, server, "/headers")
    assert_equal(first.status_code, 200)
    assert_equal(second.status_code, 200)
    assert_equal(first.headers["x-proxy-conn"], second.headers["x-proxy-conn"])
    client.close()


def test_a_post_body_survives_the_extra_hop() raises:
    var server = TestServer()
    var proxy = TestProxy()
    var client = _client(proxy)
    var response = _post(client, proxy, server, "/post", "hello from behind")
    assert_equal(response.json()["data"].as_string(), "hello from behind")
    client.close()


def test_the_async_client_proxies_too() raises:
    """The async pool is `http://` only, which is all forward proxying is, so
    there is no half of this it cannot do. A `proxy=` that the async client
    quietly dropped would be a client sending traffic straight out of a network
    that expects it to go through the proxy, which is the sort of thing nobody
    notices until it is in a firewall log."""
    var server = TestServer()
    var proxy = TestProxy()
    var client = AsyncClient(proxy=Optional[Proxy](Proxy(proxy.url())))
    var response = _aget(client, proxy, server, "/get")
    assert_equal(response.status_code, 200)
    assert_equal(response.headers["x-proxy-target"], server.url("/get"))
    client.close()


def test_the_async_client_sends_the_proxy_credential() raises:
    var server = TestServer()
    var proxy = TestProxy("tam:hunter2")
    var client = AsyncClient(
        proxy=Optional[Proxy](Proxy(proxy.url_with("tam", "hunter2")))
    )
    var response = _aget(client, proxy, server, "/get")
    assert_equal(response.status_code, 200)
    assert_equal(
        response.headers["x-proxy-auth"], proxy_basic_auth("tam", "hunter2")
    )
    client.close()


def test_an_https_target_asks_for_a_tunnel_and_keeps_its_own_origin() raises:
    """The routing decision on its own, with no sockets in it.

    Two things at once, and both matter. The hop says to connect through the
    proxy, and the origin it is keyed under is still the server, because a
    tunnel reaches one host and handing it to a request for another would send
    that request somewhere it never asked to go.
    """
    var proxy = Proxy("http://proxy.example:3128")
    var request = Request("GET", URL("https://example.com/thing"))
    var hop = route_through(Optional[Proxy](proxy^), request, TargetForm.ORIGIN)
    assert_equal(String(hop.origin), "https://example.com:443")
    assert_true(hop.connect_via)
    assert_equal(String(hop.connect_via.value()), "http://proxy.example:3128")
    assert_true(hop.form == TargetForm.ORIGIN)


def test_a_tunnelled_request_does_not_carry_the_proxy_credential() raises:
    """The counterpart of the forwarding case, and the reason `route_through`
    does not call `apply` here. The credential goes on the CONNECT, which the
    pool sends, and a copy of it inside the tunnel would travel end to end to a
    server that has no business seeing the proxy's password."""
    var proxy = Proxy("http://tam:hunter2@proxy.example:3128")
    var request = Request("GET", URL("https://example.com/thing"))
    _ = route_through(Optional[Proxy](proxy^), request, TargetForm.ORIGIN)
    assert_true("Proxy-Authorization" not in request.headers)


def test_an_https_target_goes_through_a_tunnel() raises:
    """End to end, against a real https server behind a real proxy.

    `X-Proxy-Target` is absent on purpose. The proxy adds it to everything it
    forwards and to nothing it tunnels, because once the 200 has gone out it is
    copying bytes it cannot read, so its absence here is the proof that this
    request was tunnelled rather than forwarded.
    """
    var server = TestServer(tls=True)
    var proxy = TestProxy()
    var client = _tunnel_client(proxy)
    var response = _get(client, proxy, server, "/get")
    assert_equal(response.status_code, 200)
    assert_equal(response.json()["method"].as_string(), "GET")
    assert_true("x-proxy-target" not in response.headers)
    client.close()


def test_the_tunnelled_certificate_is_the_servers() raises:
    """A client that does not trust the test certificate cannot get through.

    Which is what says the TLS is end to end. If the proxy were terminating the
    handshake this would fail against the proxy's certificate instead of against
    the server's, and if nothing were being checked it would not fail at all.
    """
    var server = TestServer(tls=True)
    var proxy = TestProxy()
    var client = Client(proxy=Optional[Proxy](Proxy(proxy.url())))
    with assert_raises():
        _ = _get(client, proxy, server, "/get")
    client.close()


def test_a_tunnelled_request_reaches_the_server_without_the_credential() raises:
    """The credential authenticates the CONNECT and stops there.

    The proxy consumes it, and the server on the far end of the tunnel sees a
    request with neither `Proxy-Authorization` nor `Authorization` on it.
    """
    var server = TestServer(tls=True)
    var proxy = TestProxy("tam:hunter2")
    var client = Client(
        proxy=Optional[Proxy](Proxy(proxy.url_with("tam", "hunter2"))),
        verify=TestServer.tls_verify(),
    )
    var response = _get(client, proxy, server, "/headers")
    var seen = response.json()["headers"]
    assert_true("Proxy-Authorization" not in seen)
    assert_true("Authorization" not in seen)
    client.close()


def test_two_tunnelled_requests_share_one_tunnel() raises:
    """A tunnel is a pooled connection like any other.

    Reopening one per request would cost a CONNECT round trip and a full TLS
    handshake every time, which is most of what a connection pool exists to
    avoid. The server's connection id is the only place this is visible, because
    the proxy cannot see inside.
    """
    var server = TestServer(tls=True)
    var proxy = TestProxy()
    var client = _tunnel_client(proxy)
    var first = _get(client, proxy, server, "/headers")
    var second = _get(client, proxy, server, "/get")
    assert_equal(first.status_code, 200)
    assert_equal(second.status_code, 200)
    assert_equal(first.headers["x-conn-id"], second.headers["x-conn-id"])
    client.close()


def test_a_proxy_that_refuses_the_tunnel_names_the_status() raises:
    """A 403 to a CONNECT is a proxy saying it will not reach that destination.

    Worth its own message, because the alternative is a TLS handshake against
    the proxy's plain text error page, which fails somewhere deep in OpenSSL
    with nothing in it about a proxy.
    """
    var server = TestServer(tls=True)
    var proxy = TestProxy(forbid=server.authority())
    var client = _tunnel_client(proxy)
    with assert_raises(contains="403"):
        _ = _get(client, proxy, server, "/get")
    client.close()


def test_a_proxy_that_wants_credentials_refuses_the_tunnel() raises:
    """A 407 to a CONNECT cannot come back as a response the way it can for a
    forwarded request, because there is no tunnel to send a response through.
    So it is an error, and the message says what to do about it."""
    var server = TestServer(tls=True)
    var proxy = TestProxy("tam:hunter2")
    var client = _tunnel_client(proxy)
    with assert_raises(contains="wants credentials"):
        _ = _get(client, proxy, server, "/get")
    client.close()


def test_an_https_proxy_for_an_https_target_says_what_is_missing() raises:
    """TLS inside TLS is the one shape still missing, and it needs a stream that
    can wrap another stream rather than a socket. Said plainly rather than
    attempted, because attempting it would send a CONNECT in the clear to a port
    expecting a handshake."""
    var proxy = TestProxy()
    var client = Client(
        proxy=Optional[Proxy](Proxy(String("https://127.0.0.1:", proxy.port))),
        verify=TestServer.tls_verify(),
    )
    with assert_raises(contains="TLS inside TLS"):
        _ = client.get("https://example.invalid/")
    client.close()
