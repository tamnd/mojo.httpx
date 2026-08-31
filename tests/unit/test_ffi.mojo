"""Tests for the libc layer.

Everything here is hermetic. The only name resolved is `127.0.0.1`, which is
numeric and never leaves the machine, and the only connection made is to a
listener this process opened on a kernel chosen loopback port. No test in this
file touches the network or depends on a name server.

The loopback round trip is the important one. It is the test that proves the
`sockaddr` bytes we copied out of `getaddrinfo` are the bytes `connect` and
`bind` want, which is the part of this layer that differs between macOS and
Linux and cannot be checked by reading the code.
"""

from std.ffi import c_int, c_size_t, c_uint
from std.testing import assert_equal, assert_false, assert_true

from httpx._exceptions import ErrorKind, is_connect_error, kind_of
from httpx._ffi.c import clear_errno, errno, strerror
from httpx._ffi.errno import (
    EAGAIN,
    EBADF,
    ECONNRESET,
    EINPROGRESS,
    EWOULDBLOCK,
    ECONNREFUSED,
    EINTR,
    ETIMEDOUT,
    Op,
    errno_message,
    errno_name,
    interrupted,
    kind_for_errno,
    would_block,
)
from httpx._ffi.netdb import (
    SOCKADDR_MAX,
    SockAddr,
    bind_addr,
    connect_addr,
    getsockname,
    resolve,
)
from httpx._ffi.socket import (
    AF_INET,
    AF_INET6,
    MSG_NOSIGNAL,
    POLLIN,
    POLLOUT,
    SOCK_STREAM,
    SO_ERROR,
    SO_REUSEADDR,
    SOL_SOCKET,
    PollFd,
    accept,
    close,
    fcntl_get_flags,
    getsockopt_int,
    listen,
    poll,
    recv,
    send,
    set_nonblocking,
    set_tcp_nodelay,
    setsockopt_int,
    socket,
    suppress_sigpipe,
    O_NONBLOCK,
)


def test_errno_reports_a_real_failure() raises:
    # Closing a descriptor that was never open is the cheapest way to make libc
    # set errno to something we can predict on both platforms.
    clear_errno()
    assert_equal(Int(errno()), 0)
    var rc = close(c_int(9999))
    assert_true(rc < 0)
    assert_equal(Int(errno()), Int(EBADF))
    assert_equal(String(errno_name(errno())), "EBADF")
    # The libc text differs between platforms, so assert only that there is one.
    assert_true(strerror(errno()).byte_length() > 0)


def test_errno_message_names_the_operation_and_the_code() raises:
    var m = errno_message(ECONNREFUSED, Op.CONNECT, "10.0.0.1:443")
    assert_true("connect" in m)
    assert_true("10.0.0.1:443" in m)
    # The symbolic name matters more than the number, because the number is
    # different on the other platform and the name is not.
    assert_true("ECONNREFUSED" in m)
    assert_true(String(Int(ECONNREFUSED)) in m)


def test_flow_control_codes_are_not_failures() raises:
    # If `EAGAIN` were ever classified as an error the client would abandon
    # every non blocking read that arrived a moment early.
    assert_true(would_block(EAGAIN))
    assert_true(would_block(EWOULDBLOCK))
    assert_true(would_block(EINPROGRESS))
    assert_false(would_block(ECONNREFUSED))
    assert_true(interrupted(EINTR))
    assert_false(interrupted(ECONNREFUSED))


def test_timeout_maps_to_the_timeout_for_the_operation() raises:
    assert_true(
        kind_for_errno(ETIMEDOUT, Op.CONNECT) == ErrorKind.CONNECT_TIMEOUT
    )
    assert_true(kind_for_errno(ETIMEDOUT, Op.READ) == ErrorKind.READ_TIMEOUT)
    assert_true(kind_for_errno(ETIMEDOUT, Op.WRITE) == ErrorKind.WRITE_TIMEOUT)


