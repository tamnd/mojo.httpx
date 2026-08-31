"""A transport that answers out of a function instead of a socket.

The reason the transport boundary is worth having. A test that swaps this in
keeps the client's redirect following, auth, cookies and header handling, and
loses only the network, so what it exercises is the program rather than a
hand rolled imitation of it.

The handler is a thin function pointer, which means it cannot capture. Mojo 1.0
has no storable closures, so a handler that needs state has to read it from
somewhere both it and the test can see. Recording is provided here instead,
because wanting to look at what was sent is the common case and having to build
a place to put it every time would be tedious.
"""

from httpx._io.deadline import Deadlines
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._transport.base import Transport


struct MockTransport(Transport):
    """Answers every request by calling `handler`."""

    var handler: def(var Request) raises thin -> Response

    var requests: List[Request]
    """Every request handled, in order, so a test can assert on what was sent.

    Copies rather than the originals, because the handler is given the request
    and may take it apart. A recording that could be mutated by the code under
    test would be worth less than no recording at all.
    """

    def __init__(out self, handler: def(var Request) raises thin -> Response):
        self.handler = handler
        self.requests = List[Request]()

    def handle_request(
        mut self, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        """The deadlines are accepted and ignored.

        Nothing here can block, so there is nothing for a deadline to bound. A
        mock that timed out on request would be inventing a failure the code
        under test never asked for.
        """
        self.requests.append(request.copy())
        return self.handler(request^)

    def close(mut self):
        """Nothing to release. Kept so this is a transport like any other."""
        pass
