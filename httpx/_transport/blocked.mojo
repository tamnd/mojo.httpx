"""A transport that refuses everything it is given.

Mounted on a pattern, it turns that pattern into a wall: `mounts.mount("http://",
blocked())` is a client that will not send a plaintext request, and one that says
so at the call rather than at the socket.

It is a transport rather than a flag on `Mounts` because a mount already means
"send matching requests here", and refusing is a thing to send them to. That also
makes it composable in the way everything else here is: a caller who wants a
different message, or wants to count what was refused, writes their own
`Transport` and mounts that instead, and nothing in the client had to leave room
for the idea.

`Mounts.bypass` is the other empty looking option and is not this one. Bypassing
sends the request to the client's own transport, which is how a host is carved
out of a wider proxy rule. Blocking sends it nowhere. httpx spells bypass as a
`None` in the `mounts` dict and has no spelling at all for blocking, which is why
this file exists.
"""

from httpx._exceptions import ErrorKind, new_error
from httpx._io.deadline import Deadlines
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._transport.aio_base import AnyAsyncTransport, AsyncTransport
from httpx._transport.aio_base import erase_async_transport
from httpx._transport.base import AnyTransport, Transport, erase_transport


struct BlockedTransport(AsyncTransport, Transport):
    """Raises for every request, and holds nothing.

    One struct for both clients. The two transport traits differ only by
    `handle_many`, and a transport that never sends anything has the same
    nothing to do in either.

    ```mojo
    from httpx import BlockedTransport, Client, erase_transport


    def main() raises:
        var transport = erase_transport(BlockedTransport("no network in tests"))
        with Client(transport=transport^) as client:
            try:
                print(client.get("https://example.com/").status_code)
            except e:
                print(e)
    ```
    """

    var reason: String
    """What the error says after naming the URL, or empty for the default."""

    def __init__(out self, reason: StringSpan = ""):
        self.reason = String(reason)

    def handle_request(
        mut self, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        raise self._refusal(request)

    def handle_stream(
        mut self, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        return self.handle_request(request^, deadlines)

    def handle_many(
        mut self, var requests: List[Request], deadlines: Deadlines
    ) raises -> List[Response]:
        # The first one, which is the rule `gather` follows for any failure in a
        # round. Nothing was sent, so there is nothing to unwind.
        while len(requests) > 0:
            raise self._refusal(requests.pop(0))
        return List[Response]()

    def close(mut self):
        pass

    def _refusal(self, request: Request) -> Error:
        var said = self.reason.copy()
        if said == "":
            said = String("it is blocked by a mount on this client")
        return new_error(
            ErrorKind.UNSUPPORTED_PROTOCOL,
            String(
                "the request to ", request.url, " was not sent, because ", said
            ),
        )


def blocked(reason: StringSpan = "") -> AnyTransport:
    """A blocking transport for a `Client`, ready to be mounted.

    `reason` finishes the sentence "the request to URL was not sent, because
    ...", so a caller who is blocking for a reason of their own can say what it
    was rather than leaving the next reader to find the mount.
    """
    return erase_transport(BlockedTransport(reason))


def async_blocked(reason: StringSpan = "") -> AnyAsyncTransport:
    """A blocking transport for an `AsyncClient`. See `blocked`."""
    return erase_async_transport(BlockedTransport(reason))
