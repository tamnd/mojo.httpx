"""One HTTP/2 stream: its identifier, its state, and its two windows.

RFC 9113 section 5.1. The state machine is small and the reason to write it out
rather than infer it from flags is that almost every rule about what may arrive
is a rule about state. A `DATA` frame is not wrong in itself; it is wrong on a
stream that has already ended, and the only way to know that is to have been
keeping track.

This is written for a client, so the half the RFC gives to servers is not here.
We open every stream, the server never does, and the reserved states exist only
for push, which is refused at the connection before a stream is ever made for
it. What is left is the path a request actually takes: idle, open, closed on our
side when the request body ends, closed entirely when the response body does.

Identifiers get their own type because two of the milestone's bounds live there.
They must be odd, since we are the client, and they must only ever go up. A
server naming a stream we never opened is not a stream we should quietly create,
it is a server whose idea of the connection has diverged from ours, and creating
it would be inventing state to match.

The reset bound is here too, and it is a count of consecutive resets rather than
a rate. A rate needs a clock, which would make this untestable without one, and
the thing actually worth catching does not need one: a server that resets every
stream we open will do it consecutively, and a client that keeps opening new ones
in response is a client in a loop. One success clears it, so a server that resets
the occasional stream for its own reasons never trips it.
"""

from httpx._exceptions import ErrorKind, new_error
from httpx._proto.h2.frames import DEFAULT_WINDOW_SIZE
from httpx._proto.h2.window import ReceiveWindow, SendWindow

comptime MAX_STREAM_ID = 0x7FFFFFFF
"""The largest identifier the thirty one bit field can carry."""

comptime DEFAULT_MAX_CONSECUTIVE_RESETS = 32
"""How many streams a server may reset in a row before we stop opening them."""

comptime MAX_HEADER_BLOCKS = 10
"""How many header blocks one stream may carry.

Eight informational responses, then the real one, then trailers. The eight is
the same allowance the HTTP/1.1 side makes and for the same reason: there is no
legitimate run of interim responses that long, and with no bound at all a server
can send header blocks for as long as it likes, each one costing a decode and
each one a chance to grow the dynamic table.
"""


def _remote(message: String) -> Error:
    return new_error(ErrorKind.REMOTE_PROTOCOL_ERROR, message)


def _local(message: String) -> Error:
    return new_error(ErrorKind.LOCAL_PROTOCOL_ERROR, message)


struct StreamState(Equatable, ImplicitlyCopyable, Movable):
    """Where in its life one stream has got to."""

    var value: Int

    comptime IDLE = Self(0)
    """Made, and nothing sent on it yet."""

    comptime OPEN = Self(1)
    """Our headers are out. Both directions are live."""

    comptime HALF_CLOSED_LOCAL = Self(2)
    """We have finished sending. The usual state to wait for a response in."""

    comptime HALF_CLOSED_REMOTE = Self(3)
    """The server has finished sending and we have not.

    Reached when a server answers before the request body is done, which is
    normal for a rejection: there is no reason to read a large upload only to
    refuse it.
    """

    comptime CLOSED = Self(4)
    """Finished, reset, or abandoned. Nothing may arrive on it again."""

    def __init__(out self, value: Int):
        self.value = value

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value

    def name(self) -> StaticString:
        if self == Self.IDLE:
            return "idle"
        if self == Self.OPEN:
            return "open"
        if self == Self.HALF_CLOSED_LOCAL:
            return "half closed on our side"
        if self == Self.HALF_CLOSED_REMOTE:
            return "half closed on the server's side"
        return "closed"


struct StreamIds(ImplicitlyCopyable, Movable):
    """Which identifiers we have used, and which a server may name.

    RFC 9113 section 5.1.1. Client streams are odd, so `next` moves by two, and
    identifiers only ever go up: an identifier below the highest we have opened
    names a stream that is finished, and one above names a stream that does not
    exist.
    """

    var _next: UInt32
    var _highest: UInt32

    def __init__(out self):
        self._next = 1
        self._highest = 0

    def __init__(out self, first: UInt32):
        """Start somewhere other than the beginning.

        Only a test uses this. Running out of identifiers is a real branch with
        a real consequence, and reaching it by taking them one at a time is a
        billion calls, so the test starts near the end rather than leaving the
        branch unexercised.
        """
        self._next = first
        self._highest = 0

    def highest(self) -> UInt32:
        """The largest identifier we have opened. Zero before the first."""
        return self._highest

    def exhausted(self) -> Bool:
        """True when no identifier is left.

        Not an error on its own. RFC 9113 section 5.1.1 says a connection that
        runs out is simply finished, and the answer is a new connection rather
        than a failed request, so the pool asks this rather than being told.
        """
        return self._next > UInt32(MAX_STREAM_ID)

    def take(mut self) raises -> UInt32:
        """The next identifier for a stream we are opening."""
        if self.exhausted():
            raise _local(
                "this connection has used every stream identifier there is"
            )
        var id = self._next
        self._next += 2
        self._highest = id
        return id

    def check_named(self, id: UInt32) raises:
        """`PROTOCOL_ERROR`. Refuse an identifier a server should not be using.

        Even identifiers belong to the server, and the only way it gets one is
        a pushed stream, which we have turned off. An odd identifier above the
        highest we have opened is a stream that does not exist, and inventing it
        would be building state to match a server that has lost track.
        """
        if id == 0:
            raise _remote(
                "the server named stream zero where a stream was expected"
            )
        if id % 2 == 0:
            raise _remote(
                String(
                    "the server named stream ",
                    id,
                    ", and even numbered streams are ones it opened",
                )
            )
        if id > self._highest:
            raise _remote(
                String(
                    "the server named stream ",
                    id,
                    ", and we have only opened up to ",
                    self._highest,
                )
            )