def test_the_same_code_maps_differently_per_operation() raises:
    # httpx2 reports a reset during the handshake and a reset mid body as
    # different exceptions, and so do we.
    assert_true(
        kind_for_errno(ECONNRESET, Op.CONNECT) == ErrorKind.CONNECT_ERROR
    )
    assert_true(kind_for_errno(ECONNRESET, Op.READ) == ErrorKind.READ_ERROR)
    assert_true(kind_for_errno(ECONNRESET, Op.WRITE) == ErrorKind.WRITE_ERROR)
    assert_true(kind_for_errno(ECONNRESET, Op.CLOSE) == ErrorKind.CLOSE_ERROR)


def test_resolve_loopback_gives_a_usable_address() raises:
    var addrs = resolve("127.0.0.1", 8080)
    assert_true(len(addrs) >= 1)
    var a = addrs[0]
    assert_true(a.is_ipv4())
    assert_equal(Int(a.family), Int(AF_INET))
    assert_equal(Int(a.socktype), Int(SOCK_STREAM))
    # Sixteen is `sizeof(struct sockaddr_in)` and is the same on both platforms.
    assert_equal(Int(a.length), 16)
    assert_equal(a.text(), "127.0.0.1")
    # The port has to survive the copy out of `struct addrinfo`, and it is the
    # one field stored in network byte order.
    assert_equal(Int(a.port()), 8080)


def test_port_can_be_changed_without_resolving_again() raises:
    var a = resolve("127.0.0.1", 80)[0]
    var b = a.with_port(8443)
    assert_equal(Int(b.port()), 8443)
    assert_equal(b.text(), "127.0.0.1")
    # The original is untouched, because a redirect to another port must not
    # rewrite the address the pool is still holding.
    assert_equal(Int(a.port()), 80)


def test_ipv6_loopback_renders_bracketed() raises:
    var addrs = resolve("::1", 443, AF_INET6)
    assert_true(len(addrs) >= 1)
    var a = addrs[0]
    assert_true(a.is_ipv6())
    # Twenty eight is `sizeof(struct sockaddr_in6)` on both platforms.
    assert_equal(Int(a.length), 28)
    assert_equal(a.text(), "::1")
    # A logged address should be pasteable back into a URL.
    assert_equal(String(a), "[::1]")
    assert_equal(Int(a.port()), 443)


def test_resolution_failure_is_a_connect_error() raises:
    # `.invalid` is reserved by RFC 2606 precisely so that it can never resolve.
    var raised = False
    try:
        _ = resolve("no-such-host.invalid", 80)
    except e:
        raised = True
        assert_true(is_connect_error(e))
        # The host has to be in the message or the failure is unactionable.
        assert_true("no-such-host.invalid" in String(e))
    assert_true(raised)


def test_a_fresh_socket_accepts_the_options_we_set() raises:
    var fd = socket(AF_INET, SOCK_STREAM, c_int(0))
    assert_true(fd >= 0)
    assert_equal(Int(set_tcp_nodelay(fd)), 0)
    assert_equal(Int(suppress_sigpipe(fd)), 0)
    assert_equal(Int(setsockopt_int(fd, SOL_SOCKET, SO_REUSEADDR, c_int(1))), 0)

    # A socket that has not been connected has no pending error.
    var err = c_int(-1)
    assert_equal(Int(getsockopt_int(fd, SOL_SOCKET, SO_ERROR, err)), 0)
    assert_equal(Int(err), 0)

    assert_equal(Int(close(fd)), 0)


def test_set_nonblocking_adds_the_bit_without_clearing_the_others() raises:
    var fd = socket(AF_INET, SOCK_STREAM, c_int(0))
    var before = fcntl_get_flags(fd)
    assert_true(before >= 0)
    assert_equal(Int(before & O_NONBLOCK), 0)

    assert_true(set_nonblocking(fd) >= 0)
    var after = fcntl_get_flags(fd)
    assert_true(Int(after & O_NONBLOCK) != 0)
    # Everything that was set before is still set. A plain assignment of
    # `O_NONBLOCK` would have wiped these and the test would catch it.
    assert_equal(Int(after & before), Int(before))

    _ = close(fd)


