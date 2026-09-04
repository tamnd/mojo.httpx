"""Routing a request to a transport by its URL.

Three layers, and they are tested separately because they fail differently. The
pattern parser is checked on its own, since a pattern that parses to something
other than what it says is a mount that silently covers the wrong traffic. The
ordering is checked on its own, since the whole table matches most requests and
the answer is decided by which entry is tried first. Then requests go through a
real client into mock transports, which is the only way to find out that the
routing is consulted on every send rather than once.

The mock transports answer with a status code each, so the assertion is which
number came back, and that reads better than an assertion about a header.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from httpx._aio_client import AsyncClient, gather
from httpx._client import Client
from httpx._io.deadline import Deadlines
from httpx._models.headers import Headers
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._models.url import URL
from httpx._pool.proxy import Proxy
from httpx._transport.aio_base import AnyAsyncTransport, erase_async_transport
from httpx._transport.base import AnyTransport, Transport, erase_transport
from httpx._transport.blocked import async_blocked, blocked
from httpx._transport.mock import MockRouter, Route
from httpx._transport.mounts import Mounts, URLPattern

from tests.support.testproxy import TestProxy
from tests.support.testserver import TestServer


def _answering(status_code: Int) raises -> AnyTransport:
    """A transport that answers everything with `status_code`."""
    var router = MockRouter()
    router.add(Route.any().respond(status_code))
    return erase_transport(router^)


def _async_answering(status_code: Int) raises -> AnyAsyncTransport:
    var router = MockRouter()
    router.add(Route.any().respond(status_code))
    return erase_async_transport(router^)


def _matches(pattern: StringSpan, url: StringSpan) raises -> Bool:
    return URLPattern(pattern).matches(URL(url))


struct _Counter(Transport):
    """A transport that records being closed and answers 204 to everything.

    Written here rather than reached for from `httpx._transport.mock`, because
    counting closes is the only thing it is for and a mock that also counted
    them would be carrying a field for one test.
    """

    var closes: Int

    def __init__(out self):
        self.closes = 0

    def handle_request(
        mut self, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        var recorded = request.copy()
        var response = Response(204)
        response.set_request(recorded^)
        return response^

    def handle_stream(
        mut self, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        return self.handle_request(request^, deadlines)

    def close(mut self):
        self.closes += 1


def test_all_matches_every_scheme_and_host() raises:
    assert_true(_matches("all://", "http://example.com/"))
    assert_true(_matches("all://", "https://other.test:8443/a"))


def test_an_empty_pattern_matches_everything() raises:
    # Not something anybody writes. The environment variable reader builds one
    # when `NO_PROXY` says to bypass everything.
    assert_true(_matches("", "https://example.com/"))


def test_a_scheme_pattern_matches_only_that_scheme() raises:
    assert_true(_matches("http://", "http://example.com/"))
    assert_false(_matches("http://", "https://example.com/"))


def test_a_host_pattern_ignores_the_scheme() raises:
    assert_true(_matches("all://example.com", "http://example.com/"))
    assert_true(_matches("all://example.com", "https://example.com/"))
    assert_false(_matches("all://example.com", "https://other.com/"))


def test_a_host_pattern_does_not_match_a_subdomain() raises:
    assert_false(_matches("all://example.com", "https://www.example.com/"))


def test_a_scheme_and_host_pattern_wants_both() raises:
    assert_true(_matches("https://example.com", "https://example.com/x"))
    assert_false(_matches("https://example.com", "http://example.com/x"))


def test_a_dotted_star_is_subdomains_only() raises:
    assert_true(_matches("all://*.example.com", "https://www.example.com/"))
    assert_true(_matches("all://*.example.com", "https://a.b.example.com/"))
    assert_false(_matches("all://*.example.com", "https://example.com/"))


def test_a_bare_star_includes_the_domain_itself() raises:
    assert_true(_matches("all://*example.com", "https://example.com/"))
    assert_true(_matches("all://*example.com", "https://www.example.com/"))


def test_a_bare_star_still_stops_at_a_label_boundary() raises:
    # The star reads as "this domain or anything under it" rather than as a
    # substring, so a host that merely ends with the same letters is somebody
    # else's and does not match. httpx draws the line in the same place.
    assert_false(_matches("all://*example.com", "https://notexample.com/"))


def test_a_star_host_with_a_port_matches_on_the_port_alone() raises:
    assert_true(_matches("all://*:8080", "http://anything.test:8080/"))
    assert_false(_matches("all://*:8080", "http://anything.test:8081/"))


def test_a_port_pattern_wants_the_port_written_out() raises:
    assert_true(
        _matches("https://example.com:1234", "https://example.com:1234/")
    )
    assert_false(_matches("https://example.com:1234", "https://example.com/"))


def test_a_default_port_in_a_pattern_means_any_port_for_that_scheme() raises:
    """A URL never carries the port its scheme implies, so a pattern that kept
    one would match nothing at all. Somebody spelling out 443 on an https
    pattern means every https request, which is what they get."""
    assert_true(_matches("https://example.com:443", "https://example.com/"))
    assert_true(_matches("https://example.com:443", "https://example.com:443/"))


def test_the_scheme_and_host_are_matched_without_case() raises:
    assert_true(_matches("HTTP://EXAMPLE.COM", "http://example.com/"))


def test_a_bracketed_ipv6_host_matches() raises:
    assert_true(_matches("all://[::1]", "http://[::1]:8080/"))
    assert_false(_matches("all://[::2]", "http://[::1]:8080/"))


def test_an_ipv6_host_without_brackets_is_refused() raises:
    """`::1` would otherwise parse as the host `:` on port 1 and match nothing
    for the rest of the program's life."""
    with assert_raises(contains="needs brackets round it"):
        _ = URLPattern("all://::1")


