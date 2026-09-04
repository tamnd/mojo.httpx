"""A compressed response, from the socket to `text()`.

The codec has its own tests over fixtures. What is checked here is the join:
that `Accept-Encoding` goes out saying what this process can undo, that the
`Content-Encoding` that comes back is acted on, that `iter_raw` still means raw,
and that a body large enough to arrive in several reads decodes the same as one
that arrives in a single read.

Every test returns early when the library its coding needs did not load. All
three are in the pixi environment, so they are there on every machine the suite
runs on, but a build that could not find one should report the single failure
that says so rather than a dozen that look like decoding bugs.
"""

from std.testing import assert_equal, assert_raises, assert_true

from httpx._client import Client
from httpx._codec.decode import accept_encoding
from httpx._ffi.brotli import is_available as brotli_available
from httpx._ffi.zlib import is_available
from httpx._ffi.zstd import is_available as zstd_available
from httpx._io.deadline import Deadlines
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._models.url import URL
from httpx._transport.http import HTTPTransport

from tests.support.testserver import TestServer

comptime LARGE = 200000
"""How large the streamed body is, before compression.

Two hundred thousand bytes is several socket reads on every platform here, so
the decoder is fed in pieces whose boundaries it did not choose, which is the
case the fixtures cannot reach.
"""


def _get(
    mut client: Client, server: TestServer, path: StringSpan
) raises -> Response:
    return client.get(server.url(path))


def _head(
    mut client: Client, server: TestServer, path: StringSpan
) raises -> Response:
    return client.head(server.url(path))


def _stream(
    mut transport: HTTPTransport, server: TestServer, path: StringSpan
) raises -> Response:
    return transport.handle_stream(
        Request("GET", URL(server.url(path))),
        Deadlines.uniform(Optional[Float64](10.0)),
    )


def _expected_large() raises -> String:
    """The same body `_compressed` builds on the server side."""
    var unit = String("the quick brown fox jumps. ")
    var out = String()
    while out.byte_length() < LARGE:
        out += unit
    return String(StringSpan(from_utf8=out.as_bytes()[:LARGE]))


def test_a_gzip_response_is_decoded_before_the_caller_sees_it() raises:
    if not is_available():
        return
    var server = TestServer()
    var client = Client()
    var response = _get(client, server, "/gzip")
    assert_equal(response.headers["content-encoding"], "gzip")
    assert_true(response.text().find('"encoding": "gzip"') >= 0)
    client.close()


def test_a_deflate_response_is_decoded_too() raises:
    """The server sends this one through `zlib.compress`, so it is the RFC 1950
    wrapper that `deflate` is supposed to mean."""
    if not is_available():
        return
    var server = TestServer()
    var client = Client()
    var response = _get(client, server, "/deflate")
    assert_equal(response.headers["content-encoding"], "deflate")
    assert_true(response.text().find('"encoding": "deflate"') >= 0)
    client.close()


def test_a_brotli_response_is_decoded_before_the_caller_sees_it() raises:
    if not brotli_available():
        return
    var server = TestServer()
    var client = Client()
    var response = _get(client, server, "/brotli")
    assert_equal(response.headers["content-encoding"], "br")
    assert_true(response.text().find('"encoding": "br"') >= 0)
    client.close()


def test_a_zstd_response_is_decoded_before_the_caller_sees_it() raises:
    if not zstd_available():
        return
    var server = TestServer()
    var client = Client()
    var response = _get(client, server, "/zstd")
    assert_equal(response.headers["content-encoding"], "zstd")
    assert_true(response.text().find('"encoding": "zstd"') >= 0)
    client.close()


def test_the_decoded_body_parses_as_what_the_content_type_said() raises:
    """`json()` reads `content`, so this fails if anything on the buffered path
    handed back compressed bytes."""
    if not is_available():
        return
    var server = TestServer()
    var client = Client()
    var response = _get(client, server, "/gzip")
    var body = response.json()
    assert_equal(body["encoding"].as_string(), "gzip")
    assert_true(body["compressed"].as_bool())
    client.close()


def test_accept_encoding_says_what_this_process_can_undo() raises:
    if not is_available():
        return
    var server = TestServer()
    var client = Client()
    var response = _get(client, server, "/headers")
    assert_true(accept_encoding().startswith("gzip, deflate"))
    assert_true(response.text().find(accept_encoding()) >= 0)
    client.close()


def test_iter_raw_still_means_raw() raises:
    """The one call that does not decode. A caller who wants the bytes the
    server sent, to store them or to forward them, has to be able to get them,
    and the two magic bytes at the front are the proof they are still gzip."""
    if not is_available():
        return
    var server = TestServer()
    var transport = HTTPTransport()
    var response = _stream(transport, server, "/gzip")
    var raw = List[UInt8]()
    var chunks = response.iter_raw()
    while chunks.has_next():
        raw.extend(Span(chunks.next()))
    assert_true(len(raw) > 2)
    assert_equal(raw[0], 0x1F)
    assert_equal(raw[1], 0x8B)
    server.stop()


