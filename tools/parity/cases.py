"""The scenarios both clients run, and the answers the server gives back.

Each case has a name, the replies the recording server hands out on each hit,
and the httpx2 code that produces the request. The Mojo side of the same case
lives in `emit.mojo` under the same name, and the driver refuses to run if the
two sets of names disagree, so a case added to one side and forgotten on the
other is a failure rather than a silent gap in the comparison.

The path always starts `/s/<name>`, which is how the server knows which case a
connection belongs to. That means the path is part of what gets compared, which
is the point: a client that escaped it differently would be caught here.

Cases come in two kinds. A `request` case is about the bytes that go out, and
the reply is only there so the exchange can finish. A `response` case is about
what the client makes of an answer that was written by hand, so the reply is the
interesting half and the request is whatever is simplest.
"""

import json


def reply(
    status=200,
    reason="OK",
    body=b"ok",
    content_type="text/plain",
    extra=(),
    framing="length",
):
    """One canned answer, framed the way the case needs it.

    `framing` is spelled out rather than inferred because half the point of the
    response cases is to feed each framing to both clients and see whether they
    agree about where the body ended.
    """
    head = "HTTP/1.1 %d %s\r\n" % (status, reason)
    if content_type is not None:
        head += "Content-Type: %s\r\n" % content_type
    for name, value in extra:
        head += "%s: %s\r\n" % (name, value)

    if framing == "length":
        head += "Content-Length: %d\r\n" % len(body)
        tail = body
    elif framing == "chunked":
        head += "Transfer-Encoding: chunked\r\n"
        tail = b""
        # Deliberately several chunks. A client that only handles one chunk per
        # read passes the single chunk version and fails this.
        for at in range(0, len(body), 4):
            piece = body[at : at + 4]
            tail += b"%x\r\n" % len(piece) + piece + b"\r\n"
        tail += b"0\r\n\r\n"
    elif framing == "close":
        head += "Connection: close\r\n"
        tail = body
    elif framing == "none":
        tail = b""
    else:
        raise ValueError("unknown framing " + framing)

    return (head + "\r\n").encode("latin-1") + tail


# Every reply says `Connection: close` unless the case is about framing, so each
# request arrives on a connection of its own and the recording server never has
# to work out where one request ended and the next began. What goes out is
# unaffected, which is what this suite is comparing.
def _closing(payload):
    at = payload.index(b"\r\n")
    return payload[:at] + b"\r\nConnection: close" + payload[at:]


OK = _closing(reply())
NO_CONTENT = _closing(reply(204, "No Content", b"", None, framing="none"))

# A challenge with no `qop`, which is the RFC 2069 shape. Worth having because
# without `qop` there is no client nonce, so the digest a client computes is
# fully determined by the challenge and the credentials. That makes the second
# request comparable byte for byte, which the `qop=auth` case below can never be.
DIGEST_PLAIN = _closing(
    reply(
        401,
        "Unauthorized",
        b"no",
        extra=[
            (
                "WWW-Authenticate",
                'Digest realm="parity", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093"',
            )
        ],
    )
)

DIGEST_QOP = _closing(
    reply(
        401,
        "Unauthorized",
        b"no",
        extra=[
            (
                "WWW-Authenticate",
                'Digest realm="parity",'
                ' nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", qop="auth",'
                ' opaque="5ccc069c403ebaf9f0171e9517f40e41"',
            )
        ],
    )
)


def _redirect(status, reason, target):
    return _closing(
        reply(status, reason, b"go", extra=[("Location", target)])
    )


CASES = []


def case(name, kind, replies, send):
    CASES.append({"name": name, "kind": kind, "replies": replies, "send": send})


# The bytes that go out.


case(
    "get_plain",
    "request",
    [OK],
    lambda c, base: c.get(base + "/s/get_plain"),
)

case(
    "get_params",
    "request",
    [OK],
    lambda c, base: c.get(
        base + "/s/get_params",
        params={"q": "a b&c=d", "empty": "", "unicode": "héllo"},
    ),
)

