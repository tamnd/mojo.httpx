"""A request going out through a SOCKS5 proxy.

Three halves, if that is allowed. The encoder is checked byte by byte, because
what goes into a binary handshake cannot be inferred from a passing integration
test and getting a length prefix wrong is the kind of mistake that only shows up
against one particular proxy. The routing is checked on its own, because whether
a SOCKS proxy tunnels an `http://` target is a decision with no sockets in it.
Then the rest go through a real proxy process to a real server.

The interesting one is `test_the_target_name_is_resolved_at_the_proxy`. The name
it asks for does not exist anywhere, and the proxy is told to answer it from a
table, so a request that succeeds is a request whose target name went over the
wire rather than into the local resolver. That is the property the milestone is
about and it is the only one a test can see directly.

Every call that touches the proxy or the server goes through a helper taking both
as parameters. Mojo ends a value's life at its last use, so building the URL
inline and then sending the request tears the processes down first and fails with
a connection refused on a port that existed a moment ago.
"""

from std.testing import assert_equal, assert_raises, assert_true

from httpx._aio_client import AsyncClient
from httpx._client import Client
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._models.url import URL
from httpx._pool.origin import proxy_origin_for
from httpx._pool.proxy import Proxy, route_through
from httpx._proto.h1.writer import TargetForm
from httpx._proto.socks5 import address_bytes, reply_message

from tests.support.testserver import TestServer
from tests.support.testsocks import TestSocks


def _client(socks: TestSocks) raises -> Client:
    return Client(proxy=Optional[Proxy](Proxy(socks.url())))


def _tls_client(socks: TestSocks) raises -> Client:
    """A client that reaches the https test server through `socks`.

    `verify` names the test certificate rather than turning verification off. A
    handshake through a tunnel that is not checked would look the same whether it
    reached the server or stopped at the proxy.
    """
    return Client(
        proxy=Optional[Proxy](Proxy(socks.url())),
        verify=TestServer.tls_verify(),
    )


def _get(
    mut client: Client, socks: TestSocks, server: TestServer, path: StringSpan
) raises -> Response:
    """One request through `socks` to `server`.

    `socks` is borrowed and unused. It is in the signature so that the process
    stays alive for the length of the call, which is the whole point.
    """
    return client.get(server.url(path))


def _get_url(
    mut client: Client, socks: TestSocks, server: TestServer, url: StringSpan
) raises -> Response:
    """The same, for the tests that address the server by a name of their own
    rather than by the address it is listening on."""
    return client.get(url)


def _nibble(value: Int) -> String:
    if value < 10:
        return String(chr(ord("0") + value))
    return String(chr(ord("a") + value - 10))


def _hex(bytes: List[UInt8]) -> String:
    """The bytes as hex, so a failure prints what was wrong rather than that
    two lists differed."""
    var out = String()
    for byte in bytes:
        out += _nibble(Int(byte) >> 4)
        out += _nibble(Int(byte) & 0xF)
    return out^


def test_a_socks_proxy_url_is_accepted() raises:
    var proxy = Proxy("socks5://proxy.example:1080")
    assert_equal(String(proxy.url), "socks5://proxy.example:1080/")
    assert_true(proxy.origin().is_socks())


def test_a_socks_proxy_defaults_to_port_1080() raises:
    """Not in the URL parser's table of scheme defaults, because `socks5://` is
    an address to get somewhere through rather than one a request can be for.
    Filled in where the proxy is turned into something to connect to."""
    var origin = proxy_origin_for(URL("socks5://proxy.example"))
    assert_equal(origin.port, 1080)
    assert_equal(origin.host, "proxy.example")


def test_socks5h_is_the_same_thing_here() raises:
    """The `h` is curl's way of saying the proxy resolves the name. This client
    does that either way, so the spelling is accepted and not acted on."""
    var proxy = Proxy("socks5h://proxy.example:1080")
    assert_true(proxy.origin().is_socks())


def test_socks_credentials_stay_out_of_the_url_and_out_of_the_headers() raises:
    """RFC 1929 carries them as bytes in the handshake, so there is no header
    for them to become. They still come out of the URL, for the reason they do
    for an HTTP proxy: a URL with a password in it ends up in logs."""
    var proxy = Proxy("socks5://tam:hunter2@proxy.example:1080")
    assert_equal(String(proxy.url), "socks5://proxy.example:1080/")
    assert_equal(proxy.username, "tam")
    assert_equal(proxy.password, "hunter2")
    assert_true("Proxy-Authorization" not in proxy.headers)


def test_writing_a_socks_proxy_out_does_not_print_the_password() raises:
    var proxy = Proxy("socks5://tam:hunter2@proxy.example:1080")
    var shown = String(proxy)
    assert_equal(shown, "socks5://proxy.example:1080/")
    assert_true(shown.find("hunter2") < 0)


