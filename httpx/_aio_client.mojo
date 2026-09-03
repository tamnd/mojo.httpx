"""The async client, which is the ordinary client with the async transport in it.

There is no second implementation here. `AsyncClient` is `BaseClient` with
`AnyAsyncTransport` as its handle, so every behaviour a user knows from `Client`
is the same code and not a copy of it: the same header merge, the same base URL
resolution, the same cookie jar, the same event hooks, the same redirect chain
and the same auth loop. `httpx._client` explains why that was worth arranging.

## What is different, and it is less than it sounds

The requests go out through `httpx._pool.aio_pool`, so a request waiting on a
socket does not hold a runtime worker. On its own that buys nothing, because a
client sending one request at a time waits for it either way. It is what makes
sending several at once possible, and that arrives as `gather` rather than as
something the caller assembles, for the reason set out in
`httpx._transport.aio_base`: a coroutine cannot be stored or awaited by another
coroutine in Mojo 1.0.0, so it cannot be handed around by the caller.

Two things the async client cannot do yet, and both say so rather than doing
something else. `stream` raises, because a streamed response has to hold a
connection while the caller reads it a chunk at a time and there is nothing yet
that can drive that reading; the async iterators are where it lands. And an
`https://` URL raises, because there is no async TLS handshake, and sending in
the clear because the secure path is unfinished is not a thing this library will
do. A client given a mock transport streams normally, which is what most of the
streaming tests need.
"""

from httpx._client import BaseClient
from httpx._pool.limits import Limits
from httpx._stream.config import TlsConfig
from httpx._transport.aio_base import AnyAsyncTransport, erase_async_transport
from httpx._transport.aio_http import AsyncHTTPTransport


def _default_async_transport(
    var limits: Limits, var tls: TlsConfig
) raises -> AnyAsyncTransport:
    """The pool an async client gets when the caller named no transport.

    `tls` is dropped. Everything in it describes a handshake, and the async pool
    refuses an `https://` request before it would get as far as one, so there is
    nothing here for it to configure yet. It stays in the signature because the
    signature is shared with the synchronous client, and because this is where
    it starts being used the day the handshake exists.
    """
    return erase_async_transport(AsyncHTTPTransport(limits^))


comptime AsyncClient = BaseClient[AnyAsyncTransport, _default_async_transport]
"""The async client. See `BaseClient` for everything it can do."""