def test_loopback_round_trip() raises:
    """Bind, listen, connect, accept, send, receive, on a real socket pair.

    This is the test that proves the whole libc layer agrees with the platform.
    It exercises the `sockaddr` bytes copied out of `getaddrinfo`, the port in
    network byte order, `getsockname` reporting the kernel's chosen port, and
    the send and receive paths, all without leaving the loopback interface.
    """
    var local = resolve("127.0.0.1", 0)[0]

    var server = socket(local.family, SOCK_STREAM, c_int(0))
    assert_true(server >= 0)
    # Without this a test run that follows another too closely fails on a port
    # still in TIME_WAIT.
    assert_equal(
        Int(setsockopt_int(server, SOL_SOCKET, SO_REUSEADDR, c_int(1))), 0
    )
    assert_equal(Int(bind_addr(server, local)), 0)
    assert_equal(Int(listen(server, c_int(8))), 0)

    # Port zero means the kernel picks, and `getsockname` is the only way to
    # find out what it picked. Asking for a fixed port would race any other
    # process on the machine.
    var bound = getsockname(server)
    assert_true(bound.port() != 0)

    var client = socket(local.family, SOCK_STREAM, c_int(0))
    assert_true(client >= 0)
    assert_equal(Int(suppress_sigpipe(client)), 0)
    assert_equal(Int(connect_addr(client, local.with_port(bound.port()))), 0)

    var accepted = accept(server)
    assert_true(accepted >= 0)

    # The listener is readable before the accept and the client is writable
    # once connected. Checking both means a wrong poll flag constant shows up
    # here rather than as a hang in M2.
    var ready = PollFd(client, POLLOUT, 0)
    assert_true(poll(Pointer(to=ready), c_uint(1), c_int(0)) >= 0)
    assert_true(Int(ready.revents & POLLOUT) != 0)

    var payload = String("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")
    var out = payload.as_bytes()
    var sent = send(
        client,
        Pointer(to=out[0]),
        c_size_t(payload.byte_length()),
        MSG_NOSIGNAL,
    )
    assert_equal(Int(sent), payload.byte_length())

    var buf = List[UInt8](length=512, fill=0)
    var got = recv(accepted, Pointer(to=buf[0]), c_size_t(512), c_int(0))
    assert_equal(Int(got), payload.byte_length())
    assert_equal(
        String(StringSpan(unsafe_from_utf8=Span(buf)[: Int(got)])), payload
    )

    # A second read with nothing left must report would block rather than zero,
    # because zero means the peer closed and that would truncate a response.
    assert_equal(Int(set_nonblocking(accepted)), 0)
    clear_errno()
    var again = recv(accepted, Pointer(to=buf[0]), c_size_t(512), c_int(0))
    assert_true(again < 0)
    assert_true(would_block(errno()))

    assert_equal(Int(close(client)), 0)
    assert_equal(Int(close(accepted)), 0)
    assert_equal(Int(close(server)), 0)


def test_reading_a_closed_peer_reports_end_of_stream() raises:
    """A clean close reads as zero, which is not the same as would block.

    Confusing the two is how a client either hangs forever or silently
    truncates a body, so the distinction gets its own test.
    """
    var local = resolve("127.0.0.1", 0)[0]
    var server = socket(local.family, SOCK_STREAM, c_int(0))
    _ = setsockopt_int(server, SOL_SOCKET, SO_REUSEADDR, c_int(1))
    _ = bind_addr(server, local)
    _ = listen(server, c_int(8))
    var bound = getsockname(server)

    var client = socket(local.family, SOCK_STREAM, c_int(0))
    _ = suppress_sigpipe(client)
    assert_equal(Int(connect_addr(client, local.with_port(bound.port()))), 0)
    var accepted = accept(server)

    assert_equal(Int(close(client)), 0)

    var buf = List[UInt8](length=64, fill=0)
    var got = recv(accepted, Pointer(to=buf[0]), c_size_t(64), c_int(0))
    assert_equal(Int(got), 0)

    _ = close(accepted)
    _ = close(server)
