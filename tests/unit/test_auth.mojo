"""Tests for authentication, from the header bytes up to a live exchange.

Three halves, if that is allowed. The first checks the pieces that are pure
functions over text: the base64 credential, the netrc parser, the challenge
parser. The second drives the schemes against a real server, because what
matters about digest is whether a server that computes the answer with somebody
else's hashlib agrees with what we sent, and no amount of testing our own
arithmetic against itself would show that.

The third is the redaction check. It seeds a password, sends it, and then greps
every string this library will produce for it. That is the test that stops a
future change to a repr or a log line from putting a credential somewhere it
was never meant to go.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._auth import (
    Auth,
    BasicAuth,
    DigestAuth,
    NetRCAuth,
    basic_auth,
    digest_auth,
    erase_auth,
    netrc_auth,
    parse_challenge,
    parse_netrc,
    split_http_list,
)
from httpx._client import Client
from httpx._exceptions import ErrorKind, kind_of, message_of
from httpx._models.headers import Headers
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._models.url import URL

from tests.support.testserver import TestServer


def _get(
    mut client: Client, server: TestServer, path: StringSpan
) raises -> Response:
    """One request to `server`, with the server held alive for the whole call.

    The server is a parameter for the same reason as in the redirect tests:
    Mojo ends a value's life at its last use, so building the URL and then
    making the request would have shut the server down in between.
    """
    return client.get(server.url(path))


def _request(method: StringSpan, url: StringSpan) raises -> Request:
    return Request(method, URL(url))


# The credential itself.


def test_a_basic_header_is_the_base64_of_user_colon_password() raises:
    # The expected value is from RFC 7617's own example, so this is checked
    # against the specification rather than against our own base64.
    var auth = BasicAuth("Aladdin", "open sesame")
    var request = auth.sign(_request("GET", "http://example.com/"))
    assert_equal(
        request.headers["authorization"], "Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ=="
    )


def test_an_empty_password_still_produces_a_header() raises:
    # `user:` with nothing after it is a legal credential and some APIs use it
    # for token style auth, so an empty password must not mean no header.
    var auth = BasicAuth("token", "")
    var request = auth.sign(_request("GET", "http://example.com/"))
    assert_equal(request.headers["authorization"], "Basic dG9rZW46")


def test_a_password_with_a_colon_in_it_survives() raises:
    # Only the first colon separates. A password containing one is legal and a
    # client that split on every colon would silently truncate it.
    var auth = BasicAuth("user", "pa:ss")
    var request = auth.sign(_request("GET", "http://example.com/"))
    assert_equal(request.headers["authorization"], "Basic dXNlcjpwYTpzcw==")


def test_basic_auth_replaces_a_header_that_was_already_there() raises:
    var headers = Headers()
    headers["Authorization"] = "Bearer stale"
    var request = Request("GET", URL("http://example.com/"), headers^)
    var auth = BasicAuth("user", "pass")
    var signed = auth.sign(request^)
    assert_equal(len(signed.headers.get_list("authorization")), 1)
    assert_true(signed.headers["authorization"].startswith("Basic "))


def test_basic_auth_never_asks_for_a_second_round_trip() raises:
    var auth = BasicAuth("user", "pass")
    var response = Response(401)
    assert_false(Bool(auth.next_request(response)))
    assert_false(auth.requires_response_body())


# The header list splitter, which the challenge parser is built on.


def test_a_comma_inside_quotes_does_not_split_a_field() raises:
    # The realm is the field that hits this in practice. Splitting naively
    # gives two fields that both parse and are both wrong.
    var fields = split_http_list('realm="Files, private", nonce="abc"')
    assert_equal(len(fields), 2)
    assert_equal(fields[0], 'realm="Files, private"')
    assert_equal(fields[1], 'nonce="abc"')


def test_an_escaped_quote_does_not_end_a_quoted_string() raises:
    var fields = split_http_list('realm="a\\"b, c", nonce="x"')
    assert_equal(len(fields), 2)
    assert_equal(fields[1], 'nonce="x"')


def test_surrounding_whitespace_is_dropped_from_every_field() raises:
    var fields = split_http_list("  a=1 ,\tb=2  ")
    assert_equal(len(fields), 2)
    assert_equal(fields[0], "a=1")
    assert_equal(fields[1], "b=2")


# The challenge parser.


def test_a_challenge_is_taken_apart_into_its_fields() raises:
    var challenge = parse_challenge(
        'Digest realm="test", nonce="abc", opaque="xyz", algorithm=SHA-256,'
        ' qop="auth"'
    )
    assert_equal(challenge.realm, "test")
    assert_equal(challenge.nonce, "abc")
    assert_equal(challenge.algorithm, "SHA-256")
    assert_equal(challenge.opaque.value(), "xyz")
    assert_equal(challenge.qop.value(), "auth")


def test_a_challenge_without_an_algorithm_means_md5() raises:
    # RFC 7616 says so, and plenty of servers leave the field out entirely.
    var challenge = parse_challenge('Digest realm="test", nonce="abc"')
    assert_equal(challenge.algorithm, "MD5")
    assert_false(Bool(challenge.opaque))
    assert_false(Bool(challenge.qop))


def test_field_names_in_a_challenge_are_case_insensitive() raises:
    var challenge = parse_challenge('Digest Realm="test", NONCE="abc"')
    assert_equal(challenge.realm, "test")
    assert_equal(challenge.nonce, "abc")


def test_a_challenge_with_no_realm_is_refused() raises:
    # Refused here rather than answered, because there is no way to compute a
    # response without it and a header built from a guess would be rejected by
    # the server for reasons the caller could not see.
    var raised = False
    try:
        _ = parse_challenge('Digest nonce="abc"')
    except e:
        raised = True
        assert_true(kind_of(e) == ErrorKind.PROTOCOL_ERROR)
        assert_true("Malformed Digest" in message_of(e))
    assert_true(raised)


def test_a_challenge_with_no_nonce_is_refused() raises:
    var raised = False
    try:
        _ = parse_challenge('Digest realm="test"')
    except e:
        raised = True
        assert_true(kind_of(e) == ErrorKind.PROTOCOL_ERROR)
    assert_true(raised)


# The netrc parser.


def test_a_netrc_entry_is_read_off_three_lines() raises:
    var entries = parse_netrc(
        "machine example.com\n  login alice\n  password s3cret\n"
    )
    assert_equal(len(entries), 1)
    assert_equal(entries[0].machine, "example.com")
    assert_equal(entries[0].login, "alice")
    assert_equal(entries[0].password, "s3cret")


def test_a_netrc_entry_is_read_off_one_line_too() raises:
    # The format is a stream of words rather than lines, so both layouts are
    # correct and a line oriented parser would only handle one of them.
    var entries = parse_netrc("machine example.com login alice password s3cret")
    assert_equal(len(entries), 1)
    assert_equal(entries[0].login, "alice")


def test_a_quoted_netrc_password_can_contain_spaces() raises:
    var entries = parse_netrc(
        'machine example.com login alice password "two words"'
    )
    assert_equal(entries[0].password, "two words")


def test_a_netrc_comment_is_ignored() raises:
    var entries = parse_netrc(
        "# a comment\nmachine example.com login alice password s3cret\n"
    )
    assert_equal(len(entries), 1)
    assert_equal(entries[0].machine, "example.com")


def test_a_macdef_body_is_not_read_as_credentials() raises:
    # The body of an FTP macro is arbitrary text that can contain the word
    # `machine`, and a parser that walked into it would invent an entry.
    var entries = parse_netrc(
        "macdef init\nmachine notreal login nobody\n\nmachine example.com"
        " login alice password s3cret\n"
    )
    assert_equal(len(entries), 1)
    assert_equal(entries[0].machine, "example.com")
    assert_equal(entries[0].login, "alice")


def test_several_netrc_entries_keep_their_order() raises:
    var entries = parse_netrc(
        "machine one.example login a password 1\n"
        "machine two.example login b password 2\n"
    )
    assert_equal(len(entries), 2)
    assert_equal(entries[0].machine, "one.example")
    assert_equal(entries[1].machine, "two.example")


def test_a_netrc_default_entry_has_an_empty_machine() raises:
    var entries = parse_netrc("default login anybody password letmein")
    assert_equal(len(entries), 1)
    assert_equal(entries[0].machine, "")
    assert_equal(entries[0].login, "anybody")


def test_an_account_field_does_not_swallow_the_password() raises:
    # `account` takes an argument. A parser that skipped only the keyword would
    # read its value as the next keyword and lose the password.
    var entries = parse_netrc(
        "machine example.com login alice account billing password s3cret"
    )
    assert_equal(entries[0].password, "s3cret")


# Basic auth against a live server.


def test_basic_auth_authenticates_against_a_real_server() raises:
    var server = TestServer()
    var client = Client(auth=basic_auth("alice", "s3cret"))
    var response = _get(client, server, "/basic-auth/alice/s3cret")
    assert_equal(response.status_code, 200)
    assert_true('"authenticated": true' in response.text())
    client.close()
    server.stop()


def test_the_wrong_password_comes_back_as_a_401() raises:
    # Not raised. A 401 is a response, and turning it into an exception would
    # be this library deciding what the caller meant.
    var server = TestServer()
    var client = Client(auth=basic_auth("alice", "wrong"))
    var response = _get(client, server, "/basic-auth/alice/s3cret")
    assert_equal(response.status_code, 401)
    client.close()
    server.stop()


def test_auth_on_the_request_beats_auth_on_the_client() raises:
    var server = TestServer()
    var client = Client(auth=basic_auth("alice", "wrong"))
    var response = client.get(
        server.url("/basic-auth/alice/s3cret"),
        auth=basic_auth("alice", "s3cret"),
    )
    assert_equal(response.status_code, 200)
    client.close()
    server.stop()


def test_basic_auth_costs_one_round_trip_and_no_history() raises:
    # The credential goes out on the first request, so there is nothing before
    # the answer and `history` is empty. Digest is the one that is not.
    var server = TestServer()
    var client = Client(auth=basic_auth("alice", "s3cret"))
    var response = _get(client, server, "/basic-auth/alice/s3cret")
    assert_equal(response.status_code, 200)
    assert_equal(response.history_count(), 0)
    client.close()
    server.stop()


# Digest auth against a live server. The server checks the arithmetic with
# Python's hashlib, so a passing test means two implementations agree.


def test_digest_auth_answers_a_challenge() raises:
    var server = TestServer()
    var client = Client(auth=digest_auth("alice", "s3cret"))
    var response = _get(client, server, "/digest-auth/auth/alice/s3cret")
    assert_equal(response.status_code, 200)
    assert_true('"authenticated": true' in response.text())
    client.close()
    server.stop()


def test_the_challenge_that_was_answered_is_kept_in_history() raises:
    # The 401 was a real exchange and the caller should be able to see it, the
    # same way they can see a redirect that was followed.
    var server = TestServer()
    var client = Client(auth=digest_auth("alice", "s3cret"))
    var response = _get(client, server, "/digest-auth/auth/alice/s3cret")
    assert_equal(response.status_code, 200)
    assert_equal(response.history_count(), 1)
    var history = response.history()
    assert_equal(history[0].status_code, 401)
    client.close()
    server.stop()


def test_digest_auth_with_the_wrong_password_gives_up_after_one_retry() raises:
    # One retry, not a loop. A server that answers its own challenge with
    # another challenge is rejecting the credentials, and trying again produces
    # the same 401 for as long as anyone is willing to wait.
    var server = TestServer()
    var client = Client(auth=digest_auth("alice", "wrong"))
    var response = _get(client, server, "/digest-auth/auth/alice/s3cret")
    assert_equal(response.status_code, 401)
    assert_equal(response.history_count(), 1)
    client.close()
    server.stop()


def test_digest_auth_works_with_sha_256() raises:
    var server = TestServer()
    var client = Client(auth=digest_auth("alice", "s3cret"))
    var response = _get(
        client, server, "/digest-auth/auth/alice/s3cret/SHA-256"
    )
    assert_equal(response.status_code, 200)
    client.close()
    server.stop()


def test_digest_auth_works_with_sha_512() raises:
    var server = TestServer()
    var client = Client(auth=digest_auth("alice", "s3cret"))
    var response = _get(
        client, server, "/digest-auth/auth/alice/s3cret/SHA-512"
    )
    assert_equal(response.status_code, 200)
    client.close()
    server.stop()


def test_digest_auth_works_with_the_session_variants() raises:
    # `-sess` folds both nonces into HA1, which is a different computation and
    # not merely a different hash.
    var server = TestServer()
    var client = Client(auth=digest_auth("alice", "s3cret"))
    var response = _get(
        client, server, "/digest-auth/auth/alice/s3cret/MD5-SESS"
    )
    assert_equal(response.status_code, 200)
    client.close()
    server.stop()


def test_digest_auth_speaks_the_older_shape_with_no_qop() raises:
    # RFC 2069, which leaves out the client nonce and the counter entirely.
    # Servers that predate RFC 2617 still send this.
    var server = TestServer()
    var client = Client(auth=digest_auth("alice", "s3cret"))
    var response = _get(client, server, "/digest-auth/none/alice/s3cret")
    assert_equal(response.status_code, 200)
    client.close()
    server.stop()


def test_a_cookie_from_the_challenge_is_carried_onto_the_retry() raises:
    # Real digest servers pin the challenge to a session cookie. A client that
    # dropped it would be challenged again with a different nonce and would
    # never converge.
    var server = TestServer()
    var client = Client(auth=digest_auth("alice", "s3cret"))
    var response = _get(client, server, "/digest-auth/auth/alice/s3cret")
    assert_equal(response.status_code, 200)
    assert_true('"digest-session": "opened"' in response.text())
    client.close()
    server.stop()


def test_the_second_request_is_authenticated_straight_away() raises:
    # The challenge is remembered, so only the first request pays for the extra
    # round trip. That is the whole reason the scheme is stateful.
    var server = TestServer()
    var client = Client(auth=digest_auth("alice", "s3cret"))
    var first = _get(client, server, "/digest-auth/auth/alice/s3cret")
    assert_equal(first.status_code, 200)
    assert_equal(first.history_count(), 1)

    var second = _get(client, server, "/digest-auth/auth/alice/s3cret")
    assert_equal(second.status_code, 200)
    assert_equal(second.history_count(), 0)
    client.close()
    server.stop()


def test_a_401_without_a_digest_challenge_is_returned_as_it_is() raises:
    # A server that answers with `Basic` when we are speaking digest is not
    # asking a question this scheme can answer, so the response goes back to
    # the caller rather than being retried.
    var server = TestServer()
    var client = Client(auth=digest_auth("alice", "s3cret"))
    var response = _get(client, server, "/basic-auth/alice/s3cret")
    assert_equal(response.status_code, 401)
    assert_equal(response.history_count(), 0)
    client.close()
    server.stop()


def test_a_non_401_is_never_retried() raises:
    var server = TestServer()
    var client = Client(auth=digest_auth("alice", "s3cret"))
    var response = _get(client, server, "/status/403")
    assert_equal(response.status_code, 403)
    assert_equal(response.history_count(), 0)
    client.close()
    server.stop()


def test_auth_survives_a_redirect_chain() raises:
    # Auth wraps redirects rather than the other way round, so the challenge is
    # answered by starting the chain again rather than by answering an
    # intermediate hop.
    var server = TestServer()
    var client = Client(
        auth=basic_auth("alice", "s3cret"), follow_redirects=True
    )
    var response = client.get(
        server.url(
            String("/redirect-to?url=", server.url("/basic-auth/alice/s3cret"))
        )
    )
    assert_equal(response.status_code, 200)
    assert_true('"authenticated": true' in response.text())
    client.close()
    server.stop()


# netrc, driven off a file rather than off the home directory.


def test_netrc_auth_signs_from_a_file() raises:
    var path = _write_netrc("machine 127.0.0.1 login alice password s3cret\n")
    var server = TestServer()
    var client = Client(auth=netrc_auth(path))
    var response = _get(client, server, "/basic-auth/alice/s3cret")
    assert_equal(response.status_code, 200)
    client.close()
    server.stop()


def test_netrc_auth_leaves_an_unknown_host_alone() raises:
    # No entry means no header, not an empty one. A request that went out with
    # `Authorization:` and nothing after it would be a different request.
    var path = _write_netrc("machine other.example login bob password x\n")
    var auth = NetRCAuth(path)
    var request = auth.sign(_request("GET", "http://example.com/"))
    assert_false("authorization" in request.headers)


def test_a_netrc_default_entry_covers_a_host_with_no_entry() raises:
    var path = _write_netrc(
        "machine other.example login bob password x\n"
        "default login anybody password letmein\n"
    )
    var auth = NetRCAuth(path)
    var request = auth.sign(_request("GET", "http://example.com/"))
    assert_equal(request.headers["authorization"], "Basic YW55Ym9keTpsZXRtZWlu")


def test_a_named_netrc_entry_beats_the_default() raises:
    var path = _write_netrc(
        "default login anybody password letmein\n"
        "machine example.com login alice password s3cret\n"
    )
    var auth = NetRCAuth(path)
    var request = auth.sign(_request("GET", "http://example.com/"))
    assert_equal(request.headers["authorization"], "Basic YWxpY2U6czNjcmV0")


def _write_netrc(text: StringSpan) raises -> String:
    """A `.netrc` in a temporary directory, whose path this returns.

    A real file rather than a string, because the point of `NetRCAuth` over
    `parse_netrc` is that it opens one, and a test that skipped the file would
    not have tested the thing that goes wrong in the field.
    """
    from std.python import Python

    var tempfile = Python.import_module("tempfile")
    var os = Python.import_module("os")
    var directory = String(tempfile.mkdtemp())
    var path = String(os.path.join(directory, ".netrc"))
    with open(path, "w") as handle:
        handle.write(String(text))
    return path^


# Redaction. The one test that is about what must not happen.


def test_a_credential_never_appears_in_anything_the_library_prints() raises:
    # Seeded and then grepped for, rather than checked field by field. A test
    # that listed the places a password must not appear would go stale the
    # moment somebody added a new one, and this one does not.
    comptime secret = "hunter2correcthorse"
    var server = TestServer()
    var client = Client(auth=basic_auth("alice", secret))
    var response = _get(client, server, "/basic-auth/alice/wrong")
    assert_equal(response.status_code, 401)

    var printed = String()
    printed += String(response)
    printed += String(response.request())
    printed += String(response.request().headers)
    printed += String(response.headers)
    printed += String(response.request().url)
    assert_false(secret in printed)

    # And the header itself, which is the encoded form. The point is that a
    # `Headers` written out says how many bytes it is hiding rather than what
    # they were.
    var written = String(response.request().headers)
    assert_false("Basic " in written)
    assert_true("[secret," in written)
    client.close()
    server.stop()


def test_a_secret_is_still_reachable_when_it_is_asked_for() raises:
    # Redaction is about what gets written out by accident, not about hiding
    # the value from the caller who set it. A client that could not read back
    # its own header would be unusable.
    var auth = BasicAuth("alice", "s3cret")
    var request = auth.sign(_request("GET", "http://example.com/"))
    assert_equal(request.headers["authorization"], "Basic YWxpY2U6czNjcmV0")


# The erased form, which is what a client actually stores.


def test_an_erased_scheme_behaves_like_the_one_inside_it() raises:
    var auth = erase_auth(BasicAuth("alice", "s3cret"))
    var request = auth.sign(_request("GET", "http://example.com/"))
    assert_equal(request.headers["authorization"], "Basic YWxpY2U6czNjcmV0")
    assert_false(auth.requires_response_body())


def test_a_copy_of_an_erased_scheme_shares_its_state() raises:
    # Sharing rather than duplicating, so a digest scheme that has been
    # challenged once stays challenged for every request after it. The client
    # takes a copy on every send, and a copy that forgot would pay the extra
    # round trip every time.
    var server = TestServer()
    var client = Client(auth=digest_auth("alice", "s3cret"))
    var first = _get(client, server, "/digest-auth/auth/alice/s3cret")
    assert_equal(first.history_count(), 1)
    var second = _get(client, server, "/digest-auth/auth/alice/s3cret")
    assert_equal(second.history_count(), 0)
    var third = _get(client, server, "/digest-auth/auth/alice/s3cret")
    assert_equal(third.history_count(), 0)
    client.close()
    server.stop()
