"""Deciding where a response body ends.

This is the whole of request smuggling in one function. A smuggling attack is
two HTTP implementations disagreeing about where one message stops and the next
one starts, and every such disagreement traces back to a message that gave two
answers to that question and to a parser that picked one instead of refusing.

So the rule here is that ambiguity is an error. RFC 9112 section 6.3 lets a
recipient recover from some of these by ignoring one of the two answers, and a
proxy that has to keep the internet working may need that latitude. A client
does not. A client that has been sent a response with both a `Content-Length`
and a `Transfer-Encoding` has been sent something no correct server produces,
and the useful thing to do about it is stop.

The order of the checks is not a style choice. It is the precedence the RFC
lays down and it is load bearing: `HEAD` before everything, because a `HEAD`
response carries the headers of the body it is not sending, and a client that
read the `Content-Length` would sit waiting for bytes that are never coming.
"""

from httpx._bytes import equal_ascii_ci, parse_decimal, trim_ows
from httpx._exceptions import ErrorKind, new_error
from httpx._models.headers import Headers
from httpx._proto.h1.head import ResponseHead


struct BodyMode(Equatable, ImplicitlyCopyable, Movable):
    """How the end of a body is recognised, if there is one at all."""

    var value: Int

    comptime NONE = Self(0)
    """There is no body, whatever the headers say."""

    comptime LENGTH = Self(1)
    """Exactly `length` bytes."""

    comptime CHUNKED = Self(2)
    """Chunks until the terminal one."""

    comptime UNTIL_CLOSE = Self(3)
    """Until the server closes the connection.

    The HTTP/1.0 way, and the reason a response framed like this cannot leave
    the connection reusable: there is no way to tell a complete body from a
    truncated one, and no way to know the next byte is a new message.
    """

    comptime TUNNEL = Self(4)
    """The connection stops being HTTP and becomes a pipe. `CONNECT` only."""

    def __init__(out self, value: Int):
        self.value = value

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value


struct Framing(ImplicitlyCopyable, Movable):
    """The decision, and the length when the decision needs one."""

    var mode: BodyMode
    var length: Int
    """Meaningful only for `LENGTH`. Zero otherwise."""

    def __init__(out self, mode: BodyMode, length: Int = 0):
        self.mode = mode
        self.length = length

    def has_body(self) -> Bool:
        return self.mode != BodyMode.NONE and self.mode != BodyMode.TUNNEL

    def is_self_delimiting(self) -> Bool:
        """Whether the end of the body can be recognised without a close.

        The connection can only be reused when this holds, so it is the same
        question as whether reading this response leaves the connection worth
        keeping.
        """
        return self.mode != BodyMode.UNTIL_CLOSE


def _remote(message: String) -> Error:
    return new_error(ErrorKind.REMOTE_PROTOCOL_ERROR, message)


def framing_for(method: StringSpan, head: ResponseHead) raises -> Framing:
    """How to read the body of `head`, given the method that asked for it.

    The method is a parameter because framing is not a property of the response
    alone. The same bytes mean a body after `GET` and no body after `HEAD`, and
    a parser that only looked at the response would hang on every `HEAD`.
    """
    # 1. No body, whatever the headers say. A `HEAD` response describes a body
    # it is not sending, and 204 and 304 are defined as having none. Reading a
    # `Content-Length` here is how a client ends up waiting on a body the server
    # already told it was not coming.
    if equal_ascii_ci(method.as_bytes(), "HEAD".as_bytes()):
        return Framing(BodyMode.NONE)
    if head.status_code < 200 or head.status_code == 204:
        return Framing(BodyMode.NONE)
    if head.status_code == 304:
        return Framing(BodyMode.NONE)

    # 2. A successful `CONNECT` stops the HTTP framing entirely: everything
    # after the head belongs to whatever is being tunnelled.
    if (
        equal_ascii_ci(method.as_bytes(), "CONNECT".as_bytes())
        and head.status_code >= 200
        and head.status_code < 300
    ):
        return Framing(BodyMode.TUNNEL)

    var chunked = _transfer_encoding_is_chunked(head.headers)
    var length = _content_length(head.headers)

    # Both. RFC 9112 allows a recipient to drop the `Content-Length` and carry
    # on, and this is exactly the shape a CL.TE desync takes: the attacker is
    # counting on the proxy and the origin dropping different ones. Checked
    # before the chunked case rather than after it, because after it the check
    # would never run on the combination that matters.
    if chunked and length:
        raise _remote(
            "the server sent both Transfer-Encoding and Content-Length"
        )

    # 3 and 4. `chunked` has to be the last coding, because anything applied
    # after it would change where the chunks are, and then nobody can find the
    # end of the body.
    if head.headers.__contains__("transfer-encoding"):
        if not chunked:
            raise _remote(
                "the server sent a Transfer-Encoding that does not end with"
                " chunked"
            )
        return Framing(BodyMode.CHUNKED)

    # 5 through 7.
    if length:
        return Framing(BodyMode.LENGTH, length.value())

    # 8. Nothing said how long the body is, so it lasts until the connection
    # does. Legal, and the reason `is_self_delimiting` exists.
    return Framing(BodyMode.UNTIL_CLOSE)


def _transfer_encoding_is_chunked(headers: Headers) raises -> Bool:
    """Whether the final transfer coding is `chunked`.

    A sender may split the list across several field lines or put it on one with
    commas, and both mean the same thing, so the codings are gathered before the
    last one is looked at.
    """
    var codings = headers.get_list("transfer-encoding", split_commas=True)
    var last = -1
    for i in range(len(codings)):
        # An empty element comes from a trailing or doubled comma. Skipping it
        # is not leniency about the framing, only about the punctuation.
        if codings[i].byte_length() > 0:
            last = i
    if last < 0:
        return False
    return equal_ascii_ci(codings[last].as_bytes(), "chunked".as_bytes())


def _content_length(headers: Headers) raises -> Optional[Int]:
    """The declared body length, with every ambiguous spelling refused.

    Two different values is the other half of the smuggling surface: whichever
    one this picked, some other implementation on the path would pick the other.
    Two identical values are merely a server that repeated itself, which is
    allowed by RFC 9110 section 5.2 and means what it says.
    """
    var values = headers.get_list("content-length", split_commas=True)
    if len(values) == 0:
        return None

    var first = parse_content_length(values[0].as_bytes())
    for i in range(1, len(values)):
        if parse_content_length(values[i].as_bytes()) != first:
            raise _remote("the server sent conflicting Content-Length values")
    return Optional[Int](first)


def parse_content_length[o: ImmOrigin](text: Span[UInt8, o]) raises -> Int:
    """One `Content-Length` value as a number.

    Strict on purpose. A leading plus, a leading zero run, whitespace inside, a
    hex prefix: every one of those is a spelling that some parsers accept and
    others reject, and a value two implementations read differently is a value
    that frames the body differently.
    """
    var trimmed = trim_ows(text)
    if trimmed.__len__() == 0:
        raise _remote("the server sent an empty Content-Length")
    try:
        var value = parse_decimal(trimmed)
        return value
    except:
        raise _remote("the server sent a Content-Length that is not a number")
