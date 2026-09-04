"""The boundary a user can replace.

A transport takes a request that is already finished, sends it somewhere, and
hands back a response. It does not follow redirects, it does not add auth, and
it does not touch the cookie jar. All of that is the client's work, above here,
and keeping it above here is what makes a test double useful: swapping the
transport under a client leaves every one of those behaviours in place, so what
the test exercises is the program rather than a rewritten version of it.

`AnyTransport` is what a client holds. It is a vtable of thin function pointers
over an `ErasedBox`, because Mojo 1.0 has no trait objects and a field has one
type. `erase_transport` turns any conforming transport into one. The cost is an
indirect call per request, which is nothing next to the syscalls on the other
side of it, and the return is that a user can write their own transport and
pass it in like they would in httpx.

The generic path stays available for anyone who wants the call inlined. A
client parameterised on a concrete transport type is monomorphised and never
touches this file.
"""

from httpx._io.deadline import Deadlines
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._transport.handle import TransportHandle
from httpx._util.erase import ErasedBox


trait Transport(Movable):
    """What a transport has to be able to do.

    The deadlines are an argument rather than something the transport reads off
    the request, because a transport that cannot see the deadline cannot honour
    it, and the four way timeout is the promise this library is built around.
    httpx hides it in an untyped extensions map, which makes the one guarantee
    users care about depend on a string key being spelled right.

    ```mojo
    from httpx import Client, Deadlines, Request, Response, Transport
    from httpx import erase_transport


    struct Canned(Movable, Transport):
        def __init__(out self):
            pass

        def handle_request(
            mut self, var request: Request, deadlines: Deadlines
        ) raises -> Response:
            return Response(200, content=List[UInt8](String("ok").as_bytes()))

        def handle_stream(
            mut self, var request: Request, deadlines: Deadlines
        ) raises -> Response:
            return self.handle_request(request^, deadlines)

        def close(mut self):
            pass


    def main() raises:
        with Client(transport=erase_transport(Canned())) as client:
            print(client.get("https://example.com/").text())
    ```
    """

    def handle_request(
        mut self, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        ...

    def handle_stream(
        mut self, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        """The same, but return as soon as the head has been read.

        Two methods rather than a flag on one, because the two differ in what
        they own when they return. `handle_request` is finished with the
        connection; `handle_stream` has handed it to the response and cannot
        touch it again. A transport with nothing to stream from, such as a mock,
        answers both the same way and loses nothing by it.
        """
        ...

    def close(mut self):
        """Release everything held, such as pooled connections.

        Does not raise. There is nothing a caller can do about a close that
        failed, and a close that can fail turns every cleanup path into another
        error path.
        """
        ...


struct AnyTransport(TransportHandle):
    """A transport whose type has been forgotten, ready to be stored.

    ```mojo
    from httpx import AnyTransport, Client, HTTPTransport, blocked
    from httpx import erase_transport


    def main() raises:
        var offline = False
        var transport = erase_transport(HTTPTransport())
        if offline:
            transport = blocked("no network in this run")
        with Client(transport=transport^) as client:
            print(client.get("https://example.com/").status_code)
    ```
    """

    var _state: ErasedBox
    var _handle_request: def(
        ErasedBox, var Request, Deadlines
    ) raises thin -> Response
    var _handle_stream: def(
        ErasedBox, var Request, Deadlines
    ) raises thin -> Response
    var _close: def(ErasedBox) thin -> None

    def __init__(
        out self,
        var state: ErasedBox,
        handle_request: def(
            ErasedBox, var Request, Deadlines
        ) raises thin -> Response,
        handle_stream: def(
            ErasedBox, var Request, Deadlines
        ) raises thin -> Response,
        close: def(ErasedBox) thin -> None,
    ):
        self._state = state^
        self._handle_request = handle_request
        self._handle_stream = handle_stream
        self._close = close

    def copy(self) -> Self:
        """Another handle on the same transport, sharing its connection pool.

        Explicit because Mojo 1.0 does not run a written copy hook for an
        implicit copy, and a silent bitwise copy of the handle would leave the
        reference count behind.
        """
        return Self(
            self._state.copy(),
            self._handle_request,
            self._handle_stream,
            self._close,
        )

    def state[T: Transport & Deinitable](self) -> ref[MutAnyOrigin] T:
        """The transport back again, as the type it was before it was erased.

        For a test that hands a `MockRouter` to a client and then wants to know
        what was sent. Take a `copy()` before handing it over and read the
        recording back through the copy, which is the same transport.

        Asking for a type other than the one that went in is undefined, which is
        the one sharp edge of erasure and the reason this is spelled out rather
        than hidden behind a property.
        """
        return self._state.get[T]()

    def handle_request(
        mut self, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        return self._handle_request(self._state, request^, deadlines)

    def handle_stream(
        mut self, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        return self._handle_stream(self._state, request^, deadlines)

    def close(mut self):
        self._close(self._state)


def erase_transport[
    T: Transport & Deinitable
](var transport: T) -> AnyTransport:
    """Box `transport` and build the vtable that reaches back into it.

    The trampolines capture nothing. They recover the concrete type from `T`,
    which is a compile time parameter, so each one is an ordinary function with
    a nameable type rather than a closure. That is the whole reason this works
    in Mojo 1.0.
    """

    def _handle_request(
        state: ErasedBox, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        return state.get[T]().handle_request(request^, deadlines)

    def _handle_stream(
        state: ErasedBox, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        return state.get[T]().handle_stream(request^, deadlines)

    def _close(state: ErasedBox) -> None:
        state.get[T]().close()

    return AnyTransport(
        ErasedBox.make[T](transport^), _handle_request, _handle_stream, _close
    )
