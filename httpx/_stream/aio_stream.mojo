"""One type for the two kinds of connection a coroutine can drive.

The async twin of `httpx._stream.stream`, and the same tagged union for the
same reason: the set of streams has two members, so a union the compiler can
see through beats a call through a vtable. What is different is the shape of
the calls. Nothing here waits. Every operation does as much as the socket
allows right now and says which way the socket has to move before it is worth
asking again, because the thing above it is a coroutine, and a coroutine that
suspends inside a loop cannot be awaited by another one. The waiting is one
level up, written out inline, in `httpx._proto.h1.aio` and
`httpx._pool.aio_pool`.

## Why the encrypted half is the synchronous `TlsStream`

There is no second TLS implementation and there is not going to be one.
`TlsStream` already keeps its socket non blocking and already talks to OpenSSL
by asking for one step at a time, because OpenSSL asks for more data by
returning `SSL_ERROR_WANT_READ` rather than by blocking. Its `try_handshake`,
`try_read` and `try_write` are exactly the steps a coroutine needs, and its
`read` and `write` are those steps with a `poll` between them. So the two paths
run the same handshake, the same certificate checks and the same record layer,
and the only thing that differs is who does the waiting.

That is also why an async https connection does not need memory BIOs. The
socket BIO only blocks when the descriptor does, and this one never does.

## The three ways a step can end

A count greater than zero moved that many bytes, and a zero from a read is the
end of the stream. `STREAM_AGAIN` means nothing moved and `want` says which way
the socket has to become ready first. `STREAM_BROKEN` means it failed and
`failure` words it.

Which way to wait has to be asked rather than assumed. A TLS read can want to
write and a TLS write can want to read, because renegotiation and post
handshake authentication send records in the direction opposite to the data. A
driver that polls for readability because it was reading works until the day a
server asks for a new key.

`errno` is dealt with here rather than being passed upwards. A retry after
`EINTR` is not a wait, so it happens inside the step, and a plain socket failure
is turned into an `Outcome` at the point where `errno` is still the one that was
just set. The drivers above see the same three answers whether the connection
is encrypted or not.
"""

from std.ffi import c_int

from httpx._exceptions import new_error
from httpx._ffi.c import errno
from httpx._ffi.errno import Op, _network_kind, interrupted, would_block
from httpx._ffi.openssl import SslCtx
from httpx._ffi.socket import POLLIN, POLLOUT
from httpx._io.aio import Outcome
from httpx._io.aio_socket import AsyncTcpStream
from httpx._io.socket import TcpStream
from httpx._stream.tls import TLS_AGAIN, TLS_BROKEN, TlsStream

comptime STREAM_AGAIN = TLS_AGAIN
"""Nothing moved. Wait for `want` and ask again.

The same number `TlsStream` uses, so that a step on an encrypted connection is
forwarded rather than translated.
"""

comptime STREAM_BROKEN = TLS_BROKEN
"""It failed, and `failure` is the sentence saying why."""


