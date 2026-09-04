"""The CLI driver: what it builds, what it exits with, what it writes.

Everything here goes through `run(argv)` or through the two functions that
build the client and the request, never through a process, because there is
nothing a process would add except a way for the suite to hang.

The tests that involve a server keep their output off stdout, either because
the case fails before there is a body or because `--download` sends the body to
a file. A test that printed a response body into the middle of the test
runner's own output would be a test that made every other result harder to
read.
"""

from std.python import Python
from std.testing import assert_equal, assert_false, assert_true

from httpx._bytes import Bytes
from httpx._exceptions import ErrorKind, new_error
from httpx._io.files import read_text
from httpx.cli.args import parse
from httpx.cli.exits import (
    EXIT_NETWORK,
    EXIT_OK,
    EXIT_REDIRECTS,
    EXIT_STATUS,
    EXIT_TIMEOUT,
    EXIT_TLS,
    EXIT_USAGE,
    code_for,
    is_tls_failure,
)
from httpx.cli.help import HELP, version_line
from httpx.cli.run import _client_for, _request_for, run

from tests.support.testserver import TestServer


def _line(*words: String) -> List[String]:
    """A command line as a list, so a test reads like a shell prompt."""
    var out = List[String]()
    for i in range(len(words)):
        out.append(words[i])
    return out^


def _temp_path(name: String) raises -> String:
    """A path in the system temporary directory, for a download to land in."""
    var tempfile = Python.import_module("tempfile")
    var os = Python.import_module("os")
    return String(os.path.join(tempfile.gettempdir(), name))


def _remove(path: String) raises:
    var os = Python.import_module("os")
    if os.path.exists(path):
        os.remove(path)


def _write_file(path: String, text: String) raises:
    with open(path, "w") as handle:
        handle.write(text)


def _body_of(argv: List[String]) raises -> String:
    """The request a command line builds, as text."""
    var args = parse(argv)
    var client = _client_for(args)
    var request = _request_for(client, args)
    return Bytes(Span(request.content)).to_string()


# The exit code table, checked against errors of every kind that can come out
# of a send. These do not need a network, because the mapping is a function of
# the error and nothing else.


def test_a_timeout_is_the_timeout_code() raises:
    assert_equal(
        code_for(new_error(ErrorKind.CONNECT_TIMEOUT, "too slow")),
        EXIT_TIMEOUT,
    )
    assert_equal(
        code_for(new_error(ErrorKind.READ_TIMEOUT, "too slow")), EXIT_TIMEOUT
    )
    assert_equal(
        code_for(new_error(ErrorKind.POOL_TIMEOUT, "too slow")), EXIT_TIMEOUT
    )


def test_too_many_redirects_is_its_own_code() raises:
    assert_equal(
        code_for(new_error(ErrorKind.TOO_MANY_REDIRECTS, "round and round")),
        EXIT_REDIRECTS,
    )


def test_a_refused_connection_is_the_network_code() raises:
    assert_equal(
        code_for(new_error(ErrorKind.CONNECT_ERROR, "connect refused")),
        EXIT_NETWORK,
    )


def test_a_url_that_does_not_parse_is_a_usage_error() raises:
    # Even though it surfaced from the send, because it is about what was
    # typed rather than about the network.
    assert_equal(
        code_for(new_error(ErrorKind.INVALID_URL, "not a URL")), EXIT_USAGE
    )
    assert_equal(
        code_for(new_error(ErrorKind.UNSUPPORTED_PROTOCOL, "no ftp here")),
        EXIT_USAGE,
    )


def test_an_error_from_somewhere_else_is_the_network_code() raises:
    assert_equal(code_for(Error("something nobody classified")), EXIT_NETWORK)


def test_a_tls_failure_is_told_apart_from_the_connection_under_it() raises:
    # The three messages `httpx/_stream/tls.mojo` raises, and one that is a
    # connect failure of the ordinary kind.
    assert_true(
        is_tls_failure(
            new_error(
                ErrorKind.CONNECT_ERROR,
                "the TLS certificate from example.com was rejected: expired",
            )
        )
    )
    assert_true(
        is_tls_failure(
            new_error(
                ErrorKind.CONNECT_ERROR,
                "the connection to example.com closed during the TLS handshake",
            )
        )
    )
    assert_true(
        is_tls_failure(
            new_error(
                ErrorKind.CONNECT_ERROR,
                "the TLS handshake with example.com failed: bad record",
            )
        )
    )
    assert_false(
        is_tls_failure(
            new_error(ErrorKind.CONNECT_ERROR, "connect 10.0.0.1:443 failed")
        )
    )


