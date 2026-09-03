"""The async transport that actually talks to a server.

Thin for the reason `httpx._transport.http` is thin: everything hard is in the
pool below and everything about what to send is in the client above, so what is
left here is the join. It owns the pool, and it holds it through a shared handle
so that the pool can outlive the transport once there is an async streaming
response to hold a connection out of it.

Both entry points block the calling thread until their work is done, which is
not a contradiction. The point of the async path is not that the caller's thread
is free, it is that a request waiting on a socket does not hold a worker. A
hundred requests through `handle_many` are a hundred coroutines on however many
workers the runtime has, and the thread that called it is one more thread
waiting, not a hundred.
"""

from httpx._io.deadline import Deadlines
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._pool.aio_pool import AsyncConnectionPool, SharedAsyncPool
from httpx._pool.limits import Limits
from httpx._transport.aio_base import AsyncTransport


struct AsyncHTTPTransport(AsyncTransport):
    """The default async transport. An async connection pool and nothing else.

    http only for now. The pool refuses an https request with a message saying
    so rather than sending it in the clear, because there is no async TLS
    handshake yet. See `httpx._pool.aio_pool`.
    """

    var pool: SharedAsyncPool

    def __init__(out self) raises:
        """The default limits, which is what nearly every caller wants.

        A separate constructor rather than a default argument because building
        the defaults validates them and so can raise, and Mojo will not call a
        raising function to fill in a default.
        """
        self.pool = SharedAsyncPool(AsyncConnectionPool(Limits()))

    def __init__(out self, var limits: Limits) raises:
        self.pool = SharedAsyncPool(AsyncConnectionPool(limits^))

    def handle_request(
        mut self, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        return self.pool[].handle_request(request^, deadlines)

    def handle_many(
        mut self, var requests: List[Request], deadlines: Deadlines
    ) raises -> List[Response]:
        return self.pool[].handle_many(requests^, deadlines)

    def close(mut self):
        self.pool[].close()
