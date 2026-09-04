"""The boundary a user can replace, for the async client.

The same idea as `httpx._transport.base` and deliberately the same shape: a
transport takes a finished request, sends it somewhere and hands back a
response, and everything above it stays the client's work so that swapping the
transport under a client leaves redirects, auth and cookies in place.

It is a second trait rather than an extra method on the first one because the
two do not have the same methods. This one has `handle_many` and the
synchronous one never will, since a transport with nothing to wait for has
nothing to overlap. The parts a client actually uses are common to both and are
spelled out in `httpx._transport.handle`, which is what lets one client serve
as `Client` and `AsyncClient` rather than the second being a copy of the first.

## Why concurrency is a method rather than something the caller does

`handle_many` looks like it belongs above the transport: take a list of
requests, start one task each, wait for all of them. In Mojo 1.0.0 it cannot
live there. A request is driven by a coroutine that suspends inside a loop, and
such a coroutine can only be handed to `_run` or to `TaskGroup.create_task`,
never awaited by another coroutine. So the group and the tasks have to be in the
same function as the thing that knows how to run one request, which is the
transport. `httpx._io.aio` has the whole list of what coroutines here can and
cannot do.

That is why the vtable has three entries instead of two. Concurrency crosses the
erasure boundary as a call taking a list, because it cannot cross it as a
coroutine: a `Coroutine` is a linear type, so it cannot be stored, returned
through a function pointer, or held in a field.

## What a transport that is not the real one has to do

`handle_many` on a transport with no network under it, such as a mock, is a loop
over `handle_request`. That is a correct implementation and not a placeholder:
the promise is that the requests all get sent and the responses come back in the
order the requests went in, not that anything overlaps. Only a transport with
something to wait for has anything to gain from overlapping.
"""

from httpx._io.deadline import Deadlines
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._transport.handle import TransportHandle
from httpx._util.erase import ErasedBox


trait AsyncTransport(Movable):
    """What an async transport has to be able to do.

    The deadlines are an argument for the reason they are one on `Transport`: a
    transport that cannot see the deadline cannot honour it.

    ```mojo
    from httpx import AsyncClient, AsyncTransport, Deadlines, Request, Response
    from httpx import erase_async_transport


    struct Canned(AsyncTransport, Movable):
        def __init__(out self):
            pass

        def handle_request(
            mut self, var request: Request, deadlines: Deadlines
        ) raises -> Response:
            return Response(200)

        def handle_stream(
            mut self, var request: Request, deadlines: Deadlines
        ) raises -> Response:
            return Response(200)

        def handle_many(
            mut self, var requests: List[Request], deadlines: Deadlines
        ) raises -> List[Response]:
            var out = List[Response]()
            for _ in range(len(requests)):
                out.append(Response(200))
            return out^

        def close(mut self):
            pass


    def main() raises:
        with AsyncClient(transport=erase_async_transport(Canned())) as client:
            print(client.get("https://example.com/").status_code)
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

        The response that comes back holds a connection out of the pool until
        the body has been read or the response is closed, and the reading is
        driven by the caller a chunk at a time. `httpx._pool.aio_pool` explains
        how that is done without anywhere to keep a suspended coroutine.
        """
        ...

    def handle_many(
        mut self, var requests: List[Request], deadlines: Deadlines
    ) raises -> List[Response]:
        """Send all of them at once, and answer in the order they came in.

        The first failure is raised and the other responses are dropped, which
        is what `asyncio.gather` does by default. Every request is still run to
        the end first, so nothing is left holding a connection.
        """
        ...

    def close(mut self):
        """Release everything held, such as pooled connections.

        Does not raise, for the reason `Transport.close` does not.
        """
        ...


struct AnyAsyncTransport(TransportHandle):
    """An async transport whose type has been forgotten, ready to be stored.

    ```mojo
    from httpx import AnyAsyncTransport, AsyncClient, AsyncHTTPTransport
    from httpx import async_blocked, erase_async_transport


    def main() raises:
        var offline = False
        var transport = erase_async_transport(AsyncHTTPTransport())
        if offline:
            transport = async_blocked("no network in this run")
        with AsyncClient(transport=transport^) as client:
            print(client.get("http://example.com/").status_code)
    ```
    """

    var _state: ErasedBox
    var _handle_request: def(
        ErasedBox, var Request, Deadlines
    ) raises thin -> Response
    var _handle_many: def(
        ErasedBox, var List[Request], Deadlines
    ) raises thin -> List[Response]
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
        handle_many: def(
            ErasedBox, var List[Request], Deadlines
        ) raises thin -> List[Response],
        handle_stream: def(
            ErasedBox, var Request, Deadlines
        ) raises thin -> Response,
        close: def(ErasedBox) thin -> None,
    ):
        self._state = state^
        self._handle_request = handle_request
        self._handle_many = handle_many
        self._handle_stream = handle_stream
        self._close = close

    def copy(self) -> Self:
        """Another handle on the same transport, sharing its connection pool.

        Explicit for the reason `AnyTransport.copy` is explicit: Mojo 1.0 does
        not run a written copy hook for an implicit copy, and a silent bitwise
        copy would leave the reference count behind.
        """
        return Self(
            self._state.copy(),
            self._handle_request,
            self._handle_many,
            self._handle_stream,
            self._close,
        )

    def state[T: AsyncTransport & Deinitable](self) -> ref[MutAnyOrigin] T:
        """The transport back again, as the type it was before it was erased.

        Asking for a type other than the one that went in is undefined, which is
        the one sharp edge of erasure and the reason this is spelled out rather
        than hidden behind a property.
        """
        return self._state.get[T]()

    def handle_request(
        mut self, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        return self._handle_request(self._state, request^, deadlines)

    def handle_many(
        mut self, var requests: List[Request], deadlines: Deadlines
    ) raises -> List[Response]:
        return self._handle_many(self._state, requests^, deadlines)

    def handle_stream(
        mut self, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        return self._handle_stream(self._state, request^, deadlines)

    def close(mut self):
        self._close(self._state)


def erase_async_transport[
    T: AsyncTransport & Deinitable
](var transport: T) -> AnyAsyncTransport:
    """Box `transport` and build the vtable that reaches back into it.

    The trampolines capture nothing. They recover the concrete type from `T`,
    which is a compile time parameter, so each one is an ordinary function with
    a nameable type rather than a closure.
    """

    def _handle_request(
        state: ErasedBox, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        return state.get[T]().handle_request(request^, deadlines)

    def _handle_many(
        state: ErasedBox, var requests: List[Request], deadlines: Deadlines
    ) raises -> List[Response]:
        return state.get[T]().handle_many(requests^, deadlines)

    def _handle_stream(
        state: ErasedBox, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        return state.get[T]().handle_stream(request^, deadlines)

    def _close(state: ErasedBox) -> None:
        state.get[T]().close()

    return AnyAsyncTransport(
        ErasedBox.make[T](transport^),
        _handle_request,
        _handle_many,
        _handle_stream,
        _close,
    )
