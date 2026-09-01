"""Tests for the cookie jar once it is wired into a client.

`test_cookies.mojo` covers the storage model and the parser on their own. This
file covers the part a user sees: a cookie a server sets coming back on the next
request, without anybody having written it down in between.

The live half runs against the local server because the interesting cases are
the ones where the jar and the redirect loop have to agree. A cookie set on a
302 and expected at the target is the ordinary shape of a login, and it is the
one that breaks when a client only reads the last response of a chain.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._client import Client
from httpx._models.cookies import Cookies
from httpx._models.headers import Headers
from httpx._models.response import Response
from httpx._models.url import URL

from tests.support.testserver import TestServer


def _get(
    mut client: Client, server: TestServer, path: StringSpan
) raises -> Response:
    """One request to `server`, with the server held alive for the whole call.

    The server is a parameter because Mojo ends a value's life at its last use,
    so building the URL and then sending the request would have shut the server
    down in between.
    """
    return client.get(server.url(path))


def _follow(
    mut client: Client, server: TestServer, path: StringSpan
) raises -> Response:
    return client.get(server.url(path), follow_redirects=True)


# What goes out.


def test_a_cookie_with_no_domain_is_sent_to_any_host() raises:
    var jar = Cookies()
    jar.set("session", "abc")
    assert_equal(jar.header_for(URL("http://example.com/"), 0), "session=abc")
    assert_equal(
        jar.header_for(URL("http://other.example/deep/path"), 0), "session=abc"
    )


def test_a_jar_seeded_before_the_first_request_goes_out_on_it() raises:
    var client = Client()
    client.cookies["session"] = "abc"
    var request = client.build_request("GET", "http://example.com/")
    assert_equal(request.headers["cookie"], "session=abc")


def test_a_per_request_cookie_is_merged_with_the_client_jar() raises:
    var client = Client()
    client.cookies["session"] = "abc"
    var extra = Cookies()
    extra.set("tracking", "off")
    var request = client.build_request(
        "GET", "http://example.com/", cookies=extra^
    )
    var sent = request.headers["cookie"]
    assert_true("session=abc" in sent)
    assert_true("tracking=off" in sent)


def test_a_per_request_cookie_replaces_the_client_one_with_the_same_name() raises:
    var client = Client()
    client.cookies["session"] = "from-the-client"
    var extra = Cookies()
    extra.set("session", "from-the-call")
    var request = client.build_request(
        "GET", "http://example.com/", cookies=extra^
    )
    assert_equal(request.headers["cookie"], "session=from-the-call")


def test_a_per_request_cookie_does_not_stay_in_the_client_jar() raises:
    var client = Client()
    var extra = Cookies()
    extra.set("once", "only")
    var first = client.build_request(
        "GET", "http://example.com/", cookies=extra^
    )
    assert_equal(first.headers["cookie"], "once=only")
    var second = client.build_request("GET", "http://example.com/")
    assert_false("cookie" in second.headers)


def test_a_hand_written_cookie_header_is_left_alone() raises:
    var client = Client()
    client.cookies["session"] = "abc"
    var headers = Headers()
    headers["Cookie"] = "captured=exactly-this"
    var request = client.build_request(
        "GET", "http://example.com/", headers=headers^
    )
    assert_equal(request.headers["cookie"], "captured=exactly-this")


def test_no_cookies_means_no_header_rather_than_an_empty_one() raises:
    var client = Client()
    var request = client.build_request("GET", "http://example.com/")
    assert_false("cookie" in request.headers)


def test_a_cookie_for_another_host_is_not_sent() raises:
    var client = Client()
    client.cookies.set("session", "abc", domain="example.com")
    var request = client.build_request("GET", "http://elsewhere.test/")
    assert_false("cookie" in request.headers)


def test_a_cookie_scoped_to_a_path_is_only_sent_under_it() raises:
    var client = Client()
    client.cookies.set("admin", "yes", domain="example.com", path="/admin")
    var outside = client.build_request("GET", "http://example.com/public")
    assert_false("cookie" in outside.headers)
    var inside = client.build_request("GET", "http://example.com/admin/users")
    assert_equal(inside.headers["cookie"], "admin=yes")


# What comes back.


def test_a_cookie_a_server_sets_lands_in_the_client_jar() raises:
    var server = TestServer()
    var client = Client()
    var response = _follow(client, server, "/cookies/set?session=abc")
    assert_equal(response.status_code, 200)
    assert_equal(client.cookies["session"], "abc")
    server.stop()


def test_a_cookie_set_on_a_redirect_is_sent_to_the_target() raises:
    var server = TestServer()
    var client = Client()
    var response = _follow(client, server, "/cookies/set?session=abc")
    # The target echoes back what it received, so this is the server saying it
    # saw the cookie rather than the client saying it meant to send one.
    assert_true('"session": "abc"' in response.text())
    server.stop()


def test_a_stored_cookie_goes_out_on_the_next_request_unasked() raises:
    var server = TestServer()
    var client = Client()
    var first = _follow(client, server, "/cookies/set?session=abc")
    _ = first
    var second = _get(client, server, "/cookies")
    assert_true('"session": "abc"' in second.text())
    server.stop()


def test_two_cookies_from_one_response_are_both_stored() raises:
    var server = TestServer()
    var client = Client()
    var response = _follow(client, server, "/cookies/set?one=1&two=2")
    _ = response
    assert_equal(client.cookies["one"], "1")
    assert_equal(client.cookies["two"], "2")
    server.stop()


def test_an_expired_set_cookie_deletes_the_stored_one() raises:
    var server = TestServer()
    var client = Client()
    var first = _follow(client, server, "/cookies/set?session=abc")
    _ = first
    assert_equal(client.cookies["session"], "abc")
    var second = _follow(client, server, "/cookies/delete?session")
    assert_false('"session"' in second.text())
    assert_false("session" in client.cookies)
    server.stop()


def test_a_secure_cookie_is_stored_but_withheld_from_a_plain_request() raises:
    var server = TestServer()
    var client = Client()
    var first = _get(
        client, server, "/cookies/set-raw?value=session%3Dabc%3B%20Secure"
    )
    _ = first
    assert_equal(client.cookies["session"], "abc")
    var second = _get(client, server, "/cookies")
    assert_false('"session"' in second.text())
    server.stop()


def test_a_cookie_for_a_domain_the_server_does_not_own_is_refused() raises:
    var server = TestServer()
    var client = Client()
    var response = _get(
        client,
        server,
        "/cookies/set-raw?value=session%3Dabc%3B%20Domain%3Devil.example",
    )
    _ = response
    assert_false("session" in client.cookies)
    server.stop()


def test_a_per_request_cookie_is_not_carried_across_a_redirect() raises:
    var server = TestServer()
    var client = Client()
    var once = Cookies()
    once.set("temporary", "yes")
    var response = client.get(
        server.url("/cookies/set?session=abc"),
        cookies=once^,
        follow_redirects=True,
    )
    # The jar cookie survives the hop and the per request one does not, which is
    # what httpx does: a cookie passed to one call was about that one URL.
    assert_true('"session": "abc"' in response.text())
    assert_false("temporary" in response.text())
    server.stop()


def test_response_cookies_holds_only_what_that_response_set() raises:
    var server = TestServer()
    var client = Client()
    var first = _follow(client, server, "/cookies/set?first=1")
    _ = first
    # Not followed, so this response is the 302 that carries the `Set-Cookie`.
    var second = _get(client, server, "/cookies/set?second=2")
    var only = second.cookies()
    assert_equal(len(only), 1)
    assert_equal(only["second"], "2")
    # The client has both by now, which is the difference being checked here.
    assert_equal(len(client.cookies), 2)
    server.stop()


def test_response_cookies_after_a_followed_redirect_is_the_last_hop_only() raises:
    var server = TestServer()
    var client = Client()
    # The `Set-Cookie` was on the 302 and the response handed back is the 200 at
    # the end of the chain, so this one set nothing. Surprising, and it is what
    # httpx does: `response.cookies` is about one response, and the answer for
    # the whole exchange is `client.cookies`.
    var response = _follow(client, server, "/cookies/set?session=abc")
    assert_equal(len(response.cookies()), 0)
    assert_equal(client.cookies["session"], "abc")
    server.stop()


def test_a_response_that_set_nothing_has_no_cookies() raises:
    var server = TestServer()
    var client = Client()
    var response = _get(client, server, "/cookies")
    assert_equal(len(response.cookies()), 0)
    server.stop()


def test_a_refreshed_cookie_replaces_rather_than_repeats() raises:
    var server = TestServer()
    var client = Client()
    var first = _follow(client, server, "/cookies/set?session=one")
    _ = first
    var second = _follow(client, server, "/cookies/set?session=two")
    _ = second
    assert_equal(len(client.cookies), 1)
    assert_equal(client.cookies["session"], "two")
    server.stop()


def test_a_cookie_value_never_appears_in_anything_the_library_prints() raises:
    comptime secret = "swordfish-in-a-cookie"
    var server = TestServer()
    var client = Client()
    var response = _follow(
        client, server, "/cookies/set?session=" + String(secret)
    )
    var printed = String()
    printed += String(response.request().headers)
    printed += String(response.headers)
    # The 302 is where the `Set-Cookie` was, so the redacting has to hold on a
    # response that is only reachable through the history.
    printed += String(response.history()[0].headers)
    assert_false(secret in printed)
    server.stop()
