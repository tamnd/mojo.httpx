"""One test per request smuggling shape, over a real socket.

The pieces below have their own unit tests and this file does not repeat them.
What it does is take each published way of making two HTTP implementations
disagree about where a message ends, put those exact bytes on a socket, and
check that the client stops instead of guessing. The value is in the list being
complete and in it being reviewable: somebody worried about a class of attack
should be able to find it here by name.

A smuggling bug does not look like a crash. It looks like a response that parses
cleanly and belongs to somebody else's request, which is why every case here
asserts a refusal rather than a particular parse, and why the cases at the end
assert that ordinary responses still work. A parser that rejected everything
would pass a suite made only of the first kind.
"""

from std.testing import assert_equal, assert_true

from httpx._exceptions import is_remote_protocol_error
from httpx._io.deadline import Deadline
from httpx._io.socket import open_stream
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._models.url import URL
from httpx._proto.h1.connection import H1Connection

from tests.support.loopback import Loopback


def _response_to(method: StringSpan, canned: StringSpan) raises -> Response:
    """Send one request, answer it with `canned`, hand back what was parsed."""
    var listener = Loopback()
    var conn = H1Connection(
        open_stream(listener.addr, "loopback", Deadline.after(5.0))
    )
    var peer = listener.accept_within()
    conn.send_request(
        Request(method, URL("http://example.com/")), Deadline.after(5.0)
    )
    _ = peer.recv_until("\r\n\r\n")
    peer.send_text(canned)
    return conn.read_response(Deadline.after(5.0))


def _refused(canned: StringSpan, method: StringSpan = "GET") raises:
    """`canned` has to be refused, and refused as the remote end's fault."""
    var raised = False
    try:
        _ = _response_to(method, canned)
    except e:
        raised = True
        assert_true(is_remote_protocol_error(e))
    assert_true(raised)


def test_smuggling_content_length_and_chunked_together() raises:
    # CL.TE, the classic. A front end that honours Content-Length and a back end
    # that honours Transfer-Encoding see two different messages in one stream.
    # RFC 9112 permits a recipient to drop one header and carry on, and that
    # permission is the whole attack, so this client drops the message instead.
    _refused(
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nTransfer-Encoding:"
        " chunked\r\n\r\n0\r\n\r\n"
    )


def test_smuggling_chunked_and_content_length_in_the_other_order() raises:
    # TE.CL. Same two headers, swapped, because a parser that took the first
    # framing header it saw would treat these two responses differently.
    _refused(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length:"
        " 5\r\n\r\n0\r\n\r\n"
    )


def test_smuggling_conflicting_content_lengths() raises:
    _refused(
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length:"
        " 6\r\n\r\nhello!"
    )


def test_smuggling_two_content_lengths_on_one_line() raises:
    # The same conflict spelled with a comma, which a parser that only looked
    # for repeated field lines would miss entirely.
    _refused("HTTP/1.1 200 OK\r\nContent-Length: 5, 6\r\n\r\nhello!")


def test_smuggling_a_content_length_padded_with_zeros() raises:
    # `05` and `5` are one number and two strings, and implementations differ on
    # which they compare. A response carrying both spellings looks consistent to
    # one hop and self contradictory to the next.
    _refused(
        "HTTP/1.1 200 OK\r\nContent-Length: 05\r\nContent-Length:"
        " 5\r\n\r\nhello"
    )


def test_smuggling_a_content_length_with_a_leading_plus() raises:
    _refused("HTTP/1.1 200 OK\r\nContent-Length: +5\r\n\r\nhello")


def test_smuggling_a_hexadecimal_content_length() raises:
    # Accepted as 16 by anything that calls a permissive integer parser, and as
    # an error by anything strict, which is a sixteen byte disagreement.
    _refused("HTTP/1.1 200 OK\r\nContent-Length: 0x10\r\n\r\nhello")


def test_smuggling_a_coding_underneath_the_chunking() raises:
    # This client never sends TE, so it never offered to accept gzip as a
    # transfer coding. A body it cannot undo is a body it would hand back wrong.
    _refused(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n"
    )


def test_smuggling_chunked_not_last_in_the_coding_list() raises:
    # Anything applied after chunked moves the chunk boundaries, so there is no
    # longer any way to find the end of the body.
    _refused(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked, gzip\r\n\r\n0\r\n\r\n"
    )


def test_smuggling_chunked_twice_across_two_field_lines() raises:
    # Chunks inside chunks. A parser that only read the last field line would
    # unwrap one layer and leave chunk headers sitting in the body, which is
    # where the smuggled request would be.
    _refused(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding:"
        " chunked\r\n\r\n0\r\n\r\n"
    )


