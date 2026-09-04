"""Tests for reading the command line.

The parser is the one part of the CLI that can be tested without a process, a
terminal or a server, so it is tested exhaustively here and the parts that need
those are tested where they live. Every flag has a case, in every form it can
be written in, because a flag that silently does nothing is the kind of bug
that survives a release.

The refusals get as much attention as the successes. A command line tool that
guesses at a malformed argument does the wrong thing quietly, and quietly is
the problem, so each thing this parser refuses has a case asserting both that
it refuses and that the message names what was wrong.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from httpx.cli.args import parse


def _line(*words: String) -> List[String]:
    """A command line, written as it would be typed."""
    var out = List[String]()
    for word in words:
        out.append(word)
    return out^


def test_a_bare_url_is_a_get() raises:
    var args = parse(_line("https://example.com"))
    assert_equal(args.url, "https://example.com")
    assert_equal(args.method_or_default(), "GET")
    assert_false(args.has_body())


def test_the_defaults_are_the_documented_ones() raises:
    var args = parse(_line("https://example.com"))
    assert_equal(args.timeout, Float64(5.0))
    assert_true(args.verify)
    assert_true(args.follow_redirects)
    assert_false(args.http2)
    assert_false(args.fail)
    assert_false(args.has_download)
    assert_equal(args.show, "b")


def test_only_the_body_is_printed_by_default() raises:
    var args = parse(_line("https://example.com"))
    assert_true(args.shows_response_body())
    assert_false(args.shows_response_headers())
    assert_false(args.shows_request_headers())
    assert_false(args.shows_request_body())


def test_a_long_flag_takes_the_next_argument() raises:
    var args = parse(_line("--method", "PUT", "https://example.com"))
    assert_equal(args.method, "PUT")
    assert_equal(args.url, "https://example.com")


def test_a_long_flag_takes_a_value_joined_with_an_equals_sign() raises:
    var args = parse(_line("--method=PUT", "https://example.com"))
    assert_equal(args.method, "PUT")


def test_a_joined_value_may_itself_contain_an_equals_sign() raises:
    # Only the first one splits, or every query string handed to --content
    # would be cut in half.
    var args = parse(_line("--content=a=b=c", "https://example.com"))
    assert_equal(args.content, "a=b=c")


def test_a_short_flag_takes_the_next_argument() raises:
    var args = parse(_line("-m", "DELETE", "https://example.com"))
    assert_equal(args.method, "DELETE")


def test_a_short_flag_takes_a_value_written_against_it() raises:
    var args = parse(_line("-mDELETE", "https://example.com"))
    assert_equal(args.method, "DELETE")


def test_short_switches_can_be_piled_up() raises:
    var args = parse(_line("-vv", "https://example.com"))
    assert_equal(args.show, "Hhb")


def test_a_pile_of_short_flags_can_end_in_one_that_takes_a_value() raises:
    var args = parse(_line("-vm", "POST", "https://example.com"))
    assert_equal(args.show, "Hhb")
    assert_equal(args.method, "POST")

    var joined = parse(_line("-vmPOST", "https://example.com"))
    assert_equal(joined.show, "Hhb")
    assert_equal(joined.method, "POST")


def test_the_url_can_come_before_the_flags() raises:
    var args = parse(_line("https://example.com", "-m", "HEAD"))
    assert_equal(args.url, "https://example.com")
    assert_equal(args.method, "HEAD")


def test_two_argument_options_take_a_name_and_a_value() raises:
    var args = parse(
        _line("-h", "Accept", "application/json", "https://example.com")
    )
    assert_equal(len(args.headers), 1)
    assert_equal(args.headers[0].name, "Accept")
    assert_equal(args.headers[0].value, "application/json")


def test_two_argument_options_repeat() raises:
    var args = parse(
        _line(
            "-h",
            "Accept",
            "application/json",
            "--headers",
            "X-Trace",
            "1",
            "https://example.com",
        )
    )
    assert_equal(len(args.headers), 2)
    assert_equal(args.headers[0].name, "Accept")
    assert_equal(args.headers[1].name, "X-Trace")
    assert_equal(args.headers[1].value, "1")


def test_every_two_argument_option_lands_in_its_own_list() raises:
    var args = parse(
        _line(
            "-p",
            "q",
            "mojo",
            "-d",
            "name",
            "value",
            "-f",
            "upload",
            "/tmp/x",
            "-h",
            "Accept",
            "*/*",
            "--cookies",
            "session",
            "abc",
            "https://example.com",
        )
    )
    assert_equal(len(args.params), 1)
    assert_equal(args.params[0].name, "q")
    assert_equal(args.params[0].value, "mojo")
    assert_equal(len(args.form), 1)
    assert_equal(args.form[0].name, "name")
    assert_equal(len(args.files), 1)
    assert_equal(args.files[0].value, "/tmp/x")
    assert_equal(len(args.headers), 1)
    assert_equal(len(args.cookies), 1)
    assert_equal(args.cookies[0].value, "abc")


def test_auth_is_a_username_and_a_password() raises:
    var args = parse(_line("--auth", "tam", "hunter2", "https://example.com"))
    assert_true(args.has_auth)
    assert_equal(args.auth.name, "tam")
    assert_equal(args.auth.value, "hunter2")


def test_a_value_may_start_with_a_dash() raises:
    # Header values, passwords and query parameters all do, and refusing them
    # would be wrong far more often than it would be helpful.
    var args = parse(
        _line("-h", "X-Flag", "-not-a-flag", "https://example.com")
    )
    assert_equal(args.headers[0].name, "X-Flag")
    assert_equal(args.headers[0].value, "-not-a-flag")

    var password = parse(_line("--auth", "tam", "-p4ss", "https://example.com"))
    assert_equal(password.auth.value, "-p4ss")


def test_a_double_dash_ends_the_flags() raises:
    var args = parse(_line("--", "-weird-url"))
    assert_equal(args.url, "-weird-url")


def test_a_lone_dash_is_not_a_flag() raises:
    var args = parse(_line("-"))
    assert_equal(args.url, "-")


def test_the_body_options_are_kept_apart() raises:
    var content = parse(_line("-c", "hello", "https://example.com"))
    assert_true(content.has_content)
    assert_equal(content.content, "hello")
    assert_false(content.has_json)

    var json = parse(_line("-j", '{"a": 1}', "https://example.com"))
    assert_true(json.has_json)
    assert_equal(json.json, '{"a": 1}')
    assert_false(json.has_content)


def test_a_body_makes_the_default_method_post() raises:
    assert_equal(
        parse(_line("-c", "hi", "https://example.com")).method_or_default(),
        "POST",
    )
    assert_equal(
        parse(_line("-j", "{}", "https://example.com")).method_or_default(),
        "POST",
    )
    assert_equal(
        parse(_line("-d", "a", "b", "https://example.com")).method_or_default(),
        "POST",
    )
    assert_equal(
        parse(
            _line("-f", "a", "/tmp/b", "https://example.com")
        ).method_or_default(),
        "POST",
    )


def test_an_explicit_method_wins_over_the_body() raises:
    var args = parse(_line("-m", "PATCH", "-c", "hi", "https://example.com"))
    assert_equal(args.method_or_default(), "PATCH")


def test_the_switches_switch() raises:
    var args = parse(
        _line(
            "--http2",
            "--fail",
            "--no-verify",
            "--no-follow-redirects",
            "https://example.com",
        )
    )
    assert_true(args.http2)
    assert_true(args.fail)
    assert_false(args.verify)
    assert_false(args.follow_redirects)


def test_the_switches_can_be_turned_back_on() raises:
    # Both spellings exist so a script can be explicit rather than relying on
    # a default it would have to look up.
    var args = parse(
        _line("--no-verify", "--verify", "--follow-redirects", "URL")
    )
    assert_true(args.verify)
    assert_true(args.follow_redirects)


def test_the_single_value_options_are_read() raises:
    var args = parse(
        _line(
            "--proxy",
            "http://127.0.0.1:3128",
            "--download",
            "out.bin",
            "--timeout",
            "2.5",
            "https://example.com",
        )
    )
    assert_true(args.has_proxy)
    assert_equal(args.proxy, "http://127.0.0.1:3128")
    assert_true(args.has_download)
    assert_equal(args.download, "out.bin")
    assert_equal(args.timeout, Float64(2.5))


def test_a_timeout_of_zero_is_allowed() raises:
    # Zero is how a caller asks for a non blocking attempt, the same reading
    # the library gives it.
    assert_equal(parse(_line("--timeout", "0", "URL")).timeout, Float64(0.0))


def test_print_asks_for_particular_parts() raises:
    var args = parse(_line("--print", "Hb", "https://example.com"))
    assert_true(args.shows_request_headers())
    assert_false(args.shows_request_body())
    assert_false(args.shows_response_headers())
    assert_true(args.shows_response_body())


def test_verbose_is_the_same_as_asking_for_three_parts() raises:
    var args = parse(_line("-v", "https://example.com"))
    assert_true(args.shows_request_headers())
    assert_true(args.shows_response_headers())
    assert_true(args.shows_response_body())
    assert_false(args.shows_request_body())


def test_the_last_thing_that_says_what_to_print_wins() raises:
    assert_equal(parse(_line("-v", "--print", "b", "URL")).show, "b")
    assert_equal(parse(_line("--print", "b", "-v", "URL")).show, "Hhb")


def test_help_and_version_need_no_url() raises:
    var asked = parse(_line("--help"))
    assert_true(asked.wants_help)
    assert_equal(asked.url, "")

    var version = parse(_line("--version"))
    assert_true(version.wants_version)


def test_help_stops_the_parse_where_it_stands() raises:
    # Somebody who cannot get the command line right is exactly the person
    # asking for the help, and complaining about the rest of the line instead
    # of answering would be unkind.
    var args = parse(_line("--help", "--print", "zzz"))
    assert_true(args.wants_help)


def test_a_line_with_no_url_is_refused() raises:
    with assert_raises(contains="no URL"):
        _ = parse(_line("-m", "GET"))


def test_a_second_url_is_refused() raises:
    with assert_raises(contains="one URL at a time"):
        _ = parse(_line("https://one.example", "https://two.example"))


def test_an_unknown_long_flag_is_named() raises:
    with assert_raises(contains="--colour is not an option"):
        _ = parse(_line("--colour", "https://example.com"))


def test_an_unknown_short_flag_is_named() raises:
    with assert_raises(contains="-z is not an option"):
        _ = parse(_line("-z", "https://example.com"))


def test_an_unknown_flag_inside_a_pile_is_named() raises:
    with assert_raises(contains="-z is not an option"):
        _ = parse(_line("-vz", "https://example.com"))


def test_a_missing_value_is_refused() raises:
    with assert_raises(contains="--method wants a value"):
        _ = parse(_line("https://example.com", "--method"))
    with assert_raises(contains="--method wants a value"):
        _ = parse(_line("https://example.com", "-m"))


def test_a_missing_second_value_is_refused() raises:
    with assert_raises(contains="--headers wants a name and a value"):
        _ = parse(_line("https://example.com", "-h", "Accept"))


def test_a_two_value_option_refuses_a_joined_value() raises:
    # Guessing at a separator would mean inventing one, and a header value can
    # contain whichever one was invented.
    with assert_raises(contains="two separate arguments"):
        _ = parse(_line("--headers=Accept", "https://example.com"))
    with assert_raises(contains="two separate arguments"):
        _ = parse(_line("-hAccept", "https://example.com"))


def test_a_switch_refuses_a_value() raises:
    with assert_raises(contains="--http2 is a switch"):
        _ = parse(_line("--http2=yes", "https://example.com"))


def test_a_timeout_that_is_not_a_number_is_refused() raises:
    with assert_raises(contains="--timeout wants a number"):
        _ = parse(_line("--timeout", "soon", "https://example.com"))
    with assert_raises(contains="--timeout wants a number"):
        _ = parse(_line("--timeout", "", "https://example.com"))


def test_a_timeout_that_is_not_finite_is_refused() raises:
    # Both of these parse as floats, and both would reach the client as a
    # timeout that never expires.
    with assert_raises(contains="--timeout wants a number"):
        _ = parse(_line("--timeout", "inf", "https://example.com"))
    with assert_raises(contains="--timeout wants a number"):
        _ = parse(_line("--timeout", "nan", "https://example.com"))


def test_a_negative_timeout_is_refused() raises:
    with assert_raises(contains="--timeout cannot be negative"):
        _ = parse(_line("--timeout", "-1", "https://example.com"))


def test_a_print_letter_that_means_nothing_is_named() raises:
    with assert_raises(contains="z is not one of them"):
        _ = parse(_line("--print", "hz", "https://example.com"))


def test_print_wants_at_least_one_letter() raises:
    with assert_raises(contains="--print wants at least one"):
        _ = parse(_line("--print", "", "https://example.com"))