def test_a_name_goes_over_as_a_name() raises:
    """The whole reason this client sends a name rather than an address.
    Resolving here would work with every proxy there is and would also tell the
    local resolver where the request is going, which is what a SOCKS proxy is
    usually there to prevent."""
    var encoded = address_bytes("example.com")
    assert_equal(Int(encoded[0]), 3)
    assert_equal(Int(encoded[1]), 11)
    assert_equal(String(StringSpan(from_utf8=Span(encoded)[2:])), "example.com")


def test_an_ipv4_literal_goes_over_as_four_bytes() raises:
    """A caller who typed an address had no name to protect, and a proxy given
    the address as a name would only have to turn it back into these bytes."""
    assert_equal(_hex(address_bytes("127.0.0.1")), "017f000001")


def test_an_ipv6_literal_goes_over_as_sixteen_bytes() raises:
    assert_equal(
        _hex(address_bytes("::1")), "04000000000000000000000000000000" + "01"
    )


def test_a_name_too_long_for_one_length_byte_is_refused() raises:
    """The field is length prefixed with a single byte, so a longer name has no
    encoding. Refused here rather than truncated, because a truncated name is a
    request to a different host."""
    var long = String("a") * 256
    with assert_raises(contains="at most 255"):
        _ = address_bytes(long)


def test_an_empty_host_is_refused() raises:
    with assert_raises(contains="is empty"):
        _ = address_bytes("")


def test_a_refusal_code_is_spelled_out() raises:
    """These are the errors a person actually sees, and the difference between
    the proxy not being allowed to reach a host and not being able to is the
    difference between fixing a rule and fixing a network."""
    assert_true("rules do not allow" in reply_message(UInt8(2)))
    assert_true("unreachable" in reply_message(UInt8(4)))


def test_an_unknown_refusal_code_still_says_something() raises:
    assert_true("77" in reply_message(UInt8(77)))


def test_an_http_target_through_socks_still_tunnels() raises:
    """The difference from an HTTP proxy, and the one worth a test with no
    sockets in it. A SOCKS proxy never reads the request, so there is no absolute
    request line to write and no header to add: the hop is a tunnel and the
    request is the one the caller wrote."""
    var proxy = Proxy("socks5://proxy.example:1080")
    var request = Request("GET", URL("http://example.com/thing"))
    var hop = route_through(Optional[Proxy](proxy^), request, TargetForm.ORIGIN)
    assert_equal(String(hop.origin), "http://example.com:80")
    assert_true(hop.form == TargetForm.ORIGIN)
    assert_true(hop.connect_via)
    assert_equal(String(hop.connect_via.value()), "socks5://proxy.example:1080")


def test_an_https_target_through_socks_tunnels_the_same_way() raises:
    var proxy = Proxy("socks5://proxy.example:1080")
    var request = Request("GET", URL("https://example.com/thing"))
    var hop = route_through(Optional[Proxy](proxy^), request, TargetForm.ORIGIN)
    assert_equal(String(hop.origin), "https://example.com:443")
    assert_true(hop.connect_via)


def test_a_socks_hop_puts_nothing_on_the_request() raises:
    """There is nowhere for a header to go. The proxy is finished with before
    the first byte of HTTP leaves, so a `Proxy-Authorization` here would travel
    end to end to a server that has no business seeing it."""
    var proxy = Proxy("socks5://tam:hunter2@proxy.example:1080")
    var request = Request("GET", URL("http://example.com/thing"))
    _ = route_through(Optional[Proxy](proxy^), request, TargetForm.ORIGIN)
    assert_true("Proxy-Authorization" not in request.headers)


def test_a_request_goes_through_the_socks_proxy() raises:
    var server = TestServer()
    var socks = TestSocks()
    var client = _client(socks)
    var response = _get(client, socks, server, "/get")
    assert_equal(response.status_code, 200)
    assert_equal(response.json()["method"].as_string(), "GET")
    client.close()


def test_the_request_that_arrives_is_the_one_that_was_written() raises:
    """Nothing is rewritten on the way through, which is what distinguishes this
    from forwarding. The server sees an ordinary origin form request with a
    `Host` naming itself and no proxy header anywhere."""
    var server = TestServer()
    var socks = TestSocks()
    var client = _client(socks)
    var response = _get(client, socks, server, "/headers")
    var seen = response.json()["headers"]
    assert_equal(seen["Host"].as_string(), server.authority())
    assert_true("Proxy-Authorization" not in seen)
    client.close()


