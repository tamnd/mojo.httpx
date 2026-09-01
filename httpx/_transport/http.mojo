"""The transport that actually talks to a server.

Thin on purpose. Everything hard about sending a request over a socket is in
the pool and the protocol layer below, and everything about what to send is in
the client above, so what is left here is the join: turn a request and a set of
deadlines into a response, and own the pool that makes the second request fast.

The pool is held through a shared handle rather than borrowed from somewhere
else. The transport is still the thing that decides when it is built and what
limits it has, but a streaming response holds a connection out of the pool for
as long as the caller keeps reading, so the pool has to outlive the transport if
the transport is dropped first. A handle says exactly that, and a borrow could
not.
"""

from std.memory import ArcPointer

from httpx._io.deadline import Deadlines
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._pool.limits import Limits
from httpx._pool.pool import ConnectionPool, SharedPool, stream_request
from httpx._stream.config import TlsConfig
from httpx._transport.base import Transport


struct HTTPTransport(Transport):
    """The default transport. A connection pool and nothing else, yet."""

    var pool: SharedPool

    def __init__(out self) raises:
        """The default limits, which is what nearly every caller wants.

        A separate constructor rather than a default argument because building
        the defaults validates them and so can raise, and Mojo will not call a
        raising function to fill in a default.
        """
        self.pool = SharedPool(ConnectionPool(Limits()))

    def __init__(
        out self, var limits: Limits, var tls: TlsConfig = TlsConfig()
    ) raises:
        self.pool = SharedPool(ConnectionPool(limits^, tls=tls^))

    def handle_request(
        mut self, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        return self.pool[].handle_request(request^, deadlines)

    def handle_stream(
        mut self, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        return stream_request(self.pool.copy(), request^, deadlines)

    def close(mut self):
        self.pool[].close()
