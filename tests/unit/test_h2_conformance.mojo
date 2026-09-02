"""The cases the python-hyper h2 test suite makes, put to this client.

h2 is the HTTP/2 implementation everything in Python sits on, and its suite is
the closest thing there is to a shared reading of RFC 9113. It is Python test
code rather than a corpus, so there is nothing to vendor and nothing to check a
digest against: what is here is its cases rewritten, which is why each one says
what rule it is about rather than pointing at a file.

Not all of them apply. Most of that suite is about the server half of the
protocol, about h2's own event objects, and about the priority scheme RFC 9113
withdrew. What is left is the part a client can get wrong on its own: what makes
a received message malformed, what a client does with an informational response,
and whether a bad message costs one stream or the whole connection. Those are
here, along with the cases in the suite that exist to stop an implementation
passing by refusing everything.

The other half of this file is `httpx/_proto/h2/validate.mojo` tested directly.
The rules in it are per field and the driver tests are per message, so a driver
test that fails tells you a message was refused and a validate test tells you
which octet did it.
"""

from std.testing import assert_equal, assert_raises, assert_true

from httpx._bytes import Bytes
from httpx._io.deadline import Deadline
from httpx._io.socket import open_stream
from httpx._models.request import Request
from httpx._models.url import URL
from httpx._proto.h2.driver import H2Driver, MAX_INFORMATIONAL
from httpx._proto.h2.frames import (
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FRAME_HEADER_SIZE,
    FrameHeader,
    FrameType,
    PREFACE,
    parse_frame_header,
    write_frame_header,
)
from httpx._proto.h2.hpack import HpackEncoder
from httpx._proto.h2.table import HeaderField
from httpx._proto.h2.validate import (
    check_field,
    check_field_name,
    check_field_value,
    check_not_connection_specific,
)

from tests.support.loopback import Loopback, Peer


def _field(name: StringSpan, value: StringSpan) -> HeaderField:
    return HeaderField(String(name), String(value))


def _ok() -> List[HeaderField]:
    var fields = List[HeaderField]()
    fields.append(_field(":status", "200"))
    return fields^


def _status(code: StringSpan) -> List[HeaderField]:
    var fields = List[HeaderField]()
    fields.append(_field(":status", code))
    return fields^


def _encoded(var fields: List[HeaderField]) raises -> List[UInt8]:
    """One header block from an encoder with an empty table.

    Safe for a second block on the same connection because an encoder that has
    indexed nothing never names a dynamic entry, and the static table it does
    name is the same sixty one rows at both ends forever.
    """
    var encoder = HpackEncoder()
    var block = Bytes()
    encoder.encode(fields, block)
    return block.take_list()


def _headers_frame(
    var fields: List[HeaderField], end_stream: Bool
) raises -> List[UInt8]:
    var block = _encoded(fields^)
    var flags = FLAG_END_HEADERS
    if end_stream:
        flags |= FLAG_END_STREAM
    var out = Bytes()
    write_frame_header(
        FrameHeader(len(block), FrameType.HEADERS, flags, 1), out
    )
    out.extend(Span(block))
    return out.take_list()


def _data_frame(payload: StringSpan, end_stream: Bool) raises -> List[UInt8]:
    var bytes = payload.as_bytes()
    var flags = FLAG_END_STREAM if end_stream else UInt8(0)
    var out = Bytes()
    write_frame_header(FrameHeader(len(bytes), FrameType.DATA, flags, 1), out)
    out.extend(bytes)
    return out.take_list()


def _settings_frame() raises -> List[UInt8]:
    var out = Bytes()
    write_frame_header(FrameHeader(0, FrameType.SETTINGS, UInt8(0), 0), out)
    return out.take_list()


def _read_frame(mut peer: Peer) raises -> Tuple[FrameHeader, List[UInt8]]:
    var head = peer.recv_exactly(FRAME_HEADER_SIZE)
    if len(head) != FRAME_HEADER_SIZE:
        raise Error("the client did not send a whole frame header")
    var header = parse_frame_header(Span(head), 0)
    var payload = List[UInt8]()
    if header.length > 0:
        payload = peer.recv_exactly(header.length)
    return (header, payload^)


def _open(listener: Loopback) raises -> H2Driver:
    return H2Driver(open_stream(listener.addr, "loopback", Deadline.after(5.0)))


def _greet(mut peer: Peer) raises:
    """Take the preface, the client's settings and its request head.

    Everything the client sends before it starts reading, so a test that follows
    this can put its answer on the wire and know that what comes back next is a
    reaction to the answer and not to the handshake.
    """
    var expected = PREFACE.as_bytes()
    var seen = peer.recv_exactly(len(expected))
    if len(seen) != len(expected):
        raise Error("the client did not send the whole preface")
    while True:
        var read = _read_frame(peer)
        if read[0].type == FrameType.HEADERS:
            break
    peer.send_bytes(Span(_settings_frame()))