struct AsyncStream(Movable):
    """A connection a coroutine can drive, encrypted or not.

    Non copyable, like both of the things it can hold. Two copies would mean two
    owners of one descriptor, and the second close lands on whatever connection
    the number was reused for.

    Both fields exist at once and at most one of them is filled. A plain stream
    holds the socket in `_tcp`, and an encrypted one has handed that socket to
    `_tls` and left an empty stream behind.
    """

    var _tcp: AsyncTcpStream
    var _tls: Optional[TlsStream]

    var _want: Int16
    """Which way a plain socket has to move, after a step returned
    `STREAM_AGAIN`. The encrypted side keeps its own, because OpenSSL is what
    knows, so `want` asks whichever half is in use."""

    var _failure: Outcome
    """The failed syscall from a plain step, kept until `failure` words it.

    An `Outcome` rather than a finished `Error` because the message needs the
    peer name and the operation, and building it here would mean building a
    string on a path that has not decided to raise yet.
    """

    def __init__(out self, var tcp: AsyncTcpStream):
        self._tcp = tcp^
        self._tls = None
        self._want = POLLIN
        self._failure = Outcome(0)

    @staticmethod
    def detached() -> Self:
        """A stream with no descriptor, which every method treats as closed.

        For a caller that has to own the field before it owns the connection.
        See `AsyncTcpStream.detached`, which is where the shape comes from and
        why it exists.
        """
        return Self(AsyncTcpStream.detached())

    def adopt(mut self, var inner: TcpStream):
        """Put a connected socket into a detached stream, without TLS on it.

        An encrypted connection is this followed by `start_tls`, because the
        handshake needs a socket to run over and the pool has to hand the winner
        of the connect race somewhere first.
        """
        self.close()
        self._tls = None
        self._tcp.adopt(inner^)

    def start_tls(mut self, ctx: SslCtx, hostname: String, verify: Bool) raises:
        """Put a TLS session on the adopted socket, agreeing nothing yet.

        The handshake is the caller's to drive, one `try_handshake` at a time,
        because the only caller is inside a coroutine and the waiting between
        steps belongs to it. Until it says it is done, the connection has agreed
        nothing with the far end and reading from it reads a handshake record as
        though it were a body.
        """
        self._tls = Optional(
            TlsStream(self._tcp.take_inner(), ctx, hostname, verify)
        )

    def handshaking(self) -> Bool:
        """Whether a TLS session has been started and is not agreed yet."""
        if not self._tls:
            return False
        return not self._tls.value().is_established()

    def try_handshake(mut self) -> Int:
        """One step of the handshake, with no waiting.

        One on success, `STREAM_AGAIN` to wait for `want`, `STREAM_BROKEN` for a
        failure `failure` will word. A stream with no TLS on it is already as
        agreed as it is going to be, so it answers one.
        """
        if not self._tls:
            return 1
        return self._tls.value().try_handshake()

    def is_secure(self) -> Bool:
        """Whether there is TLS on this connection.

        The pool asks, so that it never hands a plain connection to a request
        for an https origin. See `Stream.is_secure`, which is the same question
        for the same reason.
        """
        return self._tls.__bool__()

    def fd(self) -> c_int:
        """The raw descriptor. Nothing outside this layer may close it."""
        if self._tls:
            return self._tls.value().fd()
        return self._tcp.fd()

    def peer(self) -> String:
        if self._tls:
            return self._tls.value().peer()
        return self._tcp.peer()

    def is_open(self) -> Bool:
        if self._tls:
            return self._tls.value().is_open()
        return self._tcp.is_open()

    def has_data_waiting(self) raises -> Bool:
        """Whether a read right now would return something. Does not wait."""
        if self._tls:
            return self._tls.value().has_data_waiting()
        return self._tcp.has_data_waiting()

    def is_closed_by_peer(self) raises -> Bool:
        """Whether the far end hung up on an idle connection. Does not wait."""
        if self._tls:
            return self._tls.value().is_closed_by_peer()
        return self._tcp.is_closed_by_peer()

    def alpn_protocol(self) raises -> String:
        """What ALPN settled on, or empty on a connection with no TLS."""
        if self._tls:
            return self._tls.value().alpn_protocol()
        return String()

    def want(self) -> Int16:
        """`POLLIN` or `POLLOUT`, after a step that returned `STREAM_AGAIN`."""
        if self._tls:
            return self._tls.value().want()
        return self._want

    def try_read[o: MutOrigin](mut self, buf: Span[UInt8, o]) -> Int:
        """Read what is there, with no waiting. See the module docstring.

        Zero is the end of the stream and not a failure. Whether that is a
        complete message depends on the framing, and the HTTP layer is what
        knows.
        """
        if self._tls:
            return self._tls.value().try_read(buf)
        while True:
            var n = self._tcp.try_read(buf)
            if n >= 0:
                return n
            var code = errno()
            if interrupted(code):
                # A signal, not a reason to go round the scheduler.
                continue
            if would_block(code):
                self._want = POLLIN
                return STREAM_AGAIN
            self._failure = Outcome.from_errno(code, Op.READ)
            return STREAM_BROKEN

    def try_write[
        o: ImmOrigin
    ](mut self, data: Span[UInt8, o], offset: Int = 0) -> Int:
        """Write what the socket will take from `offset` on, with no waiting.

        A short write is normal rather than an error, so the count that comes
        back is what went out and the caller keeps going. Treating it as all or
        nothing is how a large request body gets silently truncated.
        """
        if self._tls:
            return self._tls.value().try_write(data, offset)
        while True:
            var n = self._tcp.try_write(data, offset)
            if n > 0:
                return n
            var code = errno()
            if interrupted(code):
                continue
            if would_block(code):
                self._want = POLLOUT
                return STREAM_AGAIN
            self._failure = Outcome.from_errno(code, Op.WRITE)
            return STREAM_BROKEN

    def failure(self, op: Op) -> Error:
        """The reason the last step returned `STREAM_BROKEN`, worded.

        `op` is what the caller was doing, and it picks the kind of error as
        well as the wording, so the same broken pipe reads as a write error to a
        caller that was writing and a connect error to one that was still
        shaking hands.

        Built here rather than inside the step because a string has no business
        being on a path that has not decided to fail yet, and because the two
        halves word it from different material: a plain socket has an `errno`
        and an encrypted one has whatever OpenSSL said.
        """
        if self._tls:
            return new_error(_network_kind(op), self._tls.value().trouble())
        if not self._failure.failed():
            # Nothing recorded, which means a step came back neither having
            # moved anything nor having a reason. Not something the drivers can
            # produce, and saying so plainly beats reporting a failure that is
            # not there.
            return new_error(
                _network_kind(op),
                String(
                    "the connection to ",
                    self.peer(),
                    " reported neither progress nor a reason",
                ),
            )
        return new_error(
            self._failure.kind(),
            self._failure.message(_phrase(op, self.peer())),
        )

    def shutdown_write(mut self):
        """Send a FIN, leaving the socket readable."""
        if self._tls:
            self._tls.value().shutdown_write()
            return
        self._tcp.shutdown_write()

    def close(mut self):
        """Release the descriptor. Safe to call more than once."""
        if self._tls:
            self._tls.value().close()
            return
        self._tcp.close()


def _phrase(op: Op, peer: String) -> String:
    """What a failed syscall was trying to do, in the caller's terms.

    The same three wordings the synchronous path raises with, so that one
    failure reads identically whichever client hit it.
    """
    if op == Op.WRITE:
        return String("write to ", peer)
    if op == Op.CONNECT:
        return String("connect to ", peer)
    return String("read from ", peer)
