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
from httpx._models.response import Response
from httpx._pool.proxy import Proxy, proxy_basic_auth

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


def test_an_https_target_through_a_proxy_says_what_is_missing() raises:
    """CONNECT tunnelling is the next piece of this milestone. Until it lands the
    honest answer is a message naming it, rather than a connect to the proxy that
    would put the request on the wire in the clear."""
    var proxy = TestProxy()
    var client = _client(proxy)
    with assert_raises(contains="CONNECT tunnel"):
        _ = client.get("https://example.invalid/")
    client.close()