def _head_is_refused(var fields: List[HeaderField]) raises:
    """Answer a request with `fields` and require the client to refuse it."""
    var listener = Loopback()
    var driver = _open(listener)
    var peer = listener.accept_within()

    var request = Request("GET", URL("https://example.com/"))
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)

    peer.send_bytes(Span(_headers_frame(fields^, end_stream=True)))
    with assert_raises():
        _ = driver.start_response(Deadline.after(5.0))


def _head_is_accepted(var fields: List[HeaderField]) raises -> Int:
    """The other direction, returning the status so a test can check it.

    Half the cases in this file are acceptances and that is deliberate. A suite
    made only of refusals passes on a client that refuses every response there
    is, which is the one failure a refusal only suite cannot see.
    """
    var listener = Loopback()
    var driver = _open(listener)
    var peer = listener.accept_within()

    var request = Request("GET", URL("https://example.com/"))
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)

    peer.send_bytes(Span(_headers_frame(fields^, end_stream=True)))
    var head = driver.start_response(Deadline.after(5.0))
    return head.status_code


def test_h2_a_response_field_name_in_upper_case_is_malformed() raises:
    # RFC 9113 section 8.2.1. HTTP/1.1 field names are case insensitive and
    # HTTP/2 field names are lower case, so this is not a difference of style.
    var fields = _ok()
    fields.append(_field("Content-Type", "text/plain"))
    _head_is_refused(fields^)


def test_h2_a_response_field_name_in_lower_case_is_fine() raises:
    var fields = _ok()
    fields.append(_field("content-type", "text/plain"))
    assert_equal(_head_is_accepted(fields^), 200)


def test_h2_a_response_field_name_with_a_space_in_it_is_malformed() raises:
    var fields = _ok()
    fields.append(_field("content type", "text/plain"))
    _head_is_refused(fields^)


def test_h2_an_empty_response_field_name_is_malformed() raises:
    var fields = _ok()
    fields.append(_field("", "text/plain"))
    _head_is_refused(fields^)


def test_h2_a_response_field_value_with_a_newline_in_it_is_malformed() raises:
    # The header that becomes two headers the moment somebody writes the message
    # out as HTTP/1.1, which is response splitting.
    var fields = _ok()
    fields.append(_field("x-thing", "one\nx-injected: two"))
    _head_is_refused(fields^)


def test_h2_a_response_field_value_with_a_return_in_it_is_malformed() raises:
    var fields = _ok()
    fields.append(_field("x-thing", "one\rtwo"))
    _head_is_refused(fields^)


def test_h2_a_response_field_value_with_a_null_in_it_is_malformed() raises:
    var fields = _ok()
    fields.append(_field("x-thing", String("one\x00two")))
    _head_is_refused(fields^)


def test_h2_a_response_field_value_with_leading_space_is_malformed() raises:
    # HTTP/1.1 says the space is not part of the value and HTTP/2 says a value
    # with a space on it is not a value. Two hops that read the same octets
    # differently is where smuggling starts, so this is refused rather than
    # trimmed.
    var fields = _ok()
    fields.append(_field("content-length", " 0"))
    _head_is_refused(fields^)


def test_h2_a_response_field_value_with_trailing_tab_is_malformed() raises:
    var fields = _ok()
    fields.append(_field("x-thing", "value\t"))
    _head_is_refused(fields^)


def test_h2_a_response_field_value_with_an_inner_space_is_fine() raises:
    # The rule is about the ends of a value and nothing else. A client that
    # refused this would refuse most real responses.
    var fields = _ok()
    fields.append(_field("x-thing", "one two three"))
    assert_equal(_head_is_accepted(fields^), 200)


def test_h2_a_response_carrying_connection_is_malformed() raises:
    var fields = _ok()
    fields.append(_field("connection", "keep-alive"))
    _head_is_refused(fields^)


def test_h2_a_response_carrying_transfer_encoding_is_malformed() raises:
    # The clearest smuggling case in the section. It means nothing in HTTP/2,
    # where framing is the frame layer's job, and a gateway writing the message
    # back out as HTTP/1.1 could emit it and move where the next hop thinks the
    # message ends.
    var fields = _ok()
    fields.append(_field("transfer-encoding", "chunked"))
    _head_is_refused(fields^)


def test_h2_a_response_carrying_keep_alive_is_malformed() raises:
    var fields = _ok()
    fields.append(_field("keep-alive", "timeout=5"))
    _head_is_refused(fields^)


