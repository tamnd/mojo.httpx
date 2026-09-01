"""The Mojo half of the parity suite.

One function per case, named after the case in `cases.py`. Nothing here tells
the driver which cases ran. It does not need telling: every request carries the
case name in its path, so a case implemented on one side and forgotten on the
other shows up as a case with records from only one client, which the driver
treats as a failure. That is a stronger check than comparing two lists of names,
and it needs no parsing of this file.

Each case gets its own client. Sharing one would let a cookie set by an earlier
case reach a later request, and then a difference would depend on the order the
cases happen to run in.

The base URL arrives in `PARITY_BASE` rather than on the command line, because
Mojo 1.0 has no `argv`. Request cases print nothing; the comparison is over the
bytes the server recorded. Response cases print one line each, which is what the
driver compares for those.
"""

from httpx._auth import basic_auth, digest_auth
from httpx._client import Client
from httpx._content.multipart import FileUpload, MultipartData
from httpx._ffi.c import getenv
from httpx._models.cookies import Cookies
from httpx._models.headers import Headers
from httpx._models.json import Json
from httpx._models.response import Response
from httpx._models.url import QueryParams


def _base() raises -> String:
    var found = getenv("PARITY_BASE")
    if not found or found.value() == "":
        raise Error("PARITY_BASE is not set")
    return found.value()


def _url(name: StringSpan) raises -> String:
    return String(_base(), "/s/", name)


def _client() raises -> Client:
    return Client()


# The bytes that go out. Nothing is printed; the server keeps what arrived.


def get_plain() raises:
    var c = _client()
    _ = c.get(_url("get_plain"))
    c.close()


def get_params() raises:
    var c = _client()
    _ = c.get(
        _url("get_params"),
        params=QueryParams()
        .add("q", "a b&c=d")
        .add("empty", "")
        .add("unicode", "héllo"),
    )
    c.close()


def get_query_in_url() raises:
    var c = _client()
    _ = c.get(_url("get_query_in_url") + "?already=set&x=1")
    c.close()


def get_path_needing_escapes() raises:
    var c = _client()
    _ = c.get(_url("get_path_needing_escapes") + "/a b/c%2Fd/é")
    c.close()


def get_custom_headers() raises:
    var headers = Headers()
    headers["X-Marker"] = "here"
    headers["X-Empty"] = ""
    headers["Accept"] = "text/plain"
    var c = _client()
    _ = c.get(_url("get_custom_headers"), headers=headers^)
    c.close()


def get_cookies() raises:
    var cookies = Cookies()
    cookies.set("a", "1")
    cookies.set("b", "two")
    var c = _client()
    _ = c.get(_url("get_cookies"), cookies=cookies^)
    c.close()


def post_json() raises:
    var payload = Json.object()
    payload.set("name", "widget")
    payload.set("n", 2)
    payload.set("on", True)
    payload.set("nil", Json.null())
    var c = _client()
    _ = c.post(_url("post_json"), json=payload^)
    c.close()


def post_json_unicode() raises:
    var payload = Json.object()
    payload.set("text", "héllo wörld")
    var c = _client()
    _ = c.post(_url("post_json_unicode"), json=payload^)
    c.close()


def post_form() raises:
    var c = _client()
    _ = c.post(
        _url("post_form"),
        data=QueryParams().add("a", "1 2").add("b", "x&y").add("c", ""),
    )
    c.close()


def post_text() raises:
    var c = _client()
    _ = c.post(_url("post_text"), text="plain text")
    c.close()


def post_bytes() raises:
    # Not valid UTF-8, which is the point: `content=` takes bytes and must not
    # go anywhere near a decoder on the way out.
    var body = List[UInt8]()
    body.append(0)
    body.append(1)
    body.append(254)
    body.append(255)
    var c = _client()
    _ = c.post(_url("post_bytes"), content=body^)
    c.close()


def post_empty() raises:
    var c = _client()
    _ = c.post(_url("post_empty"))
    c.close()


def post_multipart() raises:
    var files = MultipartData()
    files.add("field", "value")
    files.add_file(FileUpload("f", "a.txt", "hello", "text/plain"))
    var c = _client()
    _ = c.post(_url("post_multipart"), files=files^)
    c.close()


def put_json() raises:
    var payload = Json.array()
    payload.append(1)
    payload.append(2)
    payload.append(3)
    var c = _client()
    _ = c.put(_url("put_json"), json=payload^)
    c.close()


