"""Tests for the body arguments on the client.

The encoders themselves are tested in `test_content.mojo`. What is tested here
is the wiring: that each argument reaches the right encoder, that the content
type it implies ends up on the request unless the caller wrote one, and that
passing two bodies is refused rather than resolved by a precedence rule nobody
would remember.

Most of it runs over a `MockRouter`, so the assertions are on the request the
transport was handed rather than on what a server made of it. The last two go
over a real socket, because framing is the part a mock cannot check.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._bytes import Bytes
from httpx._client import Client
from httpx._content.multipart import FileUpload, MultipartData
from httpx._exceptions import ErrorKind, kind_of
from httpx._models.headers import Headers
from httpx._models.json import Json
from httpx._models.request import Request
from httpx._models.stream import ByteSource, ByteStream, erase_source
from httpx._models.url import QueryParams
from httpx._transport.base import AnyTransport, erase_transport
from httpx._transport.mock import MockRouter, Route
from tests.support.testserver import TestServer


struct _NoChunks(ByteSource, Movable):
    """A request body source that ends immediately. Only its type is needed."""

    def __init__(out self):
        pass

    def read_chunk(mut self) raises -> List[UInt8]:
        return List[UInt8]()

    def close(mut self):
        pass

    def trailers(self) -> Headers:
        return Headers()


def _router() raises -> AnyTransport:
    var router = MockRouter()
    router.add(Route.any().respond(200))
    return erase_transport(router^)


def _sent_body(request: Request) raises -> String:
    return Bytes(Span(request.content)).to_string()


def test_content_goes_out_unchanged_and_names_no_type() raises:
    # The one place the answer surprises people. Bytes with no description are
    # the caller's business, and a client that labelled them would be a client
    # overriding the one header only the caller can get right.
    var transport = _router()
    var handle = transport.copy()
    var client = Client(transport^)
    var raw = List[UInt8]()
    raw.extend("<xml/>".as_bytes())
    _ = client.post("http://x/", content=raw^)

    ref sent = handle.state[MockRouter]().calls
    assert_equal(_sent_body(sent[0]), "<xml/>")
    assert_false("content-type" in sent[0].headers)


def test_text_is_sent_as_utf_8_and_names_no_type() raises:
    var transport = _router()
    var handle = transport.copy()
    var client = Client(transport^)
    _ = client.post("http://x/", text="héllo")

    ref sent = handle.state[MockRouter]().calls
    assert_equal(_sent_body(sent[0]), "héllo")
    assert_equal(len(sent[0].content), 6)
    assert_false("content-type" in sent[0].headers)


def test_data_is_urlencoded_and_names_the_form_type() raises:
    var transport = _router()
    var handle = transport.copy()
    var client = Client(transport^)
    _ = client.post(
        "http://x/",
        data=QueryParams().add("name", "a b").add("tag", "x&y"),
    )

    ref sent = handle.state[MockRouter]().calls
    assert_equal(_sent_body(sent[0]), "name=a+b&tag=x%26y")
    assert_equal(
        sent[0].headers.get("content-type"),
        "application/x-www-form-urlencoded",
    )


def test_json_is_serialized_compactly_and_names_the_json_type() raises:
    var payload = Json.object()
    payload.set("name", Json("widget"))
    payload.set("count", Json(3))

    var transport = _router()
    var handle = transport.copy()
    var client = Client(transport^)
    _ = client.post("http://x/", json=payload^)

    ref sent = handle.state[MockRouter]().calls
    assert_equal(_sent_body(sent[0]), '{"name":"widget","count":3}')
    assert_equal(sent[0].headers.get("content-type"), "application/json")


def test_a_json_null_body_is_still_a_body() raises:
    # `json=` is an `Optional` precisely so that a `null` document, which is
    # valid JSON and a sensible thing to send, is not read as nothing passed.
    var transport = _router()
    var handle = transport.copy()
    var client = Client(transport^)
    _ = client.post("http://x/", json=Json.null())

    ref sent = handle.state[MockRouter]().calls
    assert_equal(_sent_body(sent[0]), "null")
    assert_equal(sent[0].headers.get("content-type"), "application/json")


def test_files_are_multipart_with_a_boundary_on_the_type() raises:
    var files = MultipartData()
    files.add_file(FileUpload("report", "report.csv", "a,b\n1,2\n"))

    var transport = _router()
    var handle = transport.copy()
    var client = Client(transport^)
    _ = client.post("http://x/", files=files^)

    ref sent = handle.state[MockRouter]().calls
    var content_type = sent[0].headers.get("content-type")
    assert_true(content_type.startswith("multipart/form-data; boundary="))

    var body = _sent_body(sent[0])
    assert_true('name="report"' in body)
    assert_true('filename="report.csv"' in body)
    assert_true("text/csv" in body)
    assert_true("a,b\n1,2\n" in body)


def test_data_and_files_together_are_one_multipart_body() raises:
    # Not two bodies. This is the form a browser sends for a form with a file
    # input on it, and the fields go in ahead of the files.
    var files = MultipartData()
    files.add_file(FileUpload("avatar", "me.png", "PNG"))

    var transport = _router()
    var handle = transport.copy()
    var client = Client(transport^)
    _ = client.post(
        "http://x/", data=QueryParams().add("name", "alice"), files=files^
    )

    ref sent = handle.state[MockRouter]().calls
    assert_true(
        sent[0]
        .headers.get("content-type")
        .startswith("multipart/form-data; boundary=")
    )

    var body = _sent_body(sent[0])
    assert_true('name="name"' in body)
    assert_true('name="avatar"' in body)
    assert_true(body.find('name="name"') < body.find('name="avatar"'))


def test_two_multipart_bodies_get_different_boundaries() raises:
    # A boundary reused across requests means anybody who saw the first knows
    # the boundary of the second, which is the whole of what forging a part
    # needs.
    var transport = _router()
    var handle = transport.copy()
    var client = Client(transport^)
    for _ in range(2):
        var files = MultipartData()
        files.add_file(FileUpload("f", "a.txt", "x"))
        _ = client.post("http://x/", files=files^)

    ref sent = handle.state[MockRouter]().calls
    assert_true(
        sent[0].headers.get("content-type")
        != sent[1].headers.get("content-type")
    )


# The content type the encoding implies is a default, not an override.


def test_an_explicit_content_type_wins_over_the_encoding() raises:
    var headers = Headers()
    headers["Content-Type"] = "application/vnd.api+json"

    var transport = _router()
    var handle = transport.copy()
    var client = Client(transport^)
    _ = client.post("http://x/", json=Json("hello"), headers=headers^)

    ref sent = handle.state[MockRouter]().calls
    assert_equal(
        sent[0].headers.get("content-type"), "application/vnd.api+json"
    )
    assert_equal(_sent_body(sent[0]), '"hello"')


def test_a_client_content_type_also_wins_over_the_encoding() raises:
    # The client header is merged before the encoding's type is defaulted in, so
    # a client built for one media type does not have it undone per call.
    var headers = Headers()
    headers["Content-Type"] = "application/vnd.api+json"

    var transport = _router()
    var handle = transport.copy()
    var client = Client(transport=transport^, headers=headers^)
    _ = client.post("http://x/", json=Json(1))

    ref sent = handle.state[MockRouter]().calls
    assert_equal(
        sent[0].headers.get("content-type"), "application/vnd.api+json"
    )


# Two bodies are a mistake, not a precedence question.


def test_passing_two_bodies_raises_and_names_both() raises:
    var client = Client(_router())
    var raised = False
    try:
        _ = client.post("http://x/", text="hello", json=Json(1))
    except e:
        raised = True
        assert_true(kind_of(e) == ErrorKind.INVALID_ARGUMENT)
        assert_true("text=" in String(e))
        assert_true("json=" in String(e))
    assert_true(raised)


def test_data_and_json_together_raise() raises:
    # httpx2 lets these two fight and drops one silently, so the caller finds
    # out from the server. Naming both here is the whole point.
    var client = Client(_router())
    var raised = False
    try:
        _ = client.post(
            "http://x/", data=QueryParams().add("a", "1"), json=Json(1)
        )
    except e:
        raised = True
        assert_true("data=" in String(e))
        assert_true("json=" in String(e))
    assert_true(raised)


def test_a_stream_cannot_be_combined_with_another_body() raises:
    var client = Client(_router())
    var raised = False
    try:
        _ = client.post(
            "http://x/",
            text="hello",
            content_stream=Optional[ByteStream](erase_source(_NoChunks())),
        )
    except e:
        raised = True
        assert_true("content_stream=" in String(e))
    assert_true(raised)


# The same arguments on the other verbs.


def test_put_and_patch_take_a_body_too() raises:
    var transport = _router()
    var handle = transport.copy()
    var client = Client(transport^)
    _ = client.put("http://x/a", json=Json(1))
    _ = client.patch("http://x/b", text="patched")
    _ = client.request("DELETE", "http://x/c", text="gone")

    ref sent = handle.state[MockRouter]().calls
    assert_equal(_sent_body(sent[0]), "1")
    assert_equal(_sent_body(sent[1]), "patched")
    assert_equal(_sent_body(sent[2]), "gone")


def test_build_request_shows_the_body_without_sending_it() raises:
    var client = Client(_router())
    var built = client.build_request(
        "POST", "http://x/", data=QueryParams().add("a", "1")
    )
    assert_equal(_sent_body(built), "a=1")
    assert_equal(
        built.headers.get("content-type"),
        "application/x-www-form-urlencoded",
    )
    assert_equal(len(client.build_request("GET", "http://x/").content), 0)


# One trip over a real socket, so the framing is not only asserted in a mock.


def test_a_json_body_arrives_over_the_wire() raises:
    var server = TestServer()
    var client = Client()
    var payload = Json.object()
    payload.set("name", Json("widget"))
    var response = client.post(server.url("/echo"), json=payload^)
    assert_equal(response.status_code, 200)
    assert_equal(response.text(), '{"name":"widget"}')
    server.stop()


def test_a_form_body_is_length_framed_and_labelled() raises:
    # `/post` answers with what it saw, which is how the framing gets checked
    # rather than assumed. A form has a known length, so it is never chunked.
    var server = TestServer()
    var client = Client()
    var response = client.post(
        server.url("/post"), data=QueryParams().add("a", "1").add("b", "2")
    )
    var seen = response.text()
    assert_true('"Content-Length": "7"' in seen)
    assert_true('"Content-Type": "application/x-www-form-urlencoded"' in seen)
    assert_true('"data": "a=1&b=2"' in seen)
    server.stop()
