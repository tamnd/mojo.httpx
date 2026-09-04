"""The async transport that actually talks to a server.

Thin for the reason `httpx._transport.http` is thin: everything hard is in the
pool below and everything about what to send is in the client above, so what is
left here is the join. It owns the pool, and it holds it through a shared handle
so that the pool can outlive the transport, which it has to for a streaming
response that is still holding a connection out of it.

Every entry point blocks the calling thread until its work is done, which is not
a contradiction. The point of the async path is not that the caller's thread is
free, it is that a request waiting on a socket does not hold a worker. A hundred
requests through `handle_many` are a hundred coroutines on however many workers
the runtime has, and the thread that called it is one more thread waiting, not a
hundred.
"""

from httpx._io.deadline import Deadlines
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._pool.aio_pool import (
    AsyncConnectionPool,
    SharedAsyncPool,
    stream_request,
)
from httpx._pool.limits import Limits
from httpx._pool.proxy import Proxy
from httpx._stream.config import TlsConfig
from httpx._transport.aio_base import AsyncTransport


struct AsyncHTTPTransport(AsyncTransport):
    """The default async transport. An async connection pool and nothing else.

    http and https, both over HTTP/1.1. The handshake runs in the connect loop
    without holding a worker, which `httpx._pool.aio_pool` explains. What it
    will not do yet is reach a server through a proxy that needs a tunnel.

    ```mojo
    from httpx import AsyncClient, AsyncHTTPTransport, erase_async_transport


    def main() raises:
        var transport = erase_async_transport(AsyncHTTPTransport())
        with AsyncClient(transport=transport^) as client:
            print(client.get("https://example.com/").status_code)
    ```
    """

    var pool: SharedAsyncPool

    def __init__(out self) raises:
        """The default limits, which is what nearly every caller wants.

        A separate constructor rather than a default argument because building
        the defaults validates them and so can raise, and Mojo will not call a
        raising function to fill in a default.
        """
        self.pool = SharedAsyncPool(AsyncConnectionPool(Limits()))

    def __init__(
        out self,
        var limits: Limits,
        var tls: TlsConfig = TlsConfig(),
        var proxy: Optional[Proxy] = None,
    ) raises:
        """Limits, certificates, and a proxy to send everything through.

        The proxy belongs to the pool rather than to a request, so a transport
        built with one sends every request through it, the same as the
        synchronous transport does.
        """
        self.pool = SharedAsyncPool(
            AsyncConnectionPool(limits^, tls=tls^, proxy=proxy^)
        )

    def handle_request(
        mut self, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        return self.pool[].handle_request(request^, deadlines)

    def handle_many(
        mut self, var requests: List[Request], deadlines: Deadlines
    ) raises -> List[Response]:
        return self.pool[].handle_many(requests^, deadlines)

    def handle_stream(
        mut self, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        return stream_request(self.pool.copy(), request^, deadlines)

    def close(mut self):
        self.pool[].close()
