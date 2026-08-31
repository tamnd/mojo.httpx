"""The transport that actually talks to a server.

Thin on purpose. Everything hard about sending a request over a socket is in
the pool and the protocol layer below, and everything about what to send is in
the client above, so what is left here is the join: turn a request and a set of
deadlines into a response, and own the pool that makes the second request fast.

The pool is owned rather than borrowed because ownership is what makes reuse
work. Two transports sharing a pool would be two limits over one set of
connections, and a transport that borrowed a pool would leave the question of
who closes it to whoever wired them together.
"""

from httpx._io.deadline import Deadlines
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._pool.limits import Limits
from httpx._pool.pool import ConnectionPool
from httpx._stream.config import TlsConfig
from httpx._transport.base import Transport


struct HTTPTransport(Transport):
    """The default transport. A connection pool and nothing else, yet."""

    var pool: ConnectionPool

    def __init__(out self) raises:
        """The default limits, which is what nearly every caller wants.

        A separate constructor rather than a default argument because building
        the defaults validates them and so can raise, and Mojo will not call a
        raising function to fill in a default.
        """
        self.pool = ConnectionPool(Limits())

    def __init__(
        out self, var limits: Limits, var tls: TlsConfig = TlsConfig()
    ) raises:
        self.pool = ConnectionPool(limits^, tls=tls^)

    def handle_request(
        mut self, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        return self.pool.handle_request(request^, deadlines)

    def close(mut self):
        self.pool.close()
