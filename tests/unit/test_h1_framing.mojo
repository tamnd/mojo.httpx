"""Tests for the body framing decision.

Every case in RFC 9112 section 6.3 gets a test that provokes it, in the order
the section lists them, and then the smuggling shapes get tests of their own.
The smuggling ones are the reason this file exists. A framing bug does not look
like a crash, it looks like a response that parses fine and belongs to somebody
else's request, so the only way to know the rules hold is to write down each one
that could be broken.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._exceptions import is_remote_protocol_error
from httpx._io.buffer import ByteBuffer
from httpx._proto.h1.framing import BodyMode, Framing, framing_for
from httpx._proto.h1.head import ResponseHead, parse_head


def _head(text: StringSpan) raises -> ResponseHead:
    var buf = ByteBuffer()
    buf.extend(text.as_bytes())
    var found = parse_head(buf)
    if not found:
        raise Error("the test fixture is not a complete head")
    return found.take()


def _framing(method: StringSpan, text: StringSpan) raises -> Framing:
    return framing_for(method, _head(text))


def _framing_rejected(method: StringSpan, text: StringSpan) raises:
    var raised = False
    try:
        _ = framing_for(method, _head(text))
    except e:
        raised = True
        assert_true(is_remote_protocol_error(e))
    assert_true(raised)


def test_a_head_response_has_no_body_even_with_a_content_length() raises:
    # Rule one, and the one that costs a hang rather than a wrong answer when it
    # is missing. A HEAD response describes the body it is not sending.
    var framing = _framing(
        "HEAD", "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n"
    )
    assert_true(framing.mode == BodyMode.NONE)
    assert_false(framing.has_body())


def test_a_head_response_has_no_body_even_when_chunked() raises:
    var framing = _framing(
        "HEAD", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
    )
    assert_true(framing.mode == BodyMode.NONE)


def test_the_method_is_matched_without_regard_to_case() raises:
    var framing = _framing(
        "head", "HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n"
    )
    assert_true(framing.mode == BodyMode.NONE)


def test_an_informational_response_has_no_body() raises:
    var framing = _framing(
        "GET", "HTTP/1.1 100 Continue\r\nContent-Length: 5\r\n\r\n"
    )
    assert_true(framing.mode == BodyMode.NONE)


def test_a_204_has_no_body() raises:
    var framing = _framing(
        "GET", "HTTP/1.1 204 No Content\r\nContent-Length: 5\r\n\r\n"
    )
    assert_true(framing.mode == BodyMode.NONE)


def test_a_304_has_no_body() raises:
    # And it does carry a Content-Length, describing the body the cached copy
    # has. Reading it would be waiting for a body the server said not to expect.
    var framing = _framing(
        "GET", "HTTP/1.1 304 Not Modified\r\nContent-Length: 4096\r\n\r\n"
    )
    assert_true(framing.mode == BodyMode.NONE)


def test_a_bodiless_response_is_still_judged_on_its_framing_headers() raises:
    # Having no body is not a reason to stop reading the headers that describe
    # one. A response that would be rejected after a GET has to be rejected
    # after a HEAD as well, or the same bytes mean two different things
    # depending on the method, which is the split smuggling is built out of.
    _framing_rejected(
        "HEAD",
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n",
    )
    _framing_rejected("HEAD", "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n")
    _framing_rejected(
        "GET",
        (
            "HTTP/1.1 304 Not Modified\r\nContent-Length:"
            " 5\r\nTransfer-Encoding: chunked\r\n\r\n"
        ),
    )
    _framing_rejected(
        "GET",
        "HTTP/1.1 204 No Content\r\nTransfer-Encoding: gzip\r\n\r\n",
    )


def test_a_205_does_have_a_body_slot() raises:
    # Only 204 and 304 are bodiless. 205 is next to 204 in the register and is
    # framed like anything else, which is the sort of thing an off by one in a
    # range check gets wrong.
    var framing = _framing(
        "GET", "HTTP/1.1 205 Reset Content\r\nContent-Length: 0\r\n\r\n"
    )
    assert_true(framing.mode == BodyMode.LENGTH)
    assert_equal(framing.length, 0)


def test_a_successful_connect_becomes_a_tunnel() raises:
    var framing = _framing(
        "CONNECT", "HTTP/1.1 200 Connection Established\r\n\r\n"
    )
    assert_true(framing.mode == BodyMode.TUNNEL)
    assert_false(framing.has_body())


def test_a_failed_connect_is_framed_like_any_other_response() raises:
    # The tunnel only exists on success. A 407 carries a body explaining what
    # credentials the proxy wanted, and it has to be readable.
    var framing = _framing(
        "CONNECT",
        (
            "HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length:"
            " 7\r\n\r\n"
        ),
    )
    assert_true(framing.mode == BodyMode.LENGTH)
    assert_equal(framing.length, 7)


def test_a_chunked_response_is_chunked() raises:
    var framing = _framing(
        "GET", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
    )
    assert_true(framing.mode == BodyMode.CHUNKED)


def test_chunked_is_matched_without_regard_to_case() raises:
    var framing = _framing(
        "GET", "HTTP/1.1 200 OK\r\nTransfer-Encoding: Chunked\r\n\r\n"
    )
    assert_true(framing.mode == BodyMode.CHUNKED)


def test_a_coding_under_the_chunking_is_rejected() raises:
    # The RFC allows this and a browser might unwrap it. This client cannot: it
    # never sends a `TE` header, so it never offered to accept `gzip` as a
    # transfer coding, and a body it cannot undo is a body it would hand back
    # wrong. h11 refuses it too, and being the lenient parser on a path is how
    # one message ends up framed two ways.
    _framing_rejected(
        "GET", "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n"
    )


def test_codings_split_across_two_field_lines_are_one_list() raises:
    # A sender may use commas or repeat the field, and the two spellings mean
    # the same thing. Chunked twice is chunks inside chunks, and a parser that
    # only looked at the last field line would see one `chunked`, unwrap one
    # layer, and leave chunk headers sitting in the body.
    _framing_rejected(
        "GET",
        (
            "HTTP/1.1 200 OK\r\nTransfer-Encoding:"
            " chunked\r\nTransfer-Encoding: chunked\r\n\r\n"
        ),
    )


def test_chunked_not_last_is_rejected() raises:
    # Anything applied after chunked moves the chunk boundaries, so there is no
    # longer any way to find the end of the body.
    _framing_rejected(
        "GET", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked, gzip\r\n\r\n"
    )


def test_a_transfer_encoding_without_chunked_is_rejected() raises:
    _framing_rejected(
        "GET", "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n"
    )


def test_an_identity_transfer_encoding_is_rejected() raises:
    # Identity was removed from the registry. A server sending it is old enough
    # that guessing what it meant is not safe.
    _framing_rejected(
        "GET", "HTTP/1.1 200 OK\r\nTransfer-Encoding: identity\r\n\r\n"
    )


def test_both_transfer_encoding_and_content_length_is_rejected() raises:
    # The CL.TE primitive. RFC 9112 lets a recipient drop the Content-Length and
    # carry on, and that permission is exactly what the attack relies on: the
    # proxy and the origin drop different ones.
    _framing_rejected(
        "GET",
        (
            "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nTransfer-Encoding:"
            " chunked\r\n\r\n"
        ),
    )


def test_the_order_of_the_two_framing_headers_does_not_matter() raises:
    _framing_rejected(
        "GET",
        (
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length:"
            " 5\r\n\r\n"
        ),
    )


def test_conflicting_content_lengths_are_rejected() raises:
    _framing_rejected(
        "GET",
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n",
    )


def test_conflicting_content_lengths_on_one_line_are_rejected() raises:
    _framing_rejected("GET", "HTTP/1.1 200 OK\r\nContent-Length: 5, 6\r\n\r\n")


def test_identical_duplicate_content_lengths_are_collapsed() raises:
    # A server that repeated itself, which RFC 9110 section 5.2 allows and which
    # says exactly one thing about where the body ends.
    var framing = _framing(
        "GET",
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\n",
    )
    assert_true(framing.mode == BodyMode.LENGTH)
    assert_equal(framing.length, 5)


def test_a_content_length_frames_that_many_bytes() raises:
    var framing = _framing(
        "GET", "HTTP/1.1 200 OK\r\nContent-Length: 42\r\n\r\n"
    )
    assert_true(framing.mode == BodyMode.LENGTH)
    assert_equal(framing.length, 42)
    assert_true(framing.has_body())
    assert_true(framing.is_self_delimiting())


def test_a_zero_content_length_is_a_body_of_no_bytes() raises:
    var framing = _framing(
        "GET", "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
    )
    assert_true(framing.mode == BodyMode.LENGTH)
    assert_equal(framing.length, 0)


def test_a_content_length_that_is_not_a_number_is_rejected() raises:
    _framing_rejected("GET", "HTTP/1.1 200 OK\r\nContent-Length: abc\r\n\r\n")


def test_a_negative_content_length_is_rejected() raises:
    _framing_rejected("GET", "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n")


def test_a_content_length_with_a_leading_plus_is_rejected() raises:
    # Accepted by some parsers, rejected by others, and a value two hops read
    # differently is a value that frames the body differently.
    _framing_rejected("GET", "HTTP/1.1 200 OK\r\nContent-Length: +5\r\n\r\n")


def test_a_content_length_padded_with_zeros_is_rejected() raises:
    # `05` and `5` are one number and two strings. This client compares the
    # numbers when it checks duplicates for agreement and h11 compares the
    # strings, so a server sending both spellings would look consistent to one
    # and self contradictory to the other. Refusing the padded spelling removes
    # the question rather than answering it.
    _framing_rejected("GET", "HTTP/1.1 200 OK\r\nContent-Length: 05\r\n\r\n")
    _framing_rejected(
        "GET",
        "HTTP/1.1 200 OK\r\nContent-Length: 05\r\nContent-Length: 5\r\n\r\n",
    )


def test_a_single_zero_content_length_is_still_a_number() raises:
    # The leading zero rule has to stop at one digit, because `0` is how every
    # server on earth says the body is empty.
    var framing = _framing(
        "GET", "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
    )
    assert_true(framing.mode == BodyMode.LENGTH)
    assert_equal(framing.length, 0)


def test_a_hex_looking_content_length_is_rejected() raises:
    _framing_rejected("GET", "HTTP/1.1 200 OK\r\nContent-Length: 0x5\r\n\r\n")


def test_an_empty_content_length_is_rejected() raises:
    _framing_rejected("GET", "HTTP/1.1 200 OK\r\nContent-Length:\r\n\r\n")


def test_a_response_with_no_framing_headers_reads_until_close() raises:
    var framing = _framing("GET", "HTTP/1.0 200 OK\r\n\r\n")
    assert_true(framing.mode == BodyMode.UNTIL_CLOSE)
    assert_true(framing.has_body())
    assert_false(framing.is_self_delimiting())