def patch_text() raises:
    var c = _client()
    _ = c.patch(_url("patch_text"), text="patched")
    c.close()


def delete_plain() raises:
    var c = _client()
    _ = c.delete(_url("delete_plain"))
    c.close()


def head_plain() raises:
    var c = _client()
    _ = c.head(_url("head_plain"))
    c.close()


def options_plain() raises:
    var c = _client()
    _ = c.options(_url("options_plain"))
    c.close()


def basic_auth_case() raises:
    var c = _client()
    _ = c.get(_url("basic_auth"), auth=basic_auth("alice", "s3cret"))
    c.close()


def digest_auth_no_qop() raises:
    var c = _client()
    _ = c.get(_url("digest_auth_no_qop"), auth=digest_auth("alice", "s3cret"))
    c.close()


def digest_auth_qop() raises:
    var c = _client()
    _ = c.get(_url("digest_auth_qop"), auth=digest_auth("alice", "s3cret"))
    c.close()


def redirect_302_get() raises:
    var c = Client(follow_redirects=True)
    _ = c.get(_url("redirect_302_get"))
    c.close()


def redirect_303_post_becomes_get() raises:
    var payload = Json.object()
    payload.set("dropped", True)
    var c = Client(follow_redirects=True)
    _ = c.post(_url("redirect_303_post_becomes_get"), json=payload^)
    c.close()


def redirect_307_keeps_body() raises:
    var c = Client(follow_redirects=True)
    _ = c.post(_url("redirect_307_keeps_body"), text="kept")
    c.close()


def redirect_relative_target() raises:
    var c = Client(follow_redirects=True)
    _ = c.get(_url("redirect_relative_target") + "/deep/here")
    c.close()


def cookie_from_response_is_sent_back() raises:
    var c = Client(follow_redirects=True)
    _ = c.get(_url("cookie_from_response_is_sent_back"))
    c.close()


# What the client makes of an answer. One line per case, and the driver compares
# the line rather than the bytes, because these cases are about the reading.


comptime _NIBBLES = "0123456789abcdef"


def _hex[o: ImmOrigin](bytes: Span[UInt8, o]) -> String:
    """Two characters per byte, always.

    Written out by nibble rather than with `hex`, which drops a leading zero. A
    report where two adjacent bytes can join into something that reads like one
    is a report that can call two different bodies equal.
    """
    var out = String()
    for i in range(bytes.__len__()):
        var high = Int(bytes[i] >> 4)
        var low = Int(bytes[i] & 0xF)
        out += _NIBBLES[byte = high : high + 1]
        out += _NIBBLES[byte = low : low + 1]
    return out^


def _report(name: StringSpan, mut response: Response) raises:
    """One case, flattened to a line.

    The text is written as hex so a body holding a newline, a quote or a byte
    that is not valid UTF-8 cannot break the line it is reported on, and so a
    difference of one byte is visible rather than hidden inside a rendering.
    """
    var text: String
    var encoding: String
    try:
        encoding = response.encoding()
        text = response.text()
    except e:
        encoding = "<error>"
        text = String(e)

    print(
        String(
            name,
            "\t",
            response.status_code,
            "\t",
            response.reason_phrase,
            "\t",
            encoding,
            "\t",
            _hex(text.as_bytes()),
        )
    )


def _read_case(name: StringSpan) raises:
    var c = _client()
    var response = c.get(_url(name))
    _report(name, response)
    c.close()


def main() raises:
    get_plain()
    get_params()
    get_query_in_url()
    get_path_needing_escapes()
    get_custom_headers()
    get_cookies()
    post_json()
    post_json_unicode()
    post_form()
    post_text()
    post_bytes()
    post_empty()
    post_multipart()
    put_json()
    patch_text()
    delete_plain()
    head_plain()
    options_plain()
    basic_auth_case()
    digest_auth_no_qop()
    digest_auth_qop()
    redirect_302_get()
    redirect_303_post_becomes_get()
    redirect_307_keeps_body()
    redirect_relative_target()
    cookie_from_response_is_sent_back()

    _read_case("resp_text_utf8")
    _read_case("resp_text_latin1")
    _read_case("resp_text_bom")
    _read_case("resp_json_no_charset")
    _read_case("resp_custom_reason")
    _read_case("resp_no_content")
    _read_case("resp_chunked")
    _read_case("resp_closed_body")
    _read_case("resp_repeated_headers")
    _read_case("resp_link_header")
    _read_case("resp_empty_body_200")