def test_a_failure_that_is_not_a_connect_is_never_a_tls_failure() raises:
    # The word alone is not enough. A read that failed after the handshake is
    # a network failure, and a body that happens to mention TLS is nothing at
    # all.
    assert_false(
        is_tls_failure(
            new_error(ErrorKind.READ_ERROR, "TLS read from example.com failed")
        )
    )


# What a command line builds, before anything is sent.


def test_headers_and_cookies_from_the_command_line_reach_the_request() raises:
    var args = parse(
        _line("-h", "X-Test", "yes", "--cookies", "sid", "abc", "http://x/")
    )
    var client = _client_for(args)
    var request = _request_for(client, args)
    assert_equal(request.headers["X-Test"], "yes")
    assert_equal(request.headers["Cookie"], "sid=abc")


def test_params_reach_the_url() raises:
    var args = parse(_line("-p", "q", "mojo", "-p", "n", "2", "http://x/"))
    var client = _client_for(args)
    var request = _request_for(client, args)
    assert_equal(request.url.raw_path(), "/?q=mojo&n=2")


def test_a_form_becomes_a_urlencoded_body() raises:
    var argv = _line("-d", "name", "mojo", "-d", "n", "2", "http://x/")
    assert_equal(_body_of(argv), "name=mojo&n=2")
    var args = parse(argv)
    var client = _client_for(args)
    var request = _request_for(client, args)
    assert_equal(
        request.headers["Content-Type"], "application/x-www-form-urlencoded"
    )
    # No -m on the line, and a body on it, so the method follows the body.
    assert_equal(request.method, "POST")


def test_content_is_sent_exactly_as_it_was_written() raises:
    assert_equal(_body_of(_line("-c", "raw bytes", "http://x/")), "raw bytes")


def test_json_is_sent_as_json() raises:
    var argv = _line("-j", '{"a": 1}', "http://x/")
    var args = parse(argv)
    var client = _client_for(args)
    var request = _request_for(client, args)
    assert_equal(request.headers["Content-Type"], "application/json")
    # Reserialized rather than passed through, so the spacing is the
    # serializer's rather than the one that was typed.
    assert_equal(Bytes(Span(request.content)).to_string(), '{"a":1}')


def test_a_json_body_that_does_not_parse_names_the_flag() raises:
    assert_equal(run(_line("-j", "{oops", "http://127.0.0.1:1/")), EXIT_USAGE)


def test_a_file_becomes_a_multipart_part_named_by_its_basename() raises:
    var path = _temp_path("httpx-cli-upload.txt")
    _write_file(path, "hello upload")
    var body = _body_of(_line("-f", "doc", path, "http://x/"))
    _remove(path)
    assert_true(body.find('name="doc"') >= 0)
    assert_true(body.find('filename="httpx-cli-upload.txt"') >= 0)
    assert_true(body.find("hello upload") >= 0)


def test_a_file_that_is_not_there_is_a_usage_error() raises:
    var path = _temp_path("httpx-cli-not-here.txt")
    _remove(path)
    assert_equal(run(_line("-f", "doc", path, "http://x/")), EXIT_USAGE)


def test_a_proxy_that_is_not_a_proxy_is_a_usage_error() raises:
    assert_equal(
        run(_line("--proxy", "not a proxy", "http://127.0.0.1:1/")), EXIT_USAGE
    )


# What the whole program does, from a command line to an exit code.


def test_a_command_line_with_no_url_is_a_usage_error() raises:
    assert_equal(run(List[String]()), EXIT_USAGE)


def test_a_flag_nobody_has_is_a_usage_error() raises:
    assert_equal(run(_line("--nonsense", "http://x/")), EXIT_USAGE)


def test_a_relative_url_is_a_usage_error() raises:
    assert_equal(run(_line("/just/a/path")), EXIT_USAGE)


def test_a_scheme_this_client_does_not_speak_is_a_usage_error() raises:
    assert_equal(run(_line("ftp://example.com/")), EXIT_USAGE)


