"""Turning what the caller passed into bytes and a content type.

This is the layer behind `content=`, `data=`, `files=` and `json=`. Each one
produces an `EncodedBody`: the bytes to send and the content type that describes
them, or an empty content type meaning the caller did not ask for one.

The split between deciding the bytes and deciding the headers is deliberate. The
content type is a property of the encoding and belongs here. Whether it actually
gets written, and whether the framing is `Content-Length` or `Transfer-Encoding`,
is the client's decision, because only the client knows what the caller passed in
`headers=` and whether an explicit type should win. So nothing here touches a
header block. It returns a value and the client applies it.

`content=` gets no content type on purpose, and this is the one place the answer
surprises people. Bytes with no further description are `application/octet-stream`
as far as HTTP is concerned, but guessing that on the caller's behalf would mean
a client that silently labels every hand built body, including the ones that are
already JSON or already form encoded. httpx2 sets nothing here and so does this,
which leaves the caller in charge of a header only the caller can get right.
"""

from httpx._bytes import Bytes
from httpx._content.multipart import (
    MultipartData,
    choose_boundary,
    render_multipart,
)
from httpx._models.json import Json
from httpx._models.url import QueryParams
from std.collections.string import StringSpan

comptime JSON_TYPE = StaticString("application/json")
comptime FORM_TYPE = StaticString("application/x-www-form-urlencoded")
comptime MULTIPART_TYPE = StaticString("multipart/form-data")


struct EncodedBody(Movable, Sized):
    """Bytes to send, and the content type that describes them.

    An empty `content_type` means this encoding has no opinion, not that the
    type is empty. The client reads it that way and leaves the header alone.
    """

    var content: Bytes
    var content_type: String

    def __init__(out self, var content: Bytes, content_type: StringSpan = ""):
        self.content = content^
        self.content_type = String(content_type)

    def copy(self) -> Self:
        return Self(self.content.copy(), self.content_type)

    def __len__(self) -> Int:
        """The byte length, which is what `Content-Length` gets."""
        return len(self.content)

    def has_content_type(self) -> Bool:
        return self.content_type != ""

    def to_string(self) raises -> String:
        """The body decoded as UTF-8. For tests and for debugging."""
        return self.content.to_string()


def encode_bytes(var content: Bytes) -> EncodedBody:
    """Raw bytes, exactly as given, with no content type.

    See the note at the top of this module for why no type is guessed.
    """
    return EncodedBody(content^)


def encode_text(text: StringSpan) -> EncodedBody:
    """Text as UTF-8, with no content type.

    UTF-8 and not the platform encoding, and not a choice the caller can change.
    A request body in any other encoding needs a `Content-Type` saying so, which
    means the caller is passing a charset anyway, which means they can encode
    the bytes themselves and pass those.
    """
    return EncodedBody(Bytes(text))


def encode_json(doc: Json) -> EncodedBody:
    """A JSON document, serialized compactly, as `application/json`.

    No charset parameter. `application/json` is defined to be UTF-8 and RFC 8259
    says the parameter is neither required nor defined, so adding it is noise
    that a strict server is entitled to reject.
    """
    return EncodedBody(Bytes(doc.to_bytes()), JSON_TYPE)


def encode_urlencoded(data: QueryParams) raises -> EncodedBody:
    """Form fields as `application/x-www-form-urlencoded`.

    The same encoder the query string uses, so a value containing `&` or `=`
    comes out escaped and cannot introduce a field that was not there. That is
    the entire security content of this function and it is why it delegates
    rather than writing pairs out by hand.
    """
    return EncodedBody(Bytes(data.encode()), FORM_TYPE)


def encode_multipart(data: MultipartData) raises -> EncodedBody:
    """Fields and files as `multipart/form-data`, with a fresh boundary.

    The boundary is drawn per call rather than per client or per process. Two
    requests sharing one means that anybody who saw the first knows the boundary
    of the second, and knowing the boundary is the whole of what an attacker
    needs to forge a part.
    """
    var boundary = choose_boundary(data)
    return encode_multipart_with(data, boundary)


def encode_multipart_with(
    data: MultipartData, boundary: StringSpan
) -> EncodedBody:
    """`encode_multipart` with the boundary chosen by the caller.

    Only for tests, which need a body they can write an exact expectation for.
    A caller who picks a boundary is responsible for it not appearing in the
    data, which is the check `choose_boundary` exists to do.
    """
    return EncodedBody(
        render_multipart(data, boundary),
        String(MULTIPART_TYPE, "; boundary=", boundary),
    )