case(
    "get_query_in_url",
    "request",
    [OK],
    lambda c, base: c.get(base + "/s/get_query_in_url?already=set&x=1"),
)

case(
    "get_path_needing_escapes",
    "request",
    [OK],
    lambda c, base: c.get(base + "/s/get_path_needing_escapes/a b/c%2Fd/é"),
)

case(
    "get_custom_headers",
    "request",
    [OK],
    lambda c, base: c.get(
        base + "/s/get_custom_headers",
        headers={"X-Marker": "here", "X-Empty": "", "Accept": "text/plain"},
    ),
)

case(
    "get_cookies",
    "request",
    [OK],
    lambda c, base: c.get(
        base + "/s/get_cookies", cookies={"a": "1", "b": "two"}
    ),
)

case(
    "post_json",
    "request",
    [OK],
    lambda c, base: c.post(
        base + "/s/post_json",
        json={"name": "widget", "n": 2, "on": True, "nil": None},
    ),
)

case(
    "post_json_unicode",
    "request",
    [OK],
    lambda c, base: c.post(
        base + "/s/post_json_unicode", json={"text": "héllo wörld"}
    ),
)

case(
    "post_form",
    "request",
    [OK],
    lambda c, base: c.post(
        base + "/s/post_form", data={"a": "1 2", "b": "x&y", "c": ""}
    ),
)

case(
    "post_text",
    "request",
    [OK],
    lambda c, base: c.post(base + "/s/post_text", content="plain text"),
)

case(
    "post_bytes",
    "request",
    [OK],
    lambda c, base: c.post(base + "/s/post_bytes", content=b"\x00\x01\xfe\xff"),
)

case(
    "post_empty",
    "request",
    [OK],
    lambda c, base: c.post(base + "/s/post_empty"),
)

case(
    "post_multipart",
    "request",
    [OK],
    lambda c, base: c.post(
        base + "/s/post_multipart",
        data={"field": "value"},
        files={"f": ("a.txt", b"hello", "text/plain")},
    ),
)

case(
    "put_json",
    "request",
    [OK],
    lambda c, base: c.put(base + "/s/put_json", json=[1, 2, 3]),
)

case(
    "patch_text",
    "request",
    [OK],
    lambda c, base: c.patch(base + "/s/patch_text", content="patched"),
)

case(
    "delete_plain",
    "request",
    [OK],
    lambda c, base: c.delete(base + "/s/delete_plain"),
)

case(
    "head_plain",
    "request",
    [OK],
    lambda c, base: c.head(base + "/s/head_plain"),
)

case(
    "options_plain",
    "request",
    [OK],
    lambda c, base: c.options(base + "/s/options_plain"),
)

case(
    "basic_auth",
    "request",
    [OK],
    lambda c, base: c.get(base + "/s/basic_auth", auth=("alice", "s3cret")),
)

case(
    "digest_auth_no_qop",
    "request",
    [DIGEST_PLAIN, OK],
    lambda c, base: c.get(
        base + "/s/digest_auth_no_qop",
        auth=__import__("httpx2").DigestAuth("alice", "s3cret"),
    ),
)

case(
    "digest_auth_qop",
    "request",
    [DIGEST_QOP, OK],
    lambda c, base: c.get(
        base + "/s/digest_auth_qop",
        auth=__import__("httpx2").DigestAuth("alice", "s3cret"),
    ),
)

# The second request is the one worth reading in each of these. What is being
# compared is what survives the hop: the method, the body, and the headers that
# should or should not be carried over.

case(
    "redirect_302_get",
    "request",
    [_redirect(302, "Found", "/s/redirect_302_get/next"), OK],
    lambda c, base: c.get(
        base + "/s/redirect_302_get", follow_redirects=True
    ),
)