struct ResetTracker(ImplicitlyCopyable, Movable):
    """How many streams the server has reset without one getting through.

    The client side of CVE-2023-44487. The attack itself is aimed at servers,
    but the mirror of it is a server that answers every stream with
    `RST_STREAM` and a client that keeps opening more, which is a loop that
    costs both sides and finishes nothing.
    """

    var _consecutive: Int
    var max_consecutive: Int

    def __init__(
        out self, max_consecutive: Int = DEFAULT_MAX_CONSECUTIVE_RESETS
    ):
        self._consecutive = 0
        self.max_consecutive = max_consecutive

    def consecutive(self) -> Int:
        return self._consecutive

    def record_reset(mut self) raises:
        self._consecutive += 1
        if self._consecutive > self.max_consecutive:
            raise _remote(
                String(
                    "the server reset ",
                    self._consecutive,
                    " streams in a row without answering one",
                )
            )

    def record_success(mut self):
        """A stream finished. Clears the count, so an occasional reset for the
        server's own reasons never accumulates into a refusal."""
        self._consecutive = 0


struct H2Stream(ImplicitlyCopyable, Movable):
    """One request and its response, and the flow control that goes with it."""

    var id: UInt32
    var state: StreamState
    var send: SendWindow
    var recv: ReceiveWindow

    var header_blocks: Int
    """How many header blocks have arrived on this stream.

    RFC 9113 section 8.1 has room for the response headers, then trailers, and
    before either of those any number of informational responses. Only the first
    two are meaningful to a caller, so the count is here to stop the third kind
    being unbounded rather than to enforce a shape: what the head and the
    trailers may be is a question for whoever reads them.
    """

    def __init__(
        out self,
        id: UInt32,
        send_window: Int = DEFAULT_WINDOW_SIZE,
        recv_window: Int = DEFAULT_WINDOW_SIZE,
    ):
        self.id = id
        self.state = StreamState.IDLE
        self.send = SendWindow(send_window)
        self.recv = ReceiveWindow(recv_window)
        self.header_blocks = 0

    def send_headers(mut self, end_stream: Bool) raises:
        """Our request head is going out."""
        if self.state != StreamState.IDLE:
            raise _local(
                String(
                    "tried to send a request on stream ",
                    self.id,
                    ", which is ",
                    self.state.name(),
                )
            )
        self.state = (
            StreamState.HALF_CLOSED_LOCAL if end_stream else StreamState.OPEN
        )

    def send_data(mut self, amount: Int, end_stream: Bool) raises:
        if self.state != StreamState.OPEN:
            raise _local(
                String(
                    "tried to send a request body on stream ",
                    self.id,
                    ", which is ",
                    self.state.name(),
                )
            )
        self.send.consume(amount)
        if end_stream:
            self.state = StreamState.HALF_CLOSED_LOCAL

    def recv_headers(mut self, end_stream: Bool) raises:
        """A response head or a set of trailers has arrived.

        `PROTOCOL_ERROR` on an idle stream, `STREAM_CLOSED` on a finished one.
        The distinction is RFC 9113 section 5.1 and it is not cosmetic: an idle
        stream means the server is answering something we never asked, and a
        closed one usually means an answer that crossed with our reset.
        """
        if self.state == StreamState.IDLE:
            raise _remote(
                String(
                    "the server sent a response on stream ",
                    self.id,
                    " before anything was asked on it",
                )
            )
        self._refuse_if_finished("a response")

        self.header_blocks += 1
        if self.header_blocks > MAX_HEADER_BLOCKS:
            raise _remote(
                String(
                    "the server sent ",
                    self.header_blocks,
                    " header blocks on stream ",
                    self.id,
                    ", which is more than a response can be made of",
                )
            )
        if end_stream:
            self._close_remote()

    def recv_data(mut self, amount: Int, end_stream: Bool) raises:
        """Response body octets, padding included.

        The window is charged before anything else, because the accounting has
        to happen whether or not we keep the octets. A frame on a stream that
        just closed still spent connection window at the sender, and a receiver
        that skipped it would drift out of step for the rest of the connection.
        """
        self.recv.record(amount)
        if self.state == StreamState.IDLE:
            raise _remote(
                String(
                    "the server sent body bytes on stream ",
                    self.id,
                    " before anything was asked on it",
                )
            )
        self._refuse_if_finished("body bytes")
        if end_stream:
            self._close_remote()

    def reset(mut self):
        """Either side gave up. Nothing may arrive on this stream again."""
        self.state = StreamState.CLOSED

    def _close_remote(mut self):
        if self.state == StreamState.HALF_CLOSED_LOCAL:
            self.state = StreamState.CLOSED
        else:
            self.state = StreamState.HALF_CLOSED_REMOTE

    def _refuse_if_finished(self, what: StaticString) raises:
        if (
            self.state == StreamState.CLOSED
            or self.state == StreamState.HALF_CLOSED_REMOTE
        ):
            raise _remote(
                String(
                    "the server sent ",
                    what,
                    " on stream ",
                    self.id,
                    ", which is ",
                    self.state.name(),
                )
            )