def test_a_bare_scheme_is_not_a_pattern() raises:
    """The commonest way to get this wrong, and it has to raise rather than
    match nothing, because a mount that never fires looks exactly like a proxy
    that is not working."""
    with assert_raises(contains="try 'http://'"):
        _ = URLPattern("http")


def test_a_pattern_with_a_path_is_refused() raises:
    with assert_raises(contains="has a path on it"):
        _ = URLPattern("http://example.com/api")


def test_a_port_above_the_range_is_refused() raises:
    with assert_raises(contains="above 65535"):
        _ = URLPattern("http://example.com:70000")


def test_a_more_specific_host_is_tried_first() raises:
    var routes = Mounts[AnyTransport]()
    routes.mount("all://", _answering(200))
    routes.mount("all://example.com", _answering(201))
    assert_equal(routes.route_for(URL("http://example.com/")), 0)
    assert_equal(routes.entries[0].pattern.pattern, "all://example.com")


def test_a_pattern_with_a_port_beats_one_with_a_longer_host() raises:
    # Port first, then host length, then scheme length. So a bare port pattern
    # outranks a fully spelled out host, which is worth knowing before writing a
    # table that depends on the other order.
    var routes = Mounts[AnyTransport]()
    routes.mount("all://very.long.example.com", _answering(200))
    routes.mount("all://*:8080", _answering(201))
    assert_equal(routes.entries[0].pattern.pattern, "all://*:8080")


def test_a_longer_scheme_breaks_a_tie_on_the_host() raises:
    var routes = Mounts[AnyTransport]()
    routes.mount("all://example.com", _answering(200))
    routes.mount("https://example.com", _answering(201))
    assert_equal(routes.entries[0].pattern.pattern, "https://example.com")


def test_patterns_that_tie_keep_the_order_they_were_added() raises:
    var routes = Mounts[AnyTransport]()
    routes.mount("http://", _answering(200))
    routes.mount("all://", _answering(201))
    assert_equal(routes.entries[0].pattern.pattern, "http://")


def test_mounting_the_same_pattern_twice_replaces_it() raises:
    var routes = Mounts[AnyTransport]()
    routes.mount("all://example.com", _answering(200))
    routes.mount("all://example.com", _answering(201))
    assert_equal(len(routes), 1)