case(
    "redirect_303_post_becomes_get",
    "request",
    [
        _redirect(303, "See Other", "/s/redirect_303_post_becomes_get/next"),
        OK,
    ],
    lambda c, base: c.post(
        base + "/s/redirect_303_post_becomes_get",
        json={"dropped": True},
        follow_redirects=True,
    ),
)

case(
    "redirect_307_keeps_body",
    "request",
    [
        _redirect(
            307, "Temporary Redirect", "/s/redirect_307_keeps_body/next"
        ),
        OK,
    ],
    lambda c, base: c.post(
        base + "/s/redirect_307_keeps_body",
        content="kept",
        follow_redirects=True,
    ),
)

case(
    "redirect_relative_target",
    "request",
    [_redirect(302, "Found", "../elsewhere?x=1"), OK],
    lambda c, base: c.get(
        base + "/s/redirect_relative_target/deep/here", follow_redirects=True
    ),
)

case(
    "cookie_from_response_is_sent_back",
    "request",
    [
        _closing(
            reply(
                302,
                "Found",
                b"go",
                extra=[
                    ("Set-Cookie", "session=abc; Path=/"),
                    (
                        "Location",
                        "/s/cookie_from_response_is_sent_back/next",
                    ),
                ],
            )
        ),
        OK,
    ],
    lambda c, base: c.get(
        base + "/s/cookie_from_response_is_sent_back", follow_redirects=True
    ),
)


# What the client makes of an answer.


def _get(name):
    return lambda c, base: c.get(base + "/s/" + name)


case(
    "resp_text_utf8",
    "response",
    [
        _closing(
            reply(
                body="héllo wörld".encode("utf-8"),
                content_type="text/plain; charset=utf-8",
            )
        )
    ],
    _get("resp_text_utf8"),
)

case(
    "resp_text_latin1",
    "response",
    [
        _closing(
            reply(
                body="héllo".encode("latin-1"),
                content_type="text/plain; charset=iso-8859-1",
            )
        )
    ],
    _get("resp_text_latin1"),
)

case(
    "resp_text_bom",
    "response",
    [
        _closing(
            reply(
                body=b"\xef\xbb\xbf" + "héllo".encode("utf-8"),
                content_type="text/plain",
            )
        )
    ],
    _get("resp_text_bom"),
)

case(
    "resp_json_no_charset",
    "response",
    [
        _closing(
            reply(
                body=json.dumps({"k": "v", "n": [1, 2]}).encode("utf-8"),
                content_type="application/json",
            )
        )
    ],
    _get("resp_json_no_charset"),
)

case(
    "resp_custom_reason",
    "response",
    [_closing(reply(418, "I am a teapot", b"short and stout"))],
    _get("resp_custom_reason"),
)

case(
    "resp_no_content",
    "response",
    [NO_CONTENT],
    _get("resp_no_content"),
)

case(
    "resp_chunked",
    "response",
    [
        _closing(
            reply(
                body=b"one two three four five", framing="chunked"
            )
        )
    ],
    _get("resp_chunked"),
)

case(
    "resp_closed_body",
    "response",
    [reply(body=b"until the socket ends", framing="close")],
    _get("resp_closed_body"),
)

case(
    "resp_repeated_headers",
    "response",
    [
        _closing(
            reply(
                extra=[
                    ("X-Repeated", "one"),
                    ("X-Repeated", "two"),
                    ("Set-Cookie", "a=1; Path=/"),
                    ("Set-Cookie", "b=2; Path=/"),
                ]
            )
        )
    ],
    _get("resp_repeated_headers"),
)

case(
    "resp_link_header",
    "response",
    [
        _closing(
            reply(
                extra=[
                    (
                        "Link",
                        '</s/page/2>; rel="next", </s/page/9>; rel="last"',
                    )
                ]
            )
        )
    ],
    _get("resp_link_header"),
)

case(
    "resp_empty_body_200",
    "response",
    [_closing(reply(body=b""))],
    _get("resp_empty_body_200"),
)


BY_NAME = {c["name"]: c for c in CASES}