def test_h2_a_response_carrying_proxy_connection_is_malformed() raises:
    var fields = _ok()
    fields.append(_field("proxy-connection", "keep-alive"))
    _head_is_refused(fields^)


def test_h2_a_response_carrying_upgrade_is_malformed() raises:
    var fields = _ok()
    fields.append(_field("upgrade", "websocket"))
    _head_is_refused(fields^)


def test_h2_te_trailers_is_the_one_allowed_te() raises:
    var fields = _ok()
    fields.append(_field("te", "trailers"))
    assert_equal(_head_is_accepted(fields^), 200)


def test_h2_any_other_te_is_malformed() raises:
    var fields = _ok()
    fields.append(_field("te", "gzip"))
    _head_is_refused(fields^)


def test_h2_a_response_carrying_trailer_is_fine() raises:
    # Not one of the five section 8.2.2 names, and a client that refused it
    # would be refusing a message the specification allows. This client does not
    # send `trailer`, which is a separate decision about the sending side.
    var fields = _ok()
    fields.append(_field("trailer", "x-checksum"))
    assert_equal(_head_is_accepted(fields^), 200)


def test_h2_a_pseudo_header_in_upper_case_is_malformed() raises:
    var fields = List[HeaderField]()
    fields.append(_field(":Status", "200"))
    _head_is_refused(fields^)


def test_h2_a_malformed_head_costs_the_stream_and_not_the_connection() raises:
    # RFC 9113 section 8.1.1 makes a malformed message a stream error. The block
    # was decoded before it was judged, so both HPACK tables are still in step
    # and nothing on any other stream is in doubt.
    var listener = Loopback()
    var driver = _open(listener)
    var peer = listener.accept_within()

    var request = Request("GET", URL("https://example.com/"))
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)

    var fields = _ok()
    fields.append(_field("transfer-encoding", "chunked"))
    peer.send_bytes(Span(_headers_frame(fields^, end_stream=True)))

    with assert_raises():
        _ = driver.start_response(Deadline.after(5.0))

    var reset = False
    for _ in range(8):
        var read = _read_frame(peer)
        if read[0].type == FrameType.RST_STREAM:
            reset = True
            assert_equal(read[0].stream_id, 1)
            break
        if read[0].type == FrameType.GOAWAY:
            break
    assert_true(reset)
    assert_true(driver.is_idle())
    assert_true(driver.is_reusable())

    # Keeps the server end alive to here. Mojo ends a value's life at its last
    # use, so without this the peer would close during the loop above and the
    # connection would be unusable for a reason that has nothing to do with the
    # malformed response.
    assert_true(peer.fd() >= 0)


def test_h2_a_malformed_trailer_costs_the_stream_and_not_the_connection() raises:
    var listener = Loopback()
    var driver = _open(listener)
    var peer = listener.accept_within()

    var request = Request("GET", URL("https://example.com/"))
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)

    peer.send_bytes(Span(_headers_frame(_ok(), end_stream=False)))
    peer.send_bytes(Span(_data_frame("hi", end_stream=False)))

    var trailers = List[HeaderField]()
    trailers.append(_field("X-Checksum", "abc"))
    peer.send_bytes(Span(_headers_frame(trailers^, end_stream=True)))

    _ = driver.start_response(Deadline.after(5.0))
    assert_equal(len(driver.read_chunk(Deadline.after(5.0))), 2)
    with assert_raises():
        _ = driver.read_chunk(Deadline.after(5.0))
    assert_true(driver.is_reusable())
    assert_true(peer.fd() >= 0)


def test_h2_an_informational_response_is_read_and_dropped() raises:
    # RFC 9110 section 15.2. It arrives as an ordinary header block on the same
    # stream, so the only thing marking it as interim is its status code, and a
    # client that returned the first block it saw would hand the caller a 100
    # with no headers and no body.
    var listener = Loopback()
    var driver = _open(listener)
    var peer = listener.accept_within()

    var request = Request("GET", URL("https://example.com/"))
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)

    peer.send_bytes(Span(_headers_frame(_status("100"), end_stream=False)))
    var final = _status("200")
    final.append(_field("content-type", "text/plain"))
    peer.send_bytes(Span(_headers_frame(final^, end_stream=True)))

    var head = driver.start_response(Deadline.after(5.0))
    assert_equal(head.status_code, 200)
    assert_equal(head.headers["content-type"], "text/plain")