def test_nothing_matching_routes_to_the_clients_own_transport() raises:
    var routes = Mounts[AnyTransport]()
    routes.mount("all://example.com", _answering(200))
    assert_equal(routes.route_for(URL("http://other.com/")), -1)


def test_a_bypass_routes_to_the_clients_own_transport() raises:
    var routes = Mounts[AnyTransport]()
    routes.mount("all://", _answering(200))
    routes.bypass("all://example.com")
    assert_equal(routes.route_for(URL("http://example.com/")), -1)
    assert_true(routes.route_for(URL("http://other.com/")) >= 0)


def test_a_mounted_transport_answers_and_the_rest_go_to_the_default() raises:
    var routes = Mounts[AnyTransport]()
    routes.mount("all://mocked.test", _answering(201))
    var client = Client(
        transport=Optional[AnyTransport](_answering(200)), mounts=routes^
    )
    assert_equal(client.get("http://mocked.test/").status_code, 201)
    assert_equal(client.get("http://elsewhere.test/").status_code, 200)


def test_every_hop_is_routed_on_its_own_url() raises:
    """A redirect that leaves a mounted host leaves its transport with it. The
    alternative is a request arriving somewhere the routing table says it should
    not, which is the whole failure this mechanism exists to prevent."""
    var moved = MockRouter()
    var location = Headers()
    location["Location"] = "http://elsewhere.test/"
    moved.add(Route.any().respond(302, headers=location^))
    var routes = Mounts[AnyTransport]()
    routes.mount("all://mocked.test", erase_transport(moved^))
    var client = Client(
        transport=Optional[AnyTransport](_answering(200)),
        mounts=routes^,
        follow_redirects=True,
    )
    var response = client.get("http://mocked.test/")
    assert_equal(response.status_code, 200)
    assert_equal(len(response.history()), 1)


def test_a_blocked_mount_refuses_and_names_the_url() raises:
    var routes = Mounts[AnyTransport]()
    routes.mount("http://", blocked())
    var client = Client(
        transport=Optional[AnyTransport](_answering(200)), mounts=routes^
    )
    with assert_raises(contains="blocked by a mount on this client"):
        _ = client.get("http://plaintext.test/things")


def test_a_blocked_mount_leaves_everything_else_alone() raises:
    var routes = Mounts[AnyTransport]()
    routes.mount("http://", blocked())
    var client = Client(
        transport=Optional[AnyTransport](_answering(200)), mounts=routes^
    )
    assert_equal(client.get("https://encrypted.test/").status_code, 200)


def test_a_blocked_mount_can_say_why() raises:
    var routes = Mounts[AnyTransport]()
    routes.mount(
        "all://internal.test", blocked("that host is not ours to call")
    )
    var client = Client(
        transport=Optional[AnyTransport](_answering(200)), mounts=routes^
    )
    with assert_raises(contains="that host is not ours to call"):
        _ = client.get("http://internal.test/")


def test_a_blocked_mount_refuses_a_stream_as_well() raises:
    var routes = Mounts[AnyTransport]()
    routes.mount("http://", blocked())
    var client = Client(
        transport=Optional[AnyTransport](_answering(200)), mounts=routes^
    )
    with assert_raises(contains="was not sent"):
        with client.stream("GET", "http://plaintext.test/") as response:
            pass


def test_closing_the_client_closes_every_mounted_transport() raises:
    var mounted = erase_transport(_Counter())
    var watching = mounted.copy()
    var routes = Mounts[AnyTransport]()
    routes.mount("all://counted.test", mounted^)
    var client = Client(
        transport=Optional[AnyTransport](_answering(200)), mounts=routes^
    )
    assert_equal(watching.state[_Counter]().closes, 0)
    client.close()
    assert_equal(watching.state[_Counter]().closes, 1)


