"""Tests for the non blocking socket wrapper.

Everything here runs against a real loopback listener rather than a fake,
because the whole point of this layer is the behaviour of the kernel: short
writes, reads that return nothing yet, a connect that finishes later, and a peer
that goes away. A fake would only test the assumptions, which are the part most
likely to be wrong.

Both sides are driven from this loop. See tests/support/loopback.mojo for why.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._exceptions import (
    is_connect_error,
    is_connect_timeout,
    is_read_timeout,
)
from httpx._io.deadline import Deadline, connect_deadline, read_deadline
from httpx._io.socket import (
    TcpStream,
    finish_connect,
    open_stream,
    start_connect,
)

from tests.support.loopback import Loopback, dead_address


def _read_text(mut stream: TcpStream, count: Int) raises -> String:
    var buf = List[UInt8](length=count, fill=0)
    var n = stream.read(Span(buf), Deadline.after(5.0))
    return String(StringSpan(from_utf8=Span(buf)[:n]))


def test_a_connection_to_a_listener_succeeds() raises:
    var listener = Loopback()
    var stream = open_stream(listener.addr, "loopback", Deadline.after(5.0))
    assert_true(stream.is_open())
    var peer = listener.accept_within()
    assert_true(peer.fd() >= 0)


def test_a_connection_to_a_closed_port_is_refused() raises:
    # Refused rather than timed out. A test that cannot tell the two apart would
    # pass with the deadline handling completely broken.
    var addr = dead_address()
    var raised = False
    try:
        _ = open_stream(addr, "nothing here", Deadline.after(5.0))
    except e:
        raised = True
        assert_true(is_connect_error(e))
        assert_false(is_connect_timeout(e))
    assert_true(raised)


def test_a_request_written_by_the_client_arrives_at_the_server() raises:
    var listener = Loopback()
    var stream = open_stream(listener.addr, "loopback", Deadline.after(5.0))
    var peer = listener.accept_within()
    stream.write(
        "GET / HTTP/1.1\r\nHost: x\r\n\r\n".as_bytes(), Deadline.after(5.0)
    )
    assert_equal(
        peer.recv_until("\r\n\r\n"), "GET / HTTP/1.1\r\nHost: x\r\n\r\n"
    )


def test_a_response_written_by_the_server_arrives_at_the_client() raises:
    var listener = Loopback()
    var stream = open_stream(listener.addr, "loopback", Deadline.after(5.0))
    var peer = listener.accept_within()
    peer.send_text("HTTP/1.1 204 No Content\r\n\r\n")
    assert_equal(_read_text(stream, 64), "HTTP/1.1 204 No Content\r\n\r\n")


def test_a_read_waits_for_data_that_has_not_been_sent_yet() raises:
    # The socket is non blocking underneath, so this only works if the wrapper
    # is waiting on the descriptor rather than returning the empty read that
    # `recv` actually gave it. Getting this wrong turns every response into a
    # spin or into a truncation.
    var listener = Loopback()
    var stream = open_stream(listener.addr, "loopback", Deadline.after(5.0))
    var peer = listener.accept_within()
    assert_false(stream.has_data_waiting())
    peer.send_text("late")
    assert_equal(_read_text(stream, 16), "late")


def test_a_read_with_no_time_left_raises_a_read_timeout() raises:
    var listener = Loopback()
    var stream = open_stream(listener.addr, "loopback", Deadline.after(5.0))
    var peer = listener.accept_within()
    var buf = List[UInt8](length=16, fill=0)
    var raised = False
    try:
        _ = stream.read(Span(buf), read_deadline(Optional[Float64](0.05)))
    except e:
        raised = True
        assert_true(is_read_timeout(e))
    assert_true(raised)
    # The server side has to still be here. Mojo destroys a value after its last
    # use, so without this the accepted socket closes before the read and the
    # test measures an end of stream rather than a timeout.
    assert_true(peer.fd() >= 0)


def test_a_clean_close_by_the_peer_reads_as_end_of_stream() raises:
    # Zero bytes, not an error. Whether that is a valid end of message is the
    # parser's decision and depends on the framing, so this layer only reports
    # what happened.
    var listener = Loopback()
    var stream = open_stream(listener.addr, "loopback", Deadline.after(5.0))
    var peer = listener.accept_within()
    peer.send_text("bye")
    peer.close()
    assert_equal(_read_text(stream, 16), "bye")
    assert_equal(_read_text(stream, 16), "")


def test_a_closed_peer_is_noticed_without_consuming_anything() raises:
    # This is what the pool asks before reusing a connection. It has to be able
    # to tell "the server hung up" from "a response is waiting", and it must not
    # eat the response while finding out.
    var listener = Loopback()
    var stream = open_stream(listener.addr, "loopback", Deadline.after(5.0))
    var peer = listener.accept_within()
    assert_false(stream.is_closed_by_peer())
    peer.send_text("HTTP/1.1 200 OK\r\n")
    assert_false(stream.is_closed_by_peer())
    assert_equal(_read_text(stream, 64), "HTTP/1.1 200 OK\r\n")
    peer.close()
    assert_true(stream.is_closed_by_peer())


def test_a_large_write_completes_across_several_short_writes() raises:
    # More than any socket buffer will take at once, so `send` returns short and
    # the loop has to finish the job. A wrapper that trusted one `send` would
    # truncate every large request body and only on large ones.
    var listener = Loopback()
    var stream = open_stream(listener.addr, "loopback", Deadline.after(5.0))
    var peer = listener.accept_within()

    var body = String()
    for i in range(20000):
        body += String(i % 10)

    # The server has to drain while the client writes, because neither side has
    # a buffer big enough to hold all of it. That is the whole point of the
    # test, and it is also why this is the one place the loop is interleaved.
    var written = 0
    var seen = String()
    while written < body.byte_length():
        var end = written + 4096
        if end > body.byte_length():
            end = body.byte_length()
        stream.write(body.as_bytes()[written:end], Deadline.after(5.0))
        written = end
        while seen.byte_length() < written:
            seen += peer.recv_text(65536)
    assert_equal(seen.byte_length(), body.byte_length())
    assert_equal(seen, body)


def test_a_half_close_lets_the_server_see_the_end_of_the_request() raises:
    # A request body framed by connection close needs this. Closing outright
    # would throw away a response already on its way back.
    var listener = Loopback()
    var stream = open_stream(listener.addr, "loopback", Deadline.after(5.0))
    var peer = listener.accept_within()
    stream.write("body".as_bytes(), Deadline.after(5.0))
    stream.shutdown_write()
    assert_equal(peer.recv_until("body"), "body")
    assert_equal(peer.recv_text(), "")
    # Still readable from the client's side, which is what half close means.
    peer.send_text("HTTP/1.1 200 OK\r\n\r\n")
    assert_equal(_read_text(stream, 64), "HTTP/1.1 200 OK\r\n\r\n")


def test_closing_a_stream_twice_is_harmless() raises:
    # The descriptor is owned by exactly one stream, and the second close must
    # not hand back a number the kernel has already reused.
    var listener = Loopback()
    var stream = open_stream(listener.addr, "loopback", Deadline.after(5.0))
    _ = listener.accept_within()
    stream.close()
    assert_false(stream.is_open())
    stream.close()
    assert_false(stream.is_open())


def test_a_started_connect_can_be_finished_later() raises:
    # The split the connect race is built on. Starting must not block, and the
    # descriptor must survive being carried around before anybody waits on it.
    var listener = Loopback()
    var pending = start_connect(listener.addr, "loopback")
    assert_false(pending.failed)
    var stream = finish_connect(pending^, Deadline.after(5.0))
    assert_true(stream.is_open())
    _ = listener.accept_within()


def test_a_started_connect_to_a_dead_port_reports_the_failure() raises:
    # The failure may show up at `connect` or at the poll afterwards depending
    # on the platform, so the assertion is on what `finish_connect` raises
    # rather than on which of the two noticed.
    var pending = start_connect(dead_address(), "nothing here")
    var raised = False
    try:
        _ = finish_connect(pending^, Deadline.after(5.0))
    except e:
        raised = True
        assert_true(is_connect_error(e))
    assert_true(raised)


def test_a_connect_with_no_time_left_raises_a_connect_timeout() raises:
    # `connect_deadline` rather than `Deadline.after`, because the phase is what
    # decides the name of the error and a bare deadline is not a connect.
    var listener = Loopback()
    var raised = False
    try:
        _ = open_stream(
            listener.addr, "loopback", connect_deadline(Optional[Float64](0.0))
        )
    except e:
        raised = True
        assert_true(is_connect_timeout(e))
    assert_true(raised)
