"""Tests for `URL` and `QueryParams`.

The reference resolution tables are RFC 3986 section 5.4, both the normal and the
abnormal one, copied as written. They are the reason `join` can be trusted with a
`Location` header, and the abnormal table is the more valuable of the two because
every entry in it is a case where a plausible implementation gets a different
answer than the RFC does.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from httpx._exceptions import is_invalid_url
from httpx._models.url import URL, QueryParams, remove_dot_segments


def test_an_ordinary_url_splits_into_its_parts() raises:
    var u = URL("https://user:secret@example.com:8443/a/b?x=1&y=2#frag")
    assert_equal(u.scheme(), "https")
    assert_equal(u.username(), "user")
    assert_equal(u.password(), "secret")
    assert_equal(String(u.host()), "example.com")
    assert_equal(Int(u.port().value()), 8443)
    assert_equal(u.path(), "/a/b")
    assert_equal(u.fragment(), "frag")
    assert_true(u.is_absolute_url())
    assert_true(u.is_ssl())


def test_the_scheme_is_lowercased() raises:
    assert_equal(URL("HTTPS://example.com/").scheme(), "https")
    assert_equal(String(URL("HtTp://example.com/")), "http://example.com/")


def test_the_host_is_lowercased() raises:
    assert_equal(String(URL("https://EXAMPLE.com/").host()), "example.com")


def test_a_colon_that_is_not_a_scheme_is_not_read_as_one() raises:
    # A scheme has to start with a letter and run to a colon with nothing else
    # in between. Without that rule a path containing a colon becomes a scheme.
    var u = URL("/a:b/c")
    assert_equal(u.scheme(), "")
    assert_equal(u.path(), "/a:b/c")
    assert_true(u.is_relative_url())


def test_the_default_port_is_dropped() raises:
    # Two spellings of one origin would give the pool two entries and double
    # every connection to the server.
    assert_equal(
        String(URL("https://example.com:443/")), "https://example.com/"
    )
    assert_equal(String(URL("http://example.com:80/")), "http://example.com/")
    assert_false(Bool(URL("https://example.com:443/").port()))
    # A non default port stays, and is still the port to connect to.
    assert_equal(Int(URL("https://example.com:8443/").port().value()), 8443)


def test_the_effective_port_fills_the_default_back_in() raises:
    assert_equal(Int(URL("https://example.com/").effective_port().value()), 443)
    assert_equal(Int(URL("http://example.com/").effective_port().value()), 80)
    assert_equal(
        Int(URL("https://example.com:8443/").effective_port().value()), 8443
    )


def test_an_absolute_url_with_no_path_addresses_the_root() raises:
    assert_equal(String(URL("https://example.com")), "https://example.com/")
    assert_equal(URL("https://example.com").path(), "/")


def test_the_request_target_is_path_and_query() raises:
    assert_equal(URL("https://example.com/a/b?x=1").raw_path(), "/a/b?x=1")
    assert_equal(URL("https://example.com/a/b").raw_path(), "/a/b")
    # A request line with an empty target is malformed, so this cannot be empty.
    assert_equal(URL("https://example.com").raw_path(), "/")
    # The fragment never goes on the wire.
    assert_equal(URL("https://example.com/a#f").raw_path(), "/a")


def test_a_port_that_is_not_a_port_is_rejected() raises:
    for text in [
        "https://example.com:99999/",
        "https://example.com:http/",
        "https://example.com:8o80/",
        "https://example.com:-1/",
    ]:
        with assert_raises():
            _ = URL(text)


def test_an_empty_port_means_the_default() raises:
    # Legal, and it means the same as writing no port at all.
    assert_equal(String(URL("https://example.com:/")), "https://example.com/")


def test_the_userinfo_splits_at_the_last_at_sign() raises:
    # Splitting at the first would let an unescaped `@` in the userinfo name a
    # different host than the one the rest of the string spells out, which is
    # the entire mechanism behind a credential phishing URL.
    var u = URL("https://user@evil.example@real.example/")
    assert_equal(String(u.host()), "real.example")
    assert_equal(u.username(), "user@evil.example")


def test_a_colon_in_a_password_is_escaped_on_the_way_back_out() raises:
    var u = URL("https://example.com/").copy_with(
        username="user", password="pa:ss"
    )
    assert_equal(u.username(), "user")
    assert_equal(u.password(), "pa:ss")
    # Re-parsing has to give the same answer, which it only can if the colon was
    # escaped rather than written through.
    assert_equal(URL(String(u)).password(), "pa:ss")


def test_an_ipv6_literal_keeps_its_brackets_and_its_colons() raises:
    var u = URL("https://[2001:db8::1]:8443/x")
    assert_equal(String(u.host()), "[2001:db8::1]")
    assert_equal(Int(u.port().value()), 8443)
    assert_equal(u.netloc(), "[2001:db8::1]:8443")
    # No port, so the last colon inside the brackets must not be read as one.
    assert_false(Bool(URL("https://[::1]/").port()))


def test_an_unclosed_bracket_is_rejected() raises:
    with assert_raises():
        _ = URL("https://[2001:db8::1/x")


def test_a_unicode_host_is_stored_as_a_labels() raises:
    # This is the distinction the whole host handling exists for. What goes on
    # the wire is ASCII; what is shown to a person is not.
    var u = URL("https://ドメイン.テスト/x")
    assert_equal(String(u), "https://xn--eckwd4c7c.xn--zckzah/x")
    assert_equal(String(u.host()), "ドメイン.テスト")


def test_dot_segments_are_removed() raises:
    assert_equal(URL("https://example.com/a/b/../c").path(), "/a/c")
    assert_equal(URL("https://example.com/a/./b").path(), "/a/b")
    # This is the one that matters. A reference cannot climb above the root, so
    # the extra `..` is discarded rather than escaping the site.
    assert_equal(
        URL("https://example.com/../../etc/passwd").path(), "/etc/passwd"
    )


def test_the_rfc_dot_segment_examples() raises:
    # RFC 3986 section 5.2.4.
    assert_equal(remove_dot_segments("/a/b/c/./../../g"), "/a/g")
    assert_equal(remove_dot_segments("mid/content=5/../6"), "mid/6")
    assert_equal(remove_dot_segments("/a/b/"), "/a/b/")
    assert_equal(remove_dot_segments("/a/."), "/a/")
    assert_equal(remove_dot_segments("/"), "/")
    assert_equal(remove_dot_segments(""), "")


def test_an_encoded_dot_is_not_a_dot_segment() raises:
    # Dot segments come out before the path is percent normalized, so a `%2E`
    # that decodes to a dot is still a name and not a step upward. Doing it the
    # other way round removes a segment the server would have kept.
    assert_equal(URL("https://example.com/a/%2E%2E/b").path(), "/a/../b")


def test_percent_encoding_is_normalized() raises:
    assert_equal(
        String(URL("https://example.com/%7Euser")), "https://example.com/~user"
    )
    assert_equal(
        String(URL("https://example.com/a%2fb")), "https://example.com/a%2Fb"
    )


def test_normalization_is_idempotent() raises:
    for text in [
        "https://EXAMPLE.com:443/a/../b?x=%7e#f",
        "http://example.com",
        "https://ドメイン.テスト/x",
        "/relative/path?q=1",
        "https://example.com/a%2fb",
    ]:
        var once = URL(text)
        var twice = URL(String(once))
        assert_equal(String(once), String(twice))
        assert_true(once == twice)


def test_equality_is_the_normalized_form() raises:
    assert_true(
        URL("https://example.com:443/a") == URL("https://EXAMPLE.com/a")
    )
    assert_true(
        URL("https://example.com/%7Ex") == URL("https://example.com/~x")
    )
    assert_false(URL("https://example.com/a") == URL("https://example.com/b"))
    assert_true(URL("https://example.com/a") != URL("http://example.com/a"))


def test_rfc3986_normal_reference_resolution() raises:
    # Section 5.4.1, base http://a/b/c/d;p?q
    var base = URL("http://a/b/c/d;p?q")
    var cases = [
        ("g:h", "g:h"),
        ("g", "http://a/b/c/g"),
        ("./g", "http://a/b/c/g"),
        ("g/", "http://a/b/c/g/"),
        ("/g", "http://a/g"),
        ("//g", "http://g/"),
        ("?y", "http://a/b/c/d;p?y"),
        ("g?y", "http://a/b/c/g?y"),
        ("#s", "http://a/b/c/d;p?q#s"),
        ("g#s", "http://a/b/c/g#s"),
        ("g?y#s", "http://a/b/c/g?y#s"),
        (";x", "http://a/b/c/;x"),
        ("g;x", "http://a/b/c/g;x"),
        ("g;x?y#s", "http://a/b/c/g;x?y#s"),
        ("", "http://a/b/c/d;p?q"),
        (".", "http://a/b/c/"),
        ("./", "http://a/b/c/"),
        ("..", "http://a/b/"),
        ("../", "http://a/b/"),
        ("../g", "http://a/b/g"),
        ("../..", "http://a/"),
        ("../../", "http://a/"),
        ("../../g", "http://a/g"),
    ]
    for sample in cases:
        assert_equal(String(base.join(sample[0])), sample[1])


def test_rfc3986_abnormal_reference_resolution() raises:
    # Section 5.4.2. Every one of these is a case where a plausible
    # implementation gives a different answer than the RFC does.
    var base = URL("http://a/b/c/d;p?q")
    var cases = [
        ("../../../g", "http://a/g"),
        ("../../../../g", "http://a/g"),
        ("/./g", "http://a/g"),
        ("/../g", "http://a/g"),
        ("g.", "http://a/b/c/g."),
        (".g", "http://a/b/c/.g"),
        ("g..", "http://a/b/c/g.."),
        ("..g", "http://a/b/c/..g"),
        ("./../g", "http://a/b/g"),
        ("./g/.", "http://a/b/c/g/"),
        ("g/./h", "http://a/b/c/g/h"),
        ("g/../h", "http://a/b/c/h"),
        ("g;x=1/./y", "http://a/b/c/g;x=1/y"),
        ("g;x=1/../y", "http://a/b/c/y"),
        ("g?y/./x", "http://a/b/c/g?y/./x"),
        ("g?y/../x", "http://a/b/c/g?y/../x"),
        ("g#s/./x", "http://a/b/c/g#s/./x"),
        ("g#s/../x", "http://a/b/c/g#s/../x"),
    ]
    for sample in cases:
        assert_equal(String(base.join(sample[0])), sample[1])


def test_joining_can_leave_the_host_only_when_the_reference_says_to() raises:
    var base = URL("https://example.com/a/b")
    # A reference with its own authority replaces everything, which is how a
    # legitimate cross host redirect works.
    assert_equal(
        String(base.join("https://other.example/x")), "https://other.example/x"
    )
    # A reference without one cannot reach another host however many `..` it has.
    assert_equal(String(base.join("../../../../x")), "https://example.com/x")


def test_joining_against_a_relative_base_is_refused() raises:
    # There is no defined answer, and picking one would mean guessing at a host.
    with assert_raises():
        _ = URL("/a/b").join("c")


def test_query_params_parse_and_reserialize() raises:
    var params = QueryParams("a=1&b=2&a=3")
    assert_equal(len(params), 3)
    assert_equal(params["a"], "1")
    assert_equal(params.get("b"), "2")
    assert_equal(len(params.get_list("a")), 2)
    assert_equal(params.encode(), "a=1&b=2&a=3")


def test_a_field_with_no_equals_is_a_key_with_an_empty_value() raises:
    var params = QueryParams("a")
    assert_equal(params["a"], "")
    assert_equal(params.encode(), "a=")


def test_query_params_decode_plus_as_space() raises:
    var params = QueryParams("q=hello+world&r=1%2B1")
    assert_equal(params["q"], "hello world")
    assert_equal(params["r"], "1+1")
    assert_equal(params.encode(), "q=hello+world&r=1%2B1")


def test_a_value_cannot_introduce_a_parameter() raises:
    # The separators in a value are data. If they survived as structure a value
    # could inject a parameter the caller never wrote.
    var params = QueryParams().add("q", "a=1&b=2")
    assert_equal(params.encode(), "q=a%3D1%26b%3D2")
    assert_equal(QueryParams(params.encode())["q"], "a=1&b=2")
    assert_equal(len(QueryParams(params.encode())), 1)


def test_semicolon_is_not_a_separator() raises:
    # It used to be. Reading it as one lets a value containing a semicolon split
    # into two parameters.
    var params = QueryParams("a=1;b=2")
    assert_equal(len(params), 1)
    assert_equal(params["a"], "1;b=2")


def test_query_param_mutators_return_new_values() raises:
    var original = QueryParams("a=1&b=2")
    var added = original.add("a", "3")
    assert_equal(len(original), 2)
    assert_equal(len(added), 3)
    var replaced = original.set("a", "9")
    assert_equal(len(original), 2)
    assert_equal(replaced.encode(), "a=9&b=2")
    var removed = original.remove("a")
    assert_equal(len(original), 2)
    assert_equal(removed.encode(), "b=2")


def test_set_replaces_in_place_rather_than_appending() raises:
    # Parameter order is visible to the server, so moving one is a change nobody
    # asked for.
    assert_equal(QueryParams("a=1&b=2&a=3").set("a", "9").encode(), "a=9&b=2")


def test_merge_is_idempotent() raises:
    var base = QueryParams("a=1&b=2")
    var other = QueryParams("b=9&c=3")
    var once = base.merge(other)
    var twice = once.merge(other)
    assert_equal(once.encode(), twice.encode())
    assert_equal(once.encode(), "a=1&b=9&c=3")


def test_query_param_equality_ignores_order_but_not_multiplicity() raises:
    assert_true(QueryParams("a=1&b=2") == QueryParams("b=2&a=1"))
    # A server reading a repeated parameter can tell these apart, and some act
    # on the difference.
    assert_false(QueryParams("a=1&a=1") == QueryParams("a=1"))
    assert_false(QueryParams("a=1") == QueryParams("a=2"))


def test_items_takes_the_first_value_and_multi_items_takes_all() raises:
    var params = QueryParams("a=1&b=2&a=3")
    assert_equal(len(params.items()), 2)
    assert_equal(len(params.multi_items()), 3)
    assert_equal(len(params.keys()), 2)


def test_missing_key_raises_but_get_does_not() raises:
    var params = QueryParams("a=1")
    assert_equal(params.get("missing", "fallback"), "fallback")
    assert_false("missing" in params)
    with assert_raises():
        _ = params["missing"]


def test_url_params_round_trip_through_the_url() raises:
    var u = URL("https://example.com/s?q=mojo&page=2")
    assert_equal(u.params()["q"], "mojo")
    var next = u.copy_set_param("page", "3")
    assert_equal(next.params()["page"], "3")
    assert_equal(next.params()["q"], "mojo")
    assert_equal(String(u), "https://example.com/s?q=mojo&page=2")


def test_copy_with_changes_only_what_it_is_given() raises:
    var u = URL("https://example.com/a/b?x=1#f")
    assert_equal(
        String(u.copy_with(scheme="http")), "http://example.com/a/b?x=1#f"
    )
    assert_equal(
        String(u.copy_with(host="other.example")),
        "https://other.example/a/b?x=1#f",
    )
    assert_equal(
        String(u.copy_with(raw_path="/c")), "https://example.com/c?x=1#f"
    )
    assert_equal(
        String(u.copy_with(port=8443)), "https://example.com:8443/a/b?x=1#f"
    )


def test_a_malformed_url_reports_an_invalid_url() raises:
    var raised = False
    try:
        _ = URL("https://example.com/%zz")
    except e:
        raised = True
        assert_true(is_invalid_url(e))
    assert_true(raised)


def test_an_empty_url_is_relative_and_serializes_empty() raises:
    var u = URL("")
    assert_equal(String(u), "")
    assert_true(u.is_relative_url())