def test_iter_bytes_decodes_a_body_that_is_still_on_the_wire() raises:
    if not is_available():
        return
    var server = TestServer()
    var transport = HTTPTransport()
    var response = _stream(transport, server, "/gzip")
    var out = List[UInt8]()
    var chunks = response.iter_bytes()
    while chunks.has_next():
        out.extend(Span(chunks.next()))
    var text = String(StringSpan(from_utf8=Span(out)))
    assert_true(text.find('"encoding": "gzip"') >= 0)
    server.stop()


def test_a_large_body_decodes_the_same_arriving_in_pieces() raises:
    if not is_available():
        return
    var server = TestServer()
    var client = Client()
    var response = _get(client, server, "/gzip?size=200000")
    assert_equal(response.text(), _expected_large())
    client.close()


def test_a_large_deflate_body_decodes_the_same_way() raises:
    if not is_available():
        return
    var server = TestServer()
    var client = Client()
    var response = _get(client, server, "/deflate?size=200000")
    assert_equal(response.text(), _expected_large())
    client.close()


def test_a_large_brotli_body_decodes_the_same_way() raises:
    """Two hundred thousand bytes of text, so the compressed body still spans
    several socket reads and the decoder is fed on boundaries it did not
    choose. That is the case the fixtures cannot reach, and it is the one where
    a streaming binding that mishandles a partial block goes wrong."""
    if not brotli_available():
        return
    var server = TestServer()
    var client = Client()
    var response = _get(client, server, "/brotli?size=200000")
    assert_equal(response.text(), _expected_large())
    client.close()


def test_a_large_zstd_body_decodes_the_same_way() raises:
    if not zstd_available():
        return
    var server = TestServer()
    var client = Client()
    var response = _get(client, server, "/zstd?size=200000")
    assert_equal(response.text(), _expected_large())
    client.close()


def test_the_download_count_stays_on_the_compressed_bytes() raises:
    """What a progress bar is drawn against. The server announced a length for
    the compressed body, so counting the decoded one would run the bar past its
    own end long before the download finished."""
    if not is_available():
        return
    var server = TestServer()
    var transport = HTTPTransport()
    var response = _stream(transport, server, "/gzip?size=200000")
    var produced = 0
    var chunks = response.iter_bytes()
    while chunks.has_next():
        produced += len(chunks.next())
    assert_equal(produced, LARGE)
    assert_true(chunks.num_bytes_downloaded() < produced)
    assert_true(chunks.num_bytes_downloaded() > 0)
    server.stop()


def test_a_coding_we_did_not_ask_for_is_refused() raises:
    """The server ignored `Accept-Encoding` and answered in `exi`. Handing the
    bytes over as content would make `text` and `json` quietly wrong, so this
    fails instead, and says which coding it was."""
    var server = TestServer()
    var client = Client()
    with assert_raises(contains="cannot decode"):
        _ = _get(client, server, "/unknown-encoding")
    client.close()


def test_iter_text_reads_a_compressed_body_as_text() raises:
    if not is_available():
        return
    var server = TestServer()
    var transport = HTTPTransport()
    var response = _stream(transport, server, "/gzip?size=200000")
    var out = String()
    var chunks = response.iter_text(4096)
    while chunks.has_next():
        out += chunks.next()
    assert_equal(out, _expected_large())
    server.stop()


def test_iter_lines_reads_a_compressed_body_as_lines() raises:
    if not is_available():
        return
    var server = TestServer()
    var transport = HTTPTransport()
    var response = _stream(transport, server, "/gzip")
    var seen = 0
    var lines = response.iter_lines()
    while lines.has_next():
        assert_true(lines.next().find("gzip") >= 0)
        seen += 1
    assert_equal(seen, 1)
    server.stop()


def test_iter_bytes_on_a_read_response_does_not_decode_twice() raises:
    """`read` already decoded, so `_content` holds the document. Running it
    through a decoder again would fail on the first byte, which is what makes
    this worth a test rather than an argument."""
    if not is_available():
        return
    var server = TestServer()
    var client = Client()
    var response = _get(client, server, "/gzip")
    var out = List[UInt8]()
    var chunks = response.iter_bytes()
    while chunks.has_next():
        out.extend(Span(chunks.next()))
    assert_equal(String(StringSpan(from_utf8=Span(out))), response.text())
    client.close()


def test_a_head_response_with_a_content_encoding_is_not_an_error() raises:
    """No body at all, and a header saying that body was gzipped. Refusing it
    as truncated would turn every conditional request into a failure."""
    if not is_available():
        return
    var server = TestServer()
    var client = Client()
    var response = _head(client, server, "/gzip")
    assert_equal(response.status_code, 200)
    assert_equal(response.headers["content-encoding"], "gzip")
    assert_equal(len(response.content()), 0)
    client.close()
