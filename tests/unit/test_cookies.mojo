"""Tests for cookie parsing, storage and matching.

Grouped the way the failures group. The matching rules are pure functions and
are tested on their own, because a bug in one of them is a cookie sent to the
wrong site and that is worth catching without a jar in the way. The parser is
tested against the awkward inputs rather than the tidy ones, since the tidy ones
work in any implementation. The jar tests are about the decisions that reject a
cookie, which is the part that is a security control.

Every test states a time explicitly. Nothing here reads the clock, so nothing
here can fail at midnight.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from httpx._exceptions import is_cookie_conflict
from httpx._models.cookies import (
    Cookie,
    CookieJar,
    Cookies,
    SameSite,
    default_path,
    domain_matches,
    is_ip_address,
    parse_set_cookie,
    path_matches,
)
from httpx._models.headers import Headers
from httpx._models.url import URL

comptime NOW = 1700000000
"""A fixed instant, some time in November 2023."""


def _parse(header: StringSpan) raises -> Cookie:
    var found = parse_set_cookie(header, "example.com", "/", NOW)
    if not found:
        raise Error("expected a cookie from " + String(header))
    return found.take()


def test_domain_matching_needs_a_dot() raises:
    assert_true(domain_matches("example.com", "example.com"))
    assert_true(domain_matches("www.example.com", "example.com"))
    assert_true(domain_matches("a.b.example.com", "example.com"))
    # The one that catches people. It ends with the domain as a string and is a
    # different site entirely.
    assert_false(domain_matches("notexample.com", "example.com"))
    assert_false(domain_matches("example.com.evil.com", "example.com"))
    assert_false(domain_matches("example.com", "www.example.com"))
    assert_false(domain_matches("example.com", ""))


def test_domain_matching_ignores_case() raises:
    assert_true(domain_matches("WWW.Example.COM", "example.com"))


def test_an_address_only_matches_itself() raises:
    assert_true(is_ip_address("1.2.3.4"))
    assert_true(is_ip_address("::1"))
    assert_true(is_ip_address("2001:db8::1"))
    assert_false(is_ip_address("example.com"))
    assert_false(is_ip_address("1.2.3.4.example.com"))
    # Without the address check this would be true and a response from an
    # address could set a cookie for the fictional domain `3.4`.
    assert_false(domain_matches("1.2.3.4", "3.4"))
    assert_true(domain_matches("1.2.3.4", "1.2.3.4"))


def test_the_default_path_is_the_directory() raises:
    assert_equal(default_path("/a/b"), "/a")
    assert_equal(default_path("/a/b/"), "/a/b")
    assert_equal(default_path("/a"), "/")
    assert_equal(default_path("/"), "/")
    assert_equal(default_path(""), "/")
    assert_equal(default_path("relative"), "/")


def test_path_matching_needs_a_separator() raises:
    assert_true(path_matches("/a/b", "/a/b"))
    assert_true(path_matches("/a/b", "/a"))
    assert_true(path_matches("/a/b", "/"))
    assert_true(path_matches("/a/b", "/a/"))
    # `/foobar` is not under `/foo`, however much it looks like it.
    assert_false(path_matches("/foobar", "/foo"))
    assert_false(path_matches("/a", "/a/b"))
    assert_false(path_matches("/a", ""))


def test_a_pair_with_no_equals_is_not_a_cookie() raises:
    assert_false(Bool(parse_set_cookie("foo", "example.com", "/", NOW)))
    assert_false(Bool(parse_set_cookie("", "example.com", "/", NOW)))
    assert_false(Bool(parse_set_cookie("=bar", "example.com", "/", NOW)))
    assert_false(Bool(parse_set_cookie("  =bar", "example.com", "/", NOW)))


def test_the_name_and_value_are_split_at_the_first_equals() raises:
    var cookie = _parse("foo=bar=baz")
    assert_equal(cookie.name, "foo")
    assert_equal(cookie.value, "bar=baz")


def test_surrounding_whitespace_is_stripped() raises:
    var cookie = _parse("  foo  =  bar  ; Path=/x")
    assert_equal(cookie.name, "foo")
    assert_equal(cookie.value, "bar")
    assert_equal(cookie.path, "/x")


def test_quotes_stay_part_of_the_value() raises:
    # RFC 6265 does not give quotes any meaning, so stripping them would change
    # the value the server gets back. Browsers keep them and so do we.
    assert_equal(_parse('foo="bar"').value, '"bar"')
    assert_equal(_parse('foo="bar').value, '"bar')


def test_an_unknown_attribute_is_ignored_rather_than_fatal() raises:
    var cookie = _parse("foo=bar; Nonsense=1; Path=/x; AlsoNonsense")
    assert_equal(cookie.value, "bar")
    assert_equal(cookie.path, "/x")


def test_an_unusable_attribute_only_loses_itself() raises:
    # A relative path is not a usable Path attribute, so the cookie keeps the
    # default path instead of being thrown away.
    var found = parse_set_cookie(
        "foo=bar; Path=relative", "example.com", "/a/b", NOW
    )
    assert_equal(found.value().path, "/a")
    # Same for a Max-Age that is not a number.
    assert_false(Bool(_parse("foo=bar; Max-Age=2.5").expires))
    assert_false(Bool(_parse("foo=bar; Max-Age=").expires))
    # And for a date nothing can read, which leaves a session cookie rather
    # than a cookie that expired the moment it arrived.
    assert_false(Bool(_parse("foo=bar; Expires=never").expires))


def test_attribute_names_are_case_insensitive() raises:
    var cookie = _parse("foo=bar; SECURE; httponly; PaTh=/x; SameSite=STRICT")
    assert_true(cookie.secure)
    assert_true(cookie.http_only)
    assert_equal(cookie.path, "/x")
    assert_true(cookie.same_site == SameSite.STRICT)


def test_same_site_distinguishes_unset_from_none() raises:
    assert_true(_parse("foo=bar").same_site == SameSite.UNSET)
    assert_true(_parse("foo=bar; SameSite=None").same_site == SameSite.NONE)
    assert_true(_parse("foo=bar; SameSite=Lax").same_site == SameSite.LAX)
    # An unrecognised value leaves the attribute unset rather than guessing.
    assert_true(
        _parse("foo=bar; SameSite=Sideways").same_site == SameSite.UNSET
    )


def test_max_age_beats_expires() raises:
    # Both present, and Max-Age wins however they are ordered. It is a duration
    # rather than a date, so it survives a client whose clock is wrong.
    var header = "foo=bar; Expires=Sun, 06 Nov 1994 08:49:37 GMT; Max-Age=60"
    assert_equal(_parse(header).expires.value(), NOW + 60)
    var reversed = "foo=bar; Max-Age=60; Expires=Sun, 06 Nov 1994 08:49:37 GMT"
    assert_equal(_parse(reversed).expires.value(), NOW + 60)


def test_max_age_of_zero_or_less_expires_immediately() raises:
    assert_true(_parse("foo=bar; Max-Age=0").is_expired(NOW))
    assert_true(_parse("foo=bar; Max-Age=-1").is_expired(NOW))


def test_a_cookie_with_no_expiry_is_a_session_cookie() raises:
    var cookie = _parse("foo=bar")
    assert_false(Bool(cookie.expires))
    assert_false(cookie.is_expired(NOW))
    assert_false(cookie.is_expired(NOW + 10000000))


def test_a_leading_dot_on_the_domain_is_dropped() raises:
    # The dot was how the old specification said a cookie covered subdomains.
    # RFC 6265 removed the distinction, so it is stripped and the cookie is
    # simply not host-only.
    var cookie = _parse("foo=bar; Domain=.Example.COM")
    assert_equal(cookie.domain, "example.com")
    assert_false(cookie.host_only)


def test_no_domain_attribute_means_host_only() raises:
    var cookie = _parse("foo=bar")
    assert_equal(cookie.domain, "example.com")
    assert_true(cookie.host_only)
    # Host-only really means only. A subdomain does not get it.
    assert_false(cookie.matches("www.example.com", "/", False))
    assert_true(cookie.matches("example.com", "/", False))


def test_a_domain_cookie_covers_subdomains() raises:
    var cookie = _parse("foo=bar; Domain=example.com")
    assert_false(cookie.host_only)
    assert_true(cookie.matches("www.example.com", "/", False))
    assert_true(cookie.matches("example.com", "/", False))
    assert_false(cookie.matches("notexample.com", "/", False))


def test_a_secure_cookie_is_withheld_over_plain_http() raises:
    var cookie = _parse("foo=bar; Secure")
    assert_true(cookie.matches("example.com", "/", True))
    assert_false(cookie.matches("example.com", "/", False))


def test_a_cookie_cannot_be_scoped_to_a_public_suffix() raises:
    # The reason the Public Suffix List is embedded at all. Without this a page
    # on any site under `.com` could set a cookie every other site under `.com`
    # would send back.
    var jar = CookieJar()
    var url = URL("http://www.example.com/")
    assert_false(jar.set_cookie(url, "foo=bar; Domain=com", NOW))
    assert_false(jar.set_cookie(url, "foo=bar; Domain=co.uk", NOW))
    assert_equal(len(jar), 0)


def test_a_site_at_a_public_suffix_can_still_set_its_own_cookie() raises:
    # Some sites really do sit at a public suffix. The rule is about scoping a
    # cookie wider than yourself, not about where you are.
    var jar = CookieJar()
    var url = URL("http://com/")
    assert_true(jar.set_cookie(url, "foo=bar; Domain=com", NOW))


def test_a_cookie_cannot_be_scoped_to_someone_else() raises:
    var jar = CookieJar()
    var url = URL("http://evil.com/")
    assert_false(jar.set_cookie(url, "session=stolen; Domain=bank.com", NOW))
    # Nor to a subdomain the responder is not part of.
    assert_false(jar.set_cookie(url, "session=x; Domain=www.evil.com", NOW))
    assert_equal(len(jar), 0)


def test_a_cookie_that_arrives_expired_deletes_the_stored_one() raises:
    # How every server deletes a cookie. Storing it and cleaning up later would
    # leave the old value in the jar until something happened to look.
    var jar = CookieJar()
    var url = URL("http://example.com/")
    assert_true(jar.set_cookie(url, "foo=bar", NOW))
    assert_equal(len(jar), 1)
    assert_false(jar.set_cookie(url, "foo=; Max-Age=0", NOW))
    assert_equal(len(jar), 0)


def test_storing_the_same_cookie_again_replaces_it() raises:
    var jar = CookieJar()
    var url = URL("http://example.com/")
    _ = jar.set_cookie(url, "foo=one", NOW)
    _ = jar.set_cookie(url, "foo=two", NOW + 5)
    assert_equal(len(jar), 1)
    assert_equal(jar.header_for(url, NOW + 10), "foo=two")


def test_an_update_keeps_the_original_creation_time() raises:
    # Creation time breaks ties in send order, so a server refreshing a cookie
    # on every response would otherwise keep moving it down the header.
    var jar = CookieJar()
    var url = URL("http://example.com/")
    _ = jar.set_cookie(url, "first=1", NOW)
    _ = jar.set_cookie(url, "second=2", NOW + 1)
    _ = jar.set_cookie(url, "first=updated", NOW + 2)
    assert_equal(jar.header_for(url, NOW + 3), "first=updated; second=2")


def test_the_same_name_can_live_under_two_domains() raises:
    var jar = CookieJar()
    _ = jar.set_cookie(URL("http://a.example.com/"), "session=a", NOW)
    _ = jar.set_cookie(URL("http://b.example.com/"), "session=b", NOW)
    assert_equal(len(jar), 2)
    assert_equal(jar.header_for(URL("http://a.example.com/"), NOW), "session=a")
    assert_equal(jar.header_for(URL("http://b.example.com/"), NOW), "session=b")


def test_cookies_are_sent_longest_path_first() raises:
    # RFC 6265 section 5.4. Frameworks hand the application the first value for
    # a repeated name, so this ordering decides what the server sees.
    var jar = CookieJar()
    _ = jar.set_cookie(URL("http://example.com/"), "a=root; Path=/", NOW)
    _ = jar.set_cookie(
        URL("http://example.com/"), "a=deep; Path=/one/two", NOW + 1
    )
    _ = jar.set_cookie(URL("http://example.com/"), "a=mid; Path=/one", NOW + 2)
    assert_equal(
        jar.header_for(URL("http://example.com/one/two/three"), NOW + 3),
        "a=deep; a=mid; a=root",
    )


def test_equal_paths_are_sent_oldest_first() raises:
    var jar = CookieJar()
    var url = URL("http://example.com/")
    _ = jar.set_cookie(url, "b=second", NOW + 1)
    _ = jar.set_cookie(url, "a=first", NOW)
    assert_equal(jar.header_for(url, NOW + 2), "a=first; b=second")


def test_a_cookie_is_not_sent_to_a_path_it_does_not_cover() raises:
    var jar = CookieJar()
    _ = jar.set_cookie(URL("http://example.com/"), "a=1; Path=/admin", NOW)
    assert_equal(jar.header_for(URL("http://example.com/"), NOW), "")
    assert_equal(jar.header_for(URL("http://example.com/admin"), NOW), "a=1")
    assert_equal(jar.header_for(URL("http://example.com/adminx"), NOW), "")


def test_an_expired_cookie_is_not_sent() raises:
    var jar = CookieJar()
    var url = URL("http://example.com/")
    _ = jar.set_cookie(url, "a=1; Max-Age=60", NOW)
    assert_equal(jar.header_for(url, NOW + 30), "a=1")
    assert_equal(jar.header_for(url, NOW + 90), "")


def test_purging_drops_what_has_expired() raises:
    var jar = CookieJar()
    var url = URL("http://example.com/")
    _ = jar.set_cookie(url, "a=1; Max-Age=60", NOW)
    _ = jar.set_cookie(url, "b=2", NOW)
    jar.purge_expired(NOW + 90)
    assert_equal(len(jar), 1)
    assert_equal(jar.header_for(url, NOW + 90), "b=2")


def test_an_empty_header_means_send_no_header() raises:
    # Not the same as sending `Cookie:` with nothing after it, which some
    # servers treat differently.
    var jar = CookieJar()
    assert_equal(jar.header_for(URL("http://example.com/"), NOW), "")


def test_the_default_path_comes_from_the_request() raises:
    var jar = CookieJar()
    _ = jar.set_cookie(URL("http://example.com/a/b"), "foo=bar", NOW)
    assert_equal(jar.header_for(URL("http://example.com/a/c"), NOW), "foo=bar")
    assert_equal(jar.header_for(URL("http://example.com/other"), NOW), "")


def test_a_value_carries_bytes_through_unchanged() raises:
    # Values are octets. A cookie holding UTF-8 has to come back byte for byte,
    # since the server is the only thing that knows what it means.
    var jar = CookieJar()
    var url = URL("http://example.com/")
    _ = jar.set_cookie(url, "name=héllo wörld", NOW)
    assert_equal(jar.header_for(url, NOW), "name=héllo wörld")


def test_cookies_behaves_like_a_dictionary() raises:
    var cookies = Cookies()
    cookies["session"] = "abc"
    assert_equal(cookies["session"], "abc")
    assert_equal(len(cookies), 1)
    assert_true("session" in cookies)
    assert_false("other" in cookies)
    cookies.__delitem__("session")
    assert_equal(len(cookies), 0)


def test_reading_a_missing_cookie_raises_and_get_does_not() raises:
    var cookies = Cookies()
    assert_equal(cookies.get("nope", default="fallback"), "fallback")
    with assert_raises():
        _ = cookies["nope"]
    with assert_raises():
        cookies.__delitem__("nope")


def test_an_ambiguous_name_raises_rather_than_choosing() raises:
    # Two sites, one cookie name. Either answer would be wrong half the time,
    # so the caller is told to say which they meant.
    var cookies = Cookies()
    cookies.set("session", "a", domain="a.example.com")
    cookies.set("session", "b", domain="b.example.com")
    assert_equal(len(cookies), 2)
    var raised = False
    try:
        _ = cookies["session"]
    except e:
        raised = True
        assert_true(is_cookie_conflict(e))
    assert_true(raised)
    # Narrowing the lookup resolves it.
    assert_equal(cookies.get("session", domain="a.example.com"), "a")
    assert_equal(cookies.get("session", domain="b.example.com"), "b")


def test_deleting_by_name_removes_every_copy() raises:
    # Deleting is allowed to be plural where reading is not. A caller asking for
    # a name to be gone means gone.
    var cookies = Cookies()
    cookies.set("session", "a", domain="a.example.com")
    cookies.set("session", "b", domain="b.example.com")
    assert_true(cookies.delete("session"))
    assert_equal(len(cookies), 0)


def test_clearing_can_be_narrowed_to_one_domain() raises:
    var cookies = Cookies()
    cookies.set("one", "1", domain="a.example.com")
    cookies.set("two", "2", domain="b.example.com")
    cookies.clear(domain="a.example.com")
    assert_equal(len(cookies), 1)
    assert_equal(cookies["two"], "2")
    cookies.clear()
    assert_equal(len(cookies), 0)


def test_update_merges_another_set() raises:
    var left = Cookies()
    left.set("a", "1")
    var right = Cookies()
    right.set("a", "overwritten")
    right.set("b", "2")
    left.update(right)
    assert_equal(len(left), 2)
    assert_equal(left["a"], "overwritten")
    assert_equal(left["b"], "2")


def test_cookies_reports_its_contents_in_order() raises:
    var cookies = Cookies()
    cookies.set("a", "1")
    cookies.set("b", "2")
    var keys = cookies.keys()
    assert_equal(len(keys), 2)
    assert_equal(keys[0], "a")
    assert_equal(keys[1], "b")
    var values = cookies.values()
    assert_equal(values[0], "1")
    assert_equal(values[1], "2")
    var items = cookies.items()
    assert_equal(items[0][0], "a")
    assert_equal(items[1][1], "2")


def test_printing_a_cookie_does_not_print_its_value() raises:
    # A session cookie in a log is a session somebody else can use.
    var cookie = _parse("session=supersecret; Domain=example.com; Secure")
    var shown = String(cookie)
    assert_true("supersecret" not in shown)
    assert_true("session=[11 bytes]" in shown)
    assert_true("Secure" in shown)


def test_a_cookie_put_in_by_hand_is_sent_like_a_parsed_one() raises:
    # `store` is the way in for a cookie that was built rather than parsed, and
    # it skips every scoping check, which is why nothing above the jar uses it.
    var jar = CookieJar()
    jar.store(Cookie("a", "1", "example.com", "/", creation=NOW))
    var found = jar.matching(URL("https://example.com/x"), NOW)
    assert_equal(len(found), 1)
    assert_equal(found[0].name, "a")
    assert_equal(found[0].creation, NOW)


def test_matching_leaves_out_what_does_not_belong_on_the_request() raises:
    var jar = CookieJar()
    jar.store(Cookie("here", "1", "example.com", "/", creation=NOW))
    jar.store(Cookie("elsewhere", "2", "other.example", "/", creation=NOW))
    var found = jar.matching(URL("https://example.com/x"), NOW)
    assert_equal(len(found), 1)
    assert_equal(found[0].name, "here")


def test_extract_applies_every_set_cookie_and_counts_what_stuck() raises:
    # The count is what tells a caller something changed, which the size of the
    # jar does not: a refresh of a cookie already there leaves the size alone.
    var jar = CookieJar()
    var headers = Headers()
    headers.append("set-cookie", "a=1")
    headers.append("set-cookie", "b=2")
    headers.append("set-cookie", "c=3; Domain=elsewhere.example")
    var url = URL("https://example.com/")
    assert_equal(jar.extract(url, headers, NOW), 2)
    assert_equal(len(jar.matching(url, NOW)), 2)


def test_extracting_from_a_response_with_no_set_cookie_stores_nothing() raises:
    var jar = CookieJar()
    assert_equal(jar.extract(URL("https://example.com/"), Headers(), NOW), 0)


def test_cookies_extracts_into_the_jar_underneath_it() raises:
    var cookies = Cookies()
    var headers = Headers()
    headers.append("set-cookie", "a=1; Path=/deep")
    var deep = URL("https://example.com/deep/x")
    assert_equal(cookies.extract(deep, headers, NOW), 1)
    assert_equal(cookies["a"], "1")
    # The dictionary on top holds names and values. The jar underneath is what
    # holds the scoping, so it is the one that knows the cookie is not for /.
    assert_equal(len(cookies.jar.matching(deep, NOW)), 1)
    assert_equal(len(cookies.jar.matching(URL("https://example.com/"), NOW)), 0)