def test_a_host_that_does_not_resolve_is_the_network_code() raises:
    # A name under .invalid, which RFC 2606 reserves for exactly this and which
    # no resolver is allowed to answer. A closed port on loopback would be the
    # obvious way to write this and it is wrong: under WSL2 a connect to an
    # unbound loopback port is swallowed by the localhost relay and hangs until
    # the timeout, so the same command exits 3 there and 2 everywhere else.
    assert_equal(run(_line("http://no-such-host.invalid/")), EXIT_NETWORK)


def test_a_download_writes_the_body_to_the_file() raises:
    var server = TestServer()
    var path = _temp_path("httpx-cli-download.bin")
    _remove(path)
    var code = run(_line("--download", path, server.url("/bytes/64")))
    server.stop()
    var body = read_text(path)
    _remove(path)
    assert_equal(code, EXIT_OK)
    assert_equal(body.byte_length(), 64)


def test_a_download_to_a_directory_that_is_not_there_is_a_usage_error() raises:
    # Reported without a request being made, because the file is opened first.
    var server = TestServer()
    var code = run(
        _line("--download", "/no/such/directory/at/all.bin", server.url("/get"))
    )
    server.stop()
    assert_equal(code, EXIT_USAGE)


def test_an_error_status_is_a_success_until_fail_is_asked_for() raises:
    var server = TestServer()
    var path = _temp_path("httpx-cli-404.bin")
    _remove(path)
    # Downloaded rather than printed, only so that the 404 body does not land
    # in the middle of the test runner's output.
    var quiet = run(_line("--download", path, server.url("/status/404")))
    var loud = run(_line("--fail", server.url("/status/404")))
    server.stop()
    _remove(path)
    assert_equal(quiet, EXIT_OK)
    assert_equal(loud, EXIT_STATUS)


def test_fail_leaves_a_success_alone() raises:
    var server = TestServer()
    var path = _temp_path("httpx-cli-ok.bin")
    _remove(path)
    var code = run(_line("--fail", "--download", path, server.url("/get")))
    server.stop()
    _remove(path)
    assert_equal(code, EXIT_OK)


def test_a_redirect_chain_that_never_ends_is_its_own_code() raises:
    var server = TestServer()
    var code = run(_line(server.url("/redirect/40")))
    server.stop()
    assert_equal(code, EXIT_REDIRECTS)


def test_a_timeout_that_expires_is_the_timeout_code() raises:
    var server = TestServer()
    var code = run(_line("--timeout", "0.2", server.url("/delay/2")))
    server.stop()
    assert_equal(code, EXIT_TIMEOUT)


def test_a_handshake_against_a_server_that_is_not_speaking_tls() raises:
    """The TLS exit code, pinned against a handshake that really failed.

    `is_tls_failure` reads the message rather than the kind, because there is
    no TLS kind to read. This is what keeps that from rotting: a plain HTTP
    server answered on https, OpenSSL made nothing of the reply, and the code
    that comes back has to be the TLS one rather than the network one.
    """
    var server = TestServer()
    var url = String("https://", server.authority(), "/get")
    var code = run(_line("--no-verify", url))
    server.stop()
    assert_equal(code, EXIT_TLS)


# The help text, which is written by hand and so can drift from the parser.


def test_every_option_the_parser_takes_is_in_the_help() raises:
    var names: List[String] = [
        "--method",
        "--params",
        "--headers",
        "--cookies",
        "--content",
        "--data",
        "--files",
        "--json",
        "--auth",
        "--proxy",
        "--timeout",
        "--http2",
        "--verify",
        "--no-verify",
        "--follow-redirects",
        "--no-follow-redirects",
        "--verbose",
        "--print",
        "--download",
        "--fail",
        "--help",
        "--version",
    ]
    for i in range(len(names)):
        assert_true(
            String(HELP).find(names[i]) >= 0,
            String(names[i], " is an option and is not in the help"),
        )


def test_the_help_and_the_version_end_in_a_newline() raises:
    # Both go straight to stdout with nothing added, so the newline has to be
    # in the text itself.
    assert_true(String(HELP).endswith("\n"))
    assert_true(version_line().endswith("\n"))


def test_the_version_line_names_the_program_and_the_version() raises:
    assert_true(version_line().startswith("httpx "))