def test_the_target_name_is_resolved_at_the_proxy() raises:
    """The test this milestone row exists for.

    `socks-only.test` resolves nowhere. The proxy is told to answer it from a
    table, so a response at all means the name travelled as a name and was looked
    up on the far side. A client that resolved locally would have failed before
    opening anything.
    """
    var server = TestServer()
    var socks = TestSocks(resolve="socks-only.test=127.0.0.1")
    var client = _client(socks)
    var target = String("http://socks-only.test:", server.port, "/headers")
    var response = _get_url(client, socks, server, target)
    assert_equal(response.status_code, 200)
    var seen = response.json()["headers"]
    assert_equal(
        seen["Host"].as_string(), String("socks-only.test:", server.port)
    )
    client.close()


def test_two_requests_to_one_server_share_a_connection() raises:
    """Everything through SOCKS is a tunnel, so the pool keys these under the
    server. Two requests to the same one still reuse, which is the part that
    matters, and two requests to different servers could not, which is inherent
    to a pipe that reaches one address."""
    var server = TestServer()
    var socks = TestSocks()
    var client = _client(socks)
    var first = _get(client, socks, server, "/get")
    var second = _get(client, socks, server, "/headers")
    assert_equal(first.status_code, 200)
    assert_equal(second.status_code, 200)
    assert_equal(first.headers["x-conn-id"], second.headers["x-conn-id"])
    client.close()


def test_credentials_in_the_socks_url_are_accepted() raises:
    var server = TestServer()
    var socks = TestSocks(auth="tam:hunter2")
    var client = Client(
        proxy=Optional[Proxy](Proxy(socks.url_with("tam", "hunter2")))
    )
    var response = _get(client, socks, server, "/get")
    assert_equal(response.status_code, 200)
    client.close()


def test_the_wrong_password_is_refused_by_name() raises:
    """A failed login has its own status byte in RFC 1929, separate from the
    refusal to reach a destination, and saying which one happened is the
    difference between a typo in a password and a rule on the proxy."""
    var server = TestServer()
    var socks = TestSocks(auth="tam:hunter2")
    var client = Client(
        proxy=Optional[Proxy](Proxy(socks.url_with("tam", "wrong")))
    )
    with assert_raises(contains="rejected the username and password"):
        _ = _get(client, socks, server, "/get")
    client.close()


def test_a_proxy_that_wants_a_login_refuses_an_anonymous_client() raises:
    """With no credentials the greeting does not offer the password method at
    all, so the proxy says no to the greeting rather than to a login. The message
    has to say what is missing, because nothing else in the exchange will."""
    var server = TestServer()
    var socks = TestSocks(auth="tam:hunter2")
    var client = _client(socks)
    with assert_raises(contains="username and password in the proxy URL"):
        _ = _get(client, socks, server, "/get")
    client.close()


def test_a_forbidden_destination_says_which_kind_of_no_it_was() raises:
    var server = TestServer()
    var socks = TestSocks(forbid=server.authority())
    var client = _client(socks)
    with assert_raises(contains="rules do not allow"):
        _ = _get(client, socks, server, "/get")
    client.close()


def test_https_through_socks_reaches_the_server_itself() raises:
    """TLS inside the SOCKS pipe, end to end. A client that does not trust the
    test certificate is checked separately in `test_tls`; here the point is that
    the handshake succeeds against the server's own certificate, which it could
    not if the proxy were terminating it."""
    var server = TestServer(tls=True)
    var socks = TestSocks()
    var client = _tls_client(socks)
    var response = _get(client, socks, server, "/get")
    assert_equal(response.status_code, 200)
    client.close()


def test_a_bound_address_that_is_a_name_leaves_the_socket_clean() raises:
    """The reply's bound address is its only variable length field, so a client
    that skipped it by a fixed amount would leave bytes on the socket. Those
    bytes would be the first thing the TLS handshake read, and the failure would
    be somewhere deep in OpenSSL with nothing in it about a proxy."""
    var server = TestServer(tls=True)
    var socks = TestSocks(bound="domain")
    var client = _tls_client(socks)
    var response = _get(client, socks, server, "/get")
    assert_equal(response.status_code, 200)
    client.close()


def test_a_bound_address_that_is_ipv6_leaves_the_socket_clean() raises:
    var server = TestServer()
    var socks = TestSocks(bound="ipv6")
    var client = _client(socks)
    var response = _get(client, socks, server, "/get")
    assert_equal(response.status_code, 200)
    client.close()


def test_the_async_client_says_it_cannot_do_this_yet() raises:
    """The async pool opens its sockets inside a coroutine and has nowhere to
    put a handshake that has to happen first. Refused loudly, because the
    alternative is connecting straight to the target and sending the request
    without the proxy, which is traffic leaving a network that was told it would
    not."""
    var socks = TestSocks()
    var client = AsyncClient(proxy=Optional[Proxy](Proxy(socks.url())))
    with assert_raises(contains="cannot open a tunnel yet"):
        _ = client.get("http://example.invalid/")
    client.close()
