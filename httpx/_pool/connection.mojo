"""One type for the two protocols a pooled connection can speak.

The pool holds connections and runs exchanges on them, and until HTTP/2 landed
there was only one kind, so it held `H1Connection` directly. There are two now,
and the choice between them is made once per connection by ALPN during the TLS
handshake, so everything above this point wants a single type that answers the
same questions whichever protocol is underneath.

Same shape as `Stream` one layer down, and for the same reasons: a tagged union
spelled with two `Optional` fields, exactly one of which is filled. The set of
protocols is closed and small, the branch predicts perfectly because a
connection is one kind for its whole life, and the compiler can see through it
in a way it could not see through a pointer and a vtable.

The two state machines were written to the same surface, which is what makes
this a forwarding type and not an adapter. `H2Driver` grew `exchange`,
`send_request`, `start_response`, `read_chunk` and `take_trailers` with the same
signatures `H1Connection` already had, so there is nothing here that translates
one protocol's idea of a request into another's.
"""

from httpx._io.deadline import Deadline
from httpx._models.headers import Headers
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._proto.h1.connection import H1Connection
from httpx._proto.h1.head import ResponseHead
from httpx._proto.h1.writer import TargetForm
from httpx._proto.h2.driver import H2Driver
from httpx._stream.stream import Stream


def speaks_http2(alpn: String) -> Bool:
    """Whether a negotiated ALPN name means HTTP/2.

    Only the exact name `h2` counts. An empty answer covers both a plain
    connection and a TLS one where the server ignored the offer, and the older
    `h2c` and the draft names such as `h2-14` are not the same protocol as the
    one that shipped. Everything that is not `h2` is HTTP/1.1, which is the
    safe way round: guessing HTTP/1.1 against an HTTP/2 server produces a clear
    error on the first response, and guessing the other way produces a request
    the server reads as garbage.
    """
    return alpn == "h2"


struct Connection(Movable):
    """A connection to one origin, speaking whichever protocol was chosen.

    Non copyable, like both of the things it can hold, because both of them own
    a socket.
    """

    var _h1: Optional[H1Connection]
    var _h2: Optional[H2Driver]

    def __init__(out self, var stream: Stream) raises:
        """Wrap a fresh stream in the state machine ALPN asked for.

        The decision is made here and never revisited. A connection cannot
        change protocol after the handshake, so asking once and remembering the
        answer is not an optimisation, it is the shape of the thing.
        """
        var http2 = speaks_http2(stream.alpn_protocol())
        self = Self(stream^, http2)

    def __init__(out self, var stream: Stream, http2: Bool):
        """The same, but told rather than asked.

        The pool never uses this. It exists because HTTP/2 on a connection with
        no TLS on it has no way to be negotiated, which makes it the only way
        to drive the HTTP/2 side over a loopback socket in a test.
        """
        if http2:
            self._h1 = None
            self._h2 = Optional(H2Driver(stream^))
        else:
            self._h1 = Optional(H1Connection(stream^))
            self._h2 = None

    def is_http2(self) -> Bool:
        return self._h2.__bool__()

    def is_idle(self) -> Bool:
        if self._h2:
            return self._h2.value().is_idle()
        return self._h1.value().is_idle()

    def is_reusable(self) raises -> Bool:
        if self._h2:
            return self._h2.value().is_reusable()
        return self._h1.value().is_reusable()

    def close(mut self):
        if self._h2:
            self._h2.value().close()
            return
        self._h1.value().close()

    def take_trailers(mut self) -> Headers:
        if self._h2:
            return self._h2.value().take_trailers()
        return self._h1.value().take_trailers()

    def exchange(
        mut self,
        mut request: Request,
        write_at: Deadline,
        read_at: Deadline,
        form: TargetForm = TargetForm.ORIGIN,
    ) raises -> Response:
        if self._h2:
            return self._h2.value().exchange(request, write_at, read_at, form)
        return self._h1.value().exchange(request, write_at, read_at, form)

    def send_request(
        mut self,
        mut request: Request,
        deadline: Deadline,
        form: TargetForm = TargetForm.ORIGIN,
    ) raises:
        if self._h2:
            self._h2.value().send_request(request, deadline, form)
            return
        self._h1.value().send_request(request, deadline, form)

    def start_response(mut self, deadline: Deadline) raises -> ResponseHead:
        if self._h2:
            return self._h2.value().start_response(deadline)
        return self._h1.value().start_response(deadline)

    def read_chunk(mut self, deadline: Deadline) raises -> List[UInt8]:
        if self._h2:
            return self._h2.value().read_chunk(deadline)
        return self._h1.value().read_chunk(deadline)