def test_smuggling_an_unknown_transfer_coding() raises:
    _refused("HTTP/1.1 200 OK\r\nTransfer-Encoding: xchunked\r\n\r\n0\r\n\r\n")


def test_smuggling_whitespace_before_the_header_colon() raises:
    # A proxy that trims the space sees a Content-Length. A client that does not
    # sees a header name that is not a token. Two hops, two framings, and the
    # bytes in between belong to whoever sent them.
    _refused("HTTP/1.1 200 OK\r\nContent-Length : 5\r\n\r\nhello")


def test_smuggling_a_folded_header_line() raises:
    # Obsolete line folding, deprecated by RFC 9112 section 5.2. Accepting it
    # lets a header value contain what looks like another header, which is the
    # injection primitive that ends in a second Content-Length.
    _refused(
        "HTTP/1.1 200 OK\r\nX-Note: one\r\n Content-Length: 5\r\n\r\nhello"
    )


def test_smuggling_a_bare_carriage_return_inside_a_header_line() raises:
    # A lone CR is not a line ending anywhere in the grammar, and the parsers
    # that treat it as one do not agree with each other about where the line
    # ended.
    _refused("HTTP/1.1 200 OK\r\nX-Note: one\rContent-Length: 5\r\n\r\nhello")


def test_smuggling_a_control_character_in_the_reason_phrase() raises:
    # The phrase is copied into logs and terminals, so a control byte here is
    # log injection at the least, and on a hop that treats it as a terminator it
    # is response splitting.
    _refused("HTTP/1.1 200 O\x00K\r\nContent-Length: 0\r\n\r\n")


def test_smuggling_a_status_code_with_no_class() raises:
    # 000 has no class, so the framing rules would read it as informational and
    # therefore as having no body, while a hop that rejected the message
    # outright would carry on reading. The body is then whatever the attacker
    # put in it.
    _refused("HTTP/1.1 000 OK\r\nContent-Length: 5\r\n\r\nhello")


def test_smuggling_a_chunk_size_with_trailing_whitespace() raises:
    _refused(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5 \r\nhello\r\n0"
        "\r\n\r\n"
    )


def test_smuggling_a_bare_newline_in_the_chunk_framing() raises:
    # Here the fifth byte of a five byte chunk is the carriage return, so a
    # reader that accepted the bare newline as the end of the chunk would take
    # one byte of framing as body and stay in step with nobody.
    _refused(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhelo\r\n0"
        "\r\n\r\n"
    )


def test_smuggling_a_chunk_size_that_is_not_a_number() raises:
    _refused(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nhello\r\n0"
        "\r\n\r\n"
    )


def test_smuggling_a_chunk_longer_than_its_declared_size() raises:
    # What a size line and its data disagreeing looks like on the wire. A
    # decoder that resynchronised on the next CRLF would read the extra bytes as
    # the next chunk header, which is where the smuggled request goes.
    _refused(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello"
        " world\r\n0\r\n\r\n"
    )


def test_smuggling_framing_headers_on_a_head_response() raises:
    # A HEAD response describes a body it is not sending, so a parser that
    # stopped reading the framing headers because there was no body would accept
    # from HEAD exactly what it rejects from GET. Same bytes, two meanings, one
    # method apart.
    _refused(
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n",
        "HEAD",
    )


def test_smuggling_framing_headers_on_a_304() raises:
    _refused(
        "HTTP/1.1 304 Not Modified\r\nContent-Length: 5\r\nTransfer-Encoding:"
        " chunked\r\n\r\n"
    )


def test_a_trailer_cannot_reframe_a_body_that_has_already_been_read() raises:
    # Trailers arrive after the body, so they cannot have framed it. Keeping
    # them out of `headers` is what stops a trailing Content-Length answering a
    # question the head already answered.
    var response = _response_to(
        "GET",
        (
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello"
            "\r\n0\r\nContent-Length: 99\r\n\r\n"
        ),
    )
    assert_equal(response.status_code, 200)
    assert_equal(len(response.content()), 5)
    assert_true("content-length" not in response.headers)
    assert_equal(response.trailers["content-length"], "99")


def test_an_ordinary_response_is_still_accepted() raises:
    # The control. Without this the suite could pass by refusing everything.
    var response = _response_to(
        "GET", "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"
    )
    assert_equal(response.status_code, 200)
    assert_equal(response.text(), "hello")


def test_an_ordinary_chunked_response_is_still_accepted() raises:
    var response = _response_to(
        "GET",
        (
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello"
            "\r\n0\r\n\r\n"
        ),
    )
    assert_equal(response.text(), "hello")
