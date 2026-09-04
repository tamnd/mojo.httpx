"""Reading a proxy out of the environment.

Two halves, tested separately because they go wrong in different ways. Turning
four settings into a routing table is pure and is checked directly, since a
`NO_PROXY` entry that becomes the wrong pattern is a host that keeps going
through the proxy while the operator believes it does not. Finding those four
settings is the other half, and it is checked against a real process
environment, because the rules there are about which name wins and an injected
table would not exercise a single one of them.

The CGI check has tests of its own. It is a security control, and a security
control that is only asserted by reading the code is not asserted.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._client import Client
from httpx._ffi.c import setenv, unsetenv
from httpx._models.response import Response
from httpx._pool.proxy import Proxy
from httpx._transport.environ import (
    environment_proxies,
    no_proxy_pattern,
    proxy_routes,
)
from httpx._transport.mock import MockRouter, Route
from httpx._transport.base import AnyTransport, erase_transport

from tests.support.testproxy import TestProxy
from tests.support.testserver import TestServer


def _clear() raises:
    """Put the environment back to one with nothing proxy shaped in it.

    Every test in this file calls this at both ends. The suite runs a shard in
    one process, so a variable left behind is a variable the next test reads.
    """
    unsetenv("http_proxy")
    unsetenv("HTTP_PROXY")
    unsetenv("https_proxy")
    unsetenv("HTTPS_PROXY")
    unsetenv("all_proxy")
    unsetenv("ALL_PROXY")
    unsetenv("no_proxy")
    unsetenv("NO_PROXY")
    unsetenv("REQUEST_METHOD")


def test_nothing_set_is_no_routes() raises:
    var routes = proxy_routes("", "", "", "")
    assert_equal(len(routes), 0)


def test_each_scheme_becomes_its_own_mount() raises:
    var routes = proxy_routes(
        "http://one:3128", "http://two:3128", "http://three:3128", ""
    )
    assert_equal(len(routes), 3)
    assert_equal(routes[0].pattern, "http://")
    assert_equal(routes[1].pattern, "https://")
    assert_equal(routes[2].pattern, "all://")
    assert_equal(String(routes[0].proxy.value().url), "http://one:3128/")


def test_a_proxy_written_without_a_scheme_is_read_as_http() raises:
    """`HTTP_PROXY=squid:3128` is how half the world writes it, and it has
    always meant an HTTP proxy rather than a URL with a missing piece."""
    var routes = proxy_routes("squid:3128", "", "", "")
    assert_equal(String(routes[0].proxy.value().url), "http://squid:3128/")


def test_a_no_proxy_entry_becomes_a_bypass() raises:
    var routes = proxy_routes("http://one:3128", "", "", "example.com")
    assert_equal(len(routes), 2)
    assert_equal(routes[1].pattern, "all://*example.com")
    assert_false(Bool(routes[1].proxy))


def test_a_star_in_no_proxy_turns_the_whole_table_off() raises:
    """Not a bypass on `all://`, which would sit in front of a transport the
    caller mounted themselves. There is simply nothing to route."""
    var routes = proxy_routes("http://one:3128", "http://two:3128", "", "*")
    assert_equal(len(routes), 0)


def test_a_star_anywhere_in_the_list_counts() raises:
    var routes = proxy_routes("http://one:3128", "", "", "example.com, *")
    assert_equal(len(routes), 0)


def test_no_proxy_entries_are_split_and_trimmed() raises:
    var routes = proxy_routes("", "", "", " one.test , two.test ,, ")
    assert_equal(len(routes), 2)
    assert_equal(routes[0].pattern, "all://*one.test")
    assert_equal(routes[1].pattern, "all://*two.test")


def test_a_bare_name_covers_the_name_and_everything_under_it() raises:
    assert_equal(no_proxy_pattern("example.com"), "all://*example.com")


def test_a_leading_dot_covers_the_subdomains_only() raises:
    assert_equal(no_proxy_pattern(".example.com"), "all://*.example.com")


def test_localhost_is_itself_and_nothing_else() raises:
    """The wildcard form would widen it to anything ending in the word, and
    `notlocalhost` is a different machine."""
    assert_equal(no_proxy_pattern("localhost"), "all://localhost")


def test_an_ipv4_address_is_left_alone() raises:
    assert_equal(no_proxy_pattern("10.0.0.1"), "all://10.0.0.1")


def test_an_ipv4_range_keeps_its_prefix() raises:
    assert_equal(no_proxy_pattern("10.0.0.0/8"), "all://10.0.0.0/8")


def test_an_ipv6_address_gets_its_brackets() raises:
    assert_equal(no_proxy_pattern("::1"), "all://[::1]")


def test_an_ipv6_range_is_bracketed_with_the_prefix_outside() raises:
    """The brackets go round the address and not round the whole entry, since
    the pattern is read as a URL authority and `[fd00::/8]` is not one."""
    assert_equal(no_proxy_pattern("fd00::/8"), "all://[fd00::]/8")


def test_an_entry_that_is_already_a_pattern_is_left_as_it_is() raises:
    assert_equal(no_proxy_pattern("https://example.com"), "https://example.com")


def test_an_entry_with_a_port_keeps_it() raises:
    assert_equal(
        no_proxy_pattern("example.com:8080"), "all://*example.com:8080"
    )


def test_the_lower_case_name_is_read() raises:
    _clear()
    setenv("http_proxy", "http://lower:3128")
    var routes = environment_proxies()
    assert_equal(len(routes), 1)
    assert_equal(String(routes[0].proxy.value().url), "http://lower:3128/")
    _clear()


def test_the_upper_case_name_is_read_when_the_other_is_not_set() raises:
    _clear()
    setenv("HTTP_PROXY", "http://upper:3128")
    var routes = environment_proxies()
    assert_equal(String(routes[0].proxy.value().url), "http://upper:3128/")
    _clear()


def test_the_lower_case_name_wins_when_both_are_set() raises:
    """curl's rule. Python's own reader lets whichever spelling comes later in
    the environment block win, which makes the answer depend on the order a
    shell happened to export things in."""
    _clear()
    setenv("http_proxy", "http://lower:3128")
    setenv("HTTP_PROXY", "http://upper:3128")
    var routes = environment_proxies()
    assert_equal(String(routes[0].proxy.value().url), "http://lower:3128/")
    _clear()


def test_an_empty_value_counts_as_unset() raises:
    _clear()
    setenv("http_proxy", "")
    setenv("HTTP_PROXY", "http://upper:3128")
    var routes = environment_proxies()
    assert_equal(String(routes[0].proxy.value().url), "http://upper:3128/")
    _clear()


def test_no_proxy_is_read_from_the_environment_too() raises:
    _clear()
    setenv("HTTPS_PROXY", "http://upper:3128")
    setenv("NO_PROXY", "example.com")
    var routes = environment_proxies()
    assert_equal(len(routes), 2)
    assert_equal(routes[1].pattern, "all://*example.com")
    _clear()


def test_a_cgi_process_ignores_the_upper_case_http_proxy() raises:
    """CVE-2016-5385. A request header called `Proxy` arrives in a CGI process
    as `HTTP_PROXY`, so honouring it hands the routing of a server's own
    outgoing traffic to whoever sent the request."""
    _clear()
    setenv("REQUEST_METHOD", "GET")
    setenv("HTTP_PROXY", "http://attacker:3128")
    var routes = environment_proxies()
    assert_equal(len(routes), 0)
    _clear()


def test_a_cgi_process_still_reads_the_lower_case_http_proxy() raises:
    """No CGI server produces the lower case name, so it cannot have come from
    a request header and there is nothing to defend against."""
    _clear()
    setenv("REQUEST_METHOD", "GET")
    setenv("http_proxy", "http://real:3128")
    var routes = environment_proxies()
    assert_equal(String(routes[0].proxy.value().url), "http://real:3128/")
    _clear()


def test_a_cgi_process_still_reads_the_other_variables() raises:
    """The attack needs a request header whose CGI name is the variable, and
    there is no header that turns into `HTTPS_PROXY` or `ALL_PROXY`."""
    _clear()
    setenv("REQUEST_METHOD", "GET")
    setenv("HTTPS_PROXY", "http://real:3128")
    setenv("ALL_PROXY", "http://other:3128")
    var routes = environment_proxies()
    assert_equal(len(routes), 2)
    _clear()


def _get(
    mut client: Client, proxy: TestProxy, server: TestServer, path: StringSpan
) raises -> Response:
    """One request, with both processes borrowed so they outlive the call."""
    return client.get(server.url(path))


def test_a_client_picks_up_the_proxy_from_the_environment() raises:
    _clear()
    var server = TestServer()
    var proxy = TestProxy()
    setenv("HTTP_PROXY", proxy.url())
    var client = Client()
    var response = _get(client, proxy, server, "/headers")
    assert_equal(response.status_code, 200)
    assert_true("x-proxy-target" in response.headers)
    server.stop()
    proxy.stop()
    _clear()


def test_no_proxy_takes_the_host_back_out() raises:
    _clear()
    var server = TestServer()
    var proxy = TestProxy()
    setenv("HTTP_PROXY", proxy.url())
    setenv("NO_PROXY", server.host)
    var client = Client()
    var response = _get(client, proxy, server, "/headers")
    assert_equal(response.status_code, 200)
    assert_false("x-proxy-target" in response.headers)
    server.stop()
    proxy.stop()
    _clear()


def test_trust_env_off_ignores_the_environment() raises:
    _clear()
    var server = TestServer()
    var proxy = TestProxy()
    setenv("HTTP_PROXY", proxy.url())
    var client = Client(trust_env=False)
    var response = _get(client, proxy, server, "/headers")
    assert_equal(response.status_code, 200)
    assert_false("x-proxy-target" in response.headers)
    server.stop()
    proxy.stop()
    _clear()


def test_a_proxy_named_in_code_wins_over_the_environment() raises:
    """Code that went to the trouble of saying where its traffic goes is not
    overruled by a variable exported for something else."""
    _clear()
    var server = TestServer()
    var proxy = TestProxy()
    setenv("HTTP_PROXY", "http://127.0.0.1:1/")
    var client = Client(proxy=Optional[Proxy](Proxy(proxy.url())))
    var response = _get(client, proxy, server, "/headers")
    assert_equal(response.status_code, 200)
    assert_true("x-proxy-target" in response.headers)
    server.stop()
    proxy.stop()
    _clear()


def test_a_transport_named_in_code_ignores_the_environment() raises:
    """There is no pool left for a proxy to be a property of."""
    _clear()
    setenv("HTTP_PROXY", "http://127.0.0.1:1/")
    var router = MockRouter()
    router.add(Route.any().respond(204))
    var client = Client(
        transport=Optional[AnyTransport](erase_transport(router^))
    )
    var response = client.get("http://example.com/")
    assert_equal(response.status_code, 204)
    _clear()