def test_a_mount_overrides_the_proxy_because_the_proxy_is_a_mount() raises:
    var routes = Mounts[AnyTransport]()
    routes.mount("all://", _answering(201))
    var client = Client(
        proxy=Optional[Proxy](Proxy("http://proxy.invalid:3128")),
        mounts=routes^,
    )
    # A request would go to the proxy if the proxy mount had survived, and
    # `proxy.invalid` does not resolve, so an answer at all is the assertion.
    assert_equal(client.get("http://anywhere.test/").status_code, 201)


def _get(
    mut client: Client, proxy: TestProxy, server: TestServer, path: StringSpan
) raises -> Response:
    """One request, with both processes borrowed so they outlive the call.

    Mojo ends a value's life at its last use, so a server built and then used
    inline inside the call is torn down before the request goes out.
    """
    return client.get(server.url(path))


def test_a_bypass_takes_one_host_back_out_of_the_proxy() raises:
    """The proxy stamps `X-Proxy-Target` on everything it forwards, so its
    absence is the proof that the request went straight to the server. This is
    the test that says `proxy=` really is a mount underneath: there would be
    nothing for a bypass to fall back to otherwise."""
    var server = TestServer()
    var proxy = TestProxy()
    var routes = Mounts[AnyTransport]()
    routes.bypass(String("all://", server.host))
    var client = Client(
        proxy=Optional[Proxy](Proxy(proxy.url())), mounts=routes^
    )
    var response = _get(client, proxy, server, "/headers")
    assert_equal(response.status_code, 200)
    assert_false("x-proxy-target" in response.headers)
    server.stop()
    proxy.stop()


def test_without_the_bypass_the_same_request_goes_through_the_proxy() raises:
    var server = TestServer()
    var proxy = TestProxy()
    var client = Client(proxy=Optional[Proxy](Proxy(proxy.url())))
    var response = _get(client, proxy, server, "/headers")
    assert_equal(response.status_code, 200)
    assert_true("x-proxy-target" in response.headers)
    server.stop()
    proxy.stop()


def test_the_async_client_routes_by_mount_too() raises:
    var routes = Mounts[AnyAsyncTransport]()
    routes.mount("all://mocked.test", _async_answering(201))
    var client = AsyncClient(
        transport=Optional[AnyAsyncTransport](_async_answering(200)),
        mounts=routes^,
    )
    assert_equal(client.get("http://mocked.test/").status_code, 201)
    assert_equal(client.get("http://elsewhere.test/").status_code, 200)


def test_a_gathered_batch_is_split_by_the_transport_each_request_routes_to() raises:
    """A batch is one call into one transport, so a round that spans mounts is
    sent as one batch per transport. The answers still come back in the order
    the requests went in, which is the promise `gather` makes and the one thing
    the splitting could have broken."""
    var routes = Mounts[AnyAsyncTransport]()
    routes.mount("all://mocked.test", _async_answering(201))
    var client = AsyncClient(
        transport=Optional[AnyAsyncTransport](_async_answering(200)),
        mounts=routes^,
    )
    var pending = List[Request]()
    pending.append(client.build_request("GET", "http://elsewhere.test/one"))
    pending.append(client.build_request("GET", "http://mocked.test/two"))
    pending.append(client.build_request("GET", "http://elsewhere.test/three"))
    pending.append(client.build_request("GET", "http://mocked.test/four"))
    var answers = gather(client, pending^)
    assert_equal(len(answers), 4)
    assert_equal(answers[0].status_code, 200)
    assert_equal(answers[1].status_code, 201)
    assert_equal(answers[2].status_code, 200)
    assert_equal(answers[3].status_code, 201)


def test_a_blocked_mount_refuses_a_gathered_request() raises:
    var routes = Mounts[AnyAsyncTransport]()
    routes.mount("all://internal.test", async_blocked())
    var client = AsyncClient(
        transport=Optional[AnyAsyncTransport](_async_answering(200)),
        mounts=routes^,
    )
    var pending = List[Request]()
    pending.append(client.build_request("GET", "http://internal.test/"))
    with assert_raises(contains="was not sent"):
        _ = gather(client, pending^)