def test_h2_several_informational_responses_are_all_dropped() raises:
    var listener = Loopback()
    var driver = _open(listener)
    var peer = listener.accept_within()

    var request = Request("GET", URL("https://example.com/"))
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)

    for _ in range(3):
        peer.send_bytes(Span(_headers_frame(_status("103"), end_stream=False)))
    peer.send_bytes(Span(_headers_frame(_status("204"), end_stream=True)))

    assert_equal(driver.start_response(Deadline.after(5.0)).status_code, 204)


def test_h2_a_run_of_informational_responses_is_bounded() raises:
    # Without a bound a server that sends nothing else keeps a client reading
    # until its deadline, and every block costs a decode on the way past.
    var listener = Loopback()
    var driver = _open(listener)
    var peer = listener.accept_within()

    var request = Request("GET", URL("https://example.com/"))
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)

    for _ in range(MAX_INFORMATIONAL + 2):
        peer.send_bytes(Span(_headers_frame(_status("100"), end_stream=False)))

    with assert_raises():
        _ = driver.start_response(Deadline.after(5.0))


def test_h2_an_informational_response_that_ends_the_stream_is_refused() raises:
    # A server promising more and then stopping. Accepting it would hand the
    # caller a 100 as though it were an answer.
    var listener = Loopback()
    var driver = _open(listener)
    var peer = listener.accept_within()

    var request = Request("GET", URL("https://example.com/"))
    driver.send_request(request, Deadline.after(5.0))
    _greet(peer)

    peer.send_bytes(Span(_headers_frame(_status("100"), end_stream=True)))
    with assert_raises():
        _ = driver.start_response(Deadline.after(5.0))


def test_h2_a_field_name_may_hold_octets_a_token_may_not() raises:
    # RFC 9113 section 8.2.1 names three octet ranges and a colon is in none of
    # them, which is what lets a pseudo-header be a field name at all. The
    # narrower RFC 9110 token rule is enforced a layer up, where the message can
    # say what is wrong with the name.
    check_field_name(":status")
    check_field_name("content-type")
    check_field_name("x-thing")


def test_h2_a_field_name_may_not_hold_a_control_or_a_delete() raises:
    with assert_raises():
        check_field_name(String("x\x01thing"))
    with assert_raises():
        check_field_name(String("x\x7fthing"))


def test_h2_a_field_name_may_not_be_empty() raises:
    with assert_raises():
        check_field_name("")


def test_h2_every_upper_case_letter_is_caught_in_a_field_name() raises:
    # The whole range and not a sample, because a check written with a boundary
    # off by one still passes on the letter somebody happened to pick.
    for code in range(ord("A"), ord("Z") + 1):
        var name = String("x-", chr(code))
        var raised = False
        try:
            check_field_name(name)
        except:
            raised = True
        if not raised:
            raise Error(String("an upper case letter got through: ", name))


def test_h2_a_field_value_may_hold_most_things() raises:
    check_field_value("x-thing", "")
    check_field_value("x-thing", "one two")
    check_field_value("x-thing", "a\tb")
    check_field_value("x-thing", "punctuation: , ; = \" ' ()")


def test_h2_a_field_value_may_not_start_or_end_with_whitespace() raises:
    with assert_raises():
        check_field_value("x-thing", " one")
    with assert_raises():
        check_field_value("x-thing", "one ")
    with assert_raises():
        check_field_value("x-thing", "\tone")
    with assert_raises():
        check_field_value("x-thing", "one\t")


def test_h2_a_value_of_nothing_but_a_space_is_refused() raises:
    # The case a check written as "first octet and last octet" gets right by
    # accident and one written as "strip then compare" gets wrong.
    with assert_raises():
        check_field_value("x-thing", " ")


def test_h2_the_five_connection_specific_fields_are_all_refused() raises:
    with assert_raises():
        check_not_connection_specific("connection", "keep-alive")
    with assert_raises():
        check_not_connection_specific("proxy-connection", "keep-alive")
    with assert_raises():
        check_not_connection_specific("keep-alive", "timeout=5")
    with assert_raises():
        check_not_connection_specific("transfer-encoding", "chunked")
    with assert_raises():
        check_not_connection_specific("upgrade", "h2c")


def test_h2_te_is_compared_exactly() raises:
    check_not_connection_specific("te", "trailers")
    with assert_raises():
        check_not_connection_specific("te", "Trailers")
    with assert_raises():
        check_not_connection_specific("te", "trailers, deflate")
    with assert_raises():
        check_not_connection_specific("te", "")


def test_h2_check_field_does_all_three() raises:
    check_field("content-type", "text/plain")
    with assert_raises():
        check_field("Content-Type", "text/plain")
    with assert_raises():
        check_field("content-type", " text/plain")
    with assert_raises():
        check_field("connection", "close")
