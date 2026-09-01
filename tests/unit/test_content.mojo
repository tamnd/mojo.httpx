"""Tests for the request body encoders.

Each of these checks two things that are easy to get right separately and easy
to get inconsistent together: the bytes, and the content type that describes
them. A body encoded correctly under the wrong type is a request the server
rejects, and a right type over the wrong bytes is worse, because the server
accepts it and reads nonsense.

The content type for `content=` gets a test of its own even though the answer is
"none", because "none" is a decision here rather than an omission.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._bytes import Bytes
from httpx._content.encode import (
    FORM_TYPE,
    JSON_TYPE,
    MULTIPART_TYPE,
    EncodedBody,
    encode_bytes,
    encode_json,
    encode_multipart,
    encode_multipart_with,
    encode_request_body,
    encode_text,
    encode_urlencoded,
)
from httpx._exceptions import ErrorKind, kind_of
from httpx._content.multipart import FileUpload, MultipartData
from httpx._models.json import Json, parse_json
from httpx._models.url import QueryParams


def test_raw_bytes_go_out_unchanged() raises:
    var body = encode_bytes(Bytes("hello"))
    assert_equal(body.to_string(), "hello")
    assert_equal(len(body), 5)


def test_raw_bytes_get_no_content_type() raises:
    # Deliberate, and the same answer httpx2 gives. Labelling a hand built body
    # `application/octet-stream` would mean the client overriding the one header
    # only the caller can get right, including for bodies that are already JSON
    # or already form encoded.
    var body = encode_bytes(Bytes("hello"))
    assert_false(body.has_content_type())
    assert_equal(body.content_type, "")


def test_text_is_encoded_as_utf8() raises:
    # Byte length rather than character count. A client that measured the string
    # in characters would write a `Content-Length` short of the body for every
    # request that was not pure ASCII, and the server would hang waiting for the
    # rest or truncate it.
    var body = encode_text("héllo")
    assert_equal(body.to_string(), "héllo")
    assert_equal(len(body), 6)
    assert_false(body.has_content_type())


def test_an_empty_body_is_empty_and_not_absent() raises:
    var body = encode_bytes(Bytes())
    assert_equal(len(body), 0)
    assert_equal(body.to_string(), "")


def test_json_is_serialized_compactly() raises:
    # No spaces after the separators. It is what httpx2 sends, and on a request
    # with a few thousand fields the difference is real.
    var doc = Json.object()
    doc.set("a", 1)
    doc.set("b", "x")
    var body = encode_json(doc)
    assert_equal(body.to_string(), '{"a":1,"b":"x"}')


def test_json_says_application_json() raises:
    # And no charset parameter. `application/json` is defined to be UTF-8 and
    # RFC 8259 leaves the parameter undefined, so a strict server is entitled to
    # reject it.
    assert_equal(encode_json(Json(1)).content_type, "application/json")


def test_a_json_body_reads_back_as_the_same_document() raises:
    var doc = Json.object()
    doc.set("nested", Json.array())
    doc.set("n", 9007199254740993)
    doc.set("s", 'quote " and \\ and \n')
    var body = encode_json(doc)
    var round_trip = parse_json(body.content.as_span())
    assert_equal(round_trip["n"].as_int(), 9007199254740993)
    assert_equal(round_trip["s"].as_string(), 'quote " and \\ and \n')
    assert_equal(len(round_trip["nested"]), 0)


def test_form_fields_are_url_encoded() raises:
    var body = encode_urlencoded(QueryParams("a=1&b=2"))
    assert_equal(body.to_string(), "a=1&b=2")
    assert_equal(body.content_type, "application/x-www-form-urlencoded")


def test_a_form_value_cannot_introduce_a_field() raises:
    # The whole security content of the form encoder. A value holding `&` or `=`
    # that survived unescaped would arrive at the server as extra fields, which
    # is how a form that lets you set your display name lets you set your role.
    var params = QueryParams().add("name", "a&role=admin")
    var body = encode_urlencoded(params)
    assert_equal(body.to_string(), "name=a%26role%3Dadmin")


def test_a_form_space_becomes_a_plus() raises:
    # Form encoding, not path encoding. `%20` is also read correctly by every
    # server, but `+` is what a browser sends and parity is measured in bytes.
    assert_equal(encode_urlencoded(QueryParams("q=a b")).to_string(), "q=a+b")


def test_an_empty_form_is_an_empty_body_with_a_type() raises:
    # The type still goes on. A POST with no fields is a real request and the
    # server needs to be told how to read the nothing it is getting.
    var body = encode_urlencoded(QueryParams())
    assert_equal(len(body), 0)
    assert_equal(body.content_type, "application/x-www-form-urlencoded")


def test_multipart_puts_the_boundary_in_the_content_type() raises:
    # The one encoding where the type carries a parameter the body depends on.
    # A mismatch between the two makes the body unparseable, so they are built
    # in the same place and never separately.
    var data = MultipartData()
    data.add("a", "1")
    var body = encode_multipart_with(data, "ABC")
    assert_equal(body.content_type, "multipart/form-data; boundary=ABC")
    assert_true("--ABC\r\n" in body.to_string())


def test_a_fresh_multipart_boundary_is_used_for_every_body() raises:
    # Per call and not per client. Two requests sharing a boundary means anybody
    # who saw the first knows the boundary of the second, and knowing it is all
    # it takes to forge a part.
    var data = MultipartData()
    data.add("a", "1")
    var first = encode_multipart(data)
    var second = encode_multipart(data)
    assert_true(first.content_type != second.content_type)


def test_the_multipart_boundary_in_the_type_matches_the_body() raises:
    var data = MultipartData()
    data.add_file(FileUpload("f", "a.txt", "content"))
    var body = encode_multipart(data)

    var marker = "boundary="
    var at = body.content_type.find(marker)
    assert_true(at >= 0)
    var boundary = body.content_type[byte = at + marker.byte_length() :]

    var text = body.to_string()
    assert_true(text.startswith(String("--", boundary, "\r\n")))
    assert_true(text.endswith(String("--", boundary, "--\r\n")))


def test_the_encoded_length_is_the_byte_length() raises:
    # What `Content-Length` is set from, so it has to count bytes and not
    # anything else. Checked against a body that is not pure ASCII, because that
    # is the only case where the two disagree.
    var data = MultipartData()
    data.add("k", "é")
    var body = encode_multipart_with(data, "X")
    assert_equal(len(body), body.content.as_span().__len__())
    assert_equal(len(body), body.to_string().byte_length())


def test_an_encoded_body_can_be_copied() raises:
    # The client holds one of these across a redirect, where the same body is
    # sent again to a new location. Copying has to give back the same bytes and
    # the same type or the second request is not the first one.
    var body = encode_json(Json("x"))
    var again = body.copy()
    assert_equal(again.to_string(), body.to_string())
    assert_equal(again.content_type, body.content_type)


# Choosing between the arguments.


def _chosen(
    var content: Bytes = Bytes(),
    text: StringSpan = "",
    var data: QueryParams = QueryParams(),
    var files: MultipartData = MultipartData(),
    var json: Optional[Json] = None,
) raises -> EncodedBody:
    return encode_request_body(content^, text, data^, files^, json^)


def test_nothing_given_is_an_empty_body_with_no_type() raises:
    var body = _chosen()
    assert_equal(len(body), 0)
    assert_false(body.has_content_type())


def test_each_argument_reaches_its_own_encoder() raises:
    assert_equal(_chosen(content=Bytes("raw")).to_string(), "raw")
    assert_equal(_chosen(text="text").to_string(), "text")
    assert_equal(
        _chosen(data=QueryParams().add("a", "1")).content_type,
        String(FORM_TYPE),
    )
    assert_equal(_chosen(json=Json(1)).content_type, String(JSON_TYPE))


def test_form_fields_are_written_ahead_of_the_files() raises:
    # The order httpx2 and every browser produce. Some server side parsers hand
    # the application whichever part they saw last under a repeated name, so
    # this is not cosmetic.
    var files = MultipartData()
    files.add_file(FileUpload("upload", "a.txt", "x"))
    var body = _chosen(data=QueryParams().add("field", "v"), files=files^)

    var text = body.to_string()
    assert_true(text.find('name="field"') < text.find('name="upload"'))
    assert_true(body.content_type.startswith(String(MULTIPART_TYPE)))


def test_two_bodies_are_refused_and_both_are_named() raises:
    var raised = False
    try:
        var body = _chosen(content=Bytes("raw"), json=Json(1))
        _ = body
    except e:
        raised = True
        assert_true(kind_of(e) == ErrorKind.INVALID_ARGUMENT)
        assert_true("content=" in String(e))
        assert_true("json=" in String(e))
    assert_true(raised)


def test_an_empty_argument_is_not_a_body() raises:
    # Every one of these has an empty value that is indistinguishable from not
    # passing it, so an empty form next to a real JSON document has to be one
    # body rather than a conflict.
    var body = _chosen(
        content=Bytes(),
        text="",
        data=QueryParams(),
        files=MultipartData(),
        json=Json("only me"),
    )
    assert_equal(body.to_string(), '"only me"')
