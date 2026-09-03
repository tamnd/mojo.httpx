"""What a client needs from whatever transport it was given.

`Transport` and `AsyncTransport` are the two things a user can write. This is
the smaller thing a client can hold, and it exists so that there is one client
rather than two.

The two transports do not have the same methods, which is why they are two
traits. But the parts a client uses are the same three calls: send this and
give me the answer, send this and give me the head, and let go of everything
you are holding. Redirects, auth, cookies, event hooks, the header merge and
the base URL resolution are all written against those three and nothing else,
so a client parameterised on this trait is the whole of `Client` and the whole
of `AsyncClient` at once. The alternative was `_client.mojo` copied into
`_aio_client.mojo` with the transport type changed, eight hundred lines that
would then have to be kept in step by hand for the rest of the project.

`handle_many` is deliberately not here. A batch is only meaningful for a
transport with something to overlap, and the synchronous one has nothing: it
would be a loop, and a caller can write a loop. So concurrency is reached
through `AnyAsyncTransport` directly, by the free functions in
`httpx._aio_client` that only exist for the async client.

Building the default transport is not here either, for the opposite reason.
Which concrete transport a client falls back to when the caller named none is a
decision belonging to the client, not to the boundary, so it arrives as a
compile time function parameter alongside the handle type. That also keeps this
package free of a dependency on `httpx._transport.http`, which depends on it.
"""

from httpx._io.deadline import Deadlines
from httpx._models.request import Request
from httpx._models.response import Response


trait TransportHandle(Deinitable, Movable):
    """The three calls a client makes on the transport it holds.

    Both `AnyTransport` and `AnyAsyncTransport` conform, and nothing else needs
    to. A user writing their own transport writes `Transport` or
    `AsyncTransport` and gets this by way of the erasure.
    """

    def handle_request(
        mut self, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        ...

    def handle_stream(
        mut self, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        ...

    def close(mut self):
        ...
