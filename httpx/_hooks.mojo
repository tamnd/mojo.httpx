"""Callbacks that see every request going out and every response coming back.

This is the seam logging, metrics and tracing sit on. httpx puts it in the same
place and for the same reason: a client that has to be subclassed to be observed
is a client nobody instruments, and a transport wrapper sees the bytes but not
the request the caller wrote.

A hook takes the value and gives it back, rather than being handed a mutable
reference. That is forced: a thin function pointer in Mojo 1.0 cannot take a
`mut` parameter, and thin pointers are what makes a vtable possible at all. It
turns out to be the better contract anyway. A hook that raises has already taken
ownership of the response, so the response is destroyed as that frame unwinds
and the connection it was holding is released, with nothing in the client having
to remember to close it.

Hooks come in two spellings. A plain function is the common case and goes in
with `on_request`. A hook that needs to remember something across calls, which
is most of what observability wants, is a struct implementing `RequestHook` or
`ResponseHook` and goes in through `erase_request_hook`. `state[T]()` reads it
back afterwards, because a counter you cannot read is not a counter.
"""

from httpx._models.request import Request
from httpx._models.response import Response
from httpx._util.erase import ErasedBox


trait RequestHook(Movable):
    """Something that gets a look at every request before it is sent.

    ```mojo
    from httpx import Client, EventHooks, Request, RequestHook
    from httpx import erase_request_hook


    struct Stamp(Movable, RequestHook):
        var _value: String

        def __init__(out self, value: StringSpan):
            self._value = String(value)

        def on_request(mut self, var request: Request) raises -> Request:
            request.headers["X-Trace-Id"] = self._value
            return request^


    def main() raises:
        var hooks = EventHooks()
        hooks.request.append(erase_request_hook(Stamp("abc123")))
        with Client(event_hooks=hooks^) as client:
            print(client.get("https://example.com/").status_code)
    ```
    """

    def on_request(mut self, var request: Request) raises -> Request:
        """The request as it should go out.

        Returning it rather than mutating it in place is what lets this be
        reached through a function pointer. Return the request you were given
        unless you meant to change it.
        """
        ...


trait ResponseHook(Movable):
    """Something that gets a look at every response as it arrives.

    ```mojo
    from httpx import Client, EventHooks, Response, ResponseHook
    from httpx import erase_response_hook


    struct Log(Movable, ResponseHook):
        def __init__(out self):
            pass

        def on_response(mut self, var response: Response) raises -> Response:
            print(response.status_code)
            return response^


    def main() raises:
        var hooks = EventHooks()
        hooks.response.append(erase_response_hook(Log()))
        with Client(event_hooks=hooks^) as client:
            print(client.get("https://example.com/").status_code)
    ```
    """

    def on_response(mut self, var response: Response) raises -> Response:
        """The response as the caller should see it.

        Called before the body has been read, so a hook is free to stream it,
        read it, or leave it alone. Raising here is how a hook rejects a
        response, and the response is destroyed on the way out, which releases
        the connection.
        """
        ...


struct AnyRequestHook(Movable):
    """A request hook whose type has been forgotten, ready to be stored.

    ```mojo
    from httpx import AnyRequestHook, EventHooks, Request, URL


    def stamp(var request: Request) raises -> Request:
        request.headers["X-Trace-Id"] = "abc123"
        return request^


    def main() raises:
        var hooks = EventHooks()
        hooks.on_request(stamp)
        var boxed: AnyRequestHook = hooks.request[0].copy()
        var stamped = boxed.call(Request("GET", URL("https://example.com/")))
        print(stamped.headers["X-Trace-Id"])
    ```
    """

    var _state: ErasedBox
    var _call: def(ErasedBox, var Request) raises thin -> Request

    def __init__(
        out self,
        var state: ErasedBox,
        call: def(ErasedBox, var Request) raises thin -> Request,
    ):
        self._state = state^
        self._call = call

    def copy(self) -> Self:
        """Another handle on the same hook, sharing its state.

        Sharing rather than duplicating, which is what makes a handle kept by
        the caller and the one held by the client the same counter.
        """
        return Self(self._state.copy(), self._call)

    def call(mut self, var request: Request) raises -> Request:
        return self._call(self._state, request^)

    def state[T: RequestHook & Deinitable](self) -> ref[MutAnyOrigin] T:
        """The hook back again, as the type it was before it was erased.

        For reading what a stateful hook accumulated. Asking for a type other
        than the one that went in is undefined, which is the one sharp edge of
        erasure and the reason this is spelled explicitly rather than hidden
        behind a property.
        """
        return self._state.get[T]()


struct AnyResponseHook(Movable):
    """A response hook whose type has been forgotten, ready to be stored.

    ```mojo
    from httpx import AnyResponseHook, EventHooks, Response


    def note(var response: Response) raises -> Response:
        print("saw", response.status_code)
        return response^


    def main() raises:
        var hooks = EventHooks()
        hooks.on_response(note)
        var boxed: AnyResponseHook = hooks.response[0].copy()
        print(boxed.call(Response(200)).status_code)
    ```
    """

    var _state: ErasedBox
    var _call: def(ErasedBox, var Response) raises thin -> Response

    def __init__(
        out self,
        var state: ErasedBox,
        call: def(ErasedBox, var Response) raises thin -> Response,
    ):
        self._state = state^
        self._call = call

    def copy(self) -> Self:
        return Self(self._state.copy(), self._call)

    def call(mut self, var response: Response) raises -> Response:
        return self._call(self._state, response^)

    def state[T: ResponseHook & Deinitable](self) -> ref[MutAnyOrigin] T:
        """The hook back again, as the type it was before it was erased."""
        return self._state.get[T]()


def erase_request_hook[
    T: RequestHook & Deinitable
](var hook: T) -> AnyRequestHook:
    """Box `hook` and build the vtable that reaches back into it."""

    def _call(state: ErasedBox, var request: Request) raises -> Request:
        return state.get[T]().on_request(request^)

    return AnyRequestHook(ErasedBox.make[T](hook^), _call)


def erase_response_hook[
    T: ResponseHook & Deinitable
](var hook: T) -> AnyResponseHook:
    """Box `hook` and build the vtable that reaches back into it."""

    def _call(state: ErasedBox, var response: Response) raises -> Response:
        return state.get[T]().on_response(response^)

    return AnyResponseHook(ErasedBox.make[T](hook^), _call)


struct RequestFunction(Movable, RequestHook):
    """A plain function wearing the `RequestHook` trait.

    So that the common case, a function that logs a line and gives the request
    straight back, does not need a struct written around it.
    """

    var _call: def(var Request) raises thin -> Request

    def __init__(out self, call: def(var Request) raises thin -> Request):
        self._call = call

    def on_request(mut self, var request: Request) raises -> Request:
        return self._call(request^)


struct ResponseFunction(Movable, ResponseHook):
    """A plain function wearing the `ResponseHook` trait."""

    var _call: def(var Response) raises thin -> Response

    def __init__(out self, call: def(var Response) raises thin -> Response):
        self._call = call

    def on_response(mut self, var response: Response) raises -> Response:
        return self._call(response^)


struct EventHooks(Movable, Sized):
    """The two lists a client runs, named the way httpx names them.

    Both are public, so hooks can be added after the client was built as well as
    before. Order is the order they were added, and every hook runs on every
    send, which means once per redirect hop and once per auth retry rather than
    once per call. That is httpx's behaviour and it is the useful one: a hook
    that only saw the last request of a chain would be a hook that missed the
    request that actually got redirected.

    ```mojo
    from httpx import Client, EventHooks, Request, Response


    def stamp(var request: Request) raises -> Request:
        request.headers["X-Trace-Id"] = "abc123"
        return request^


    def note(var response: Response) raises -> Response:
        print("saw", response.status_code)
        return response^


    def main() raises:
        var hooks = EventHooks()
        hooks.on_request(stamp)
        hooks.on_response(note)
        with Client(event_hooks=hooks^) as client:
            print(client.get("https://example.com/").status_code)
    ```
    """

    var request: List[AnyRequestHook]
    var response: List[AnyResponseHook]

    def __init__(out self):
        self.request = List[AnyRequestHook]()
        self.response = List[AnyResponseHook]()

    def copy(self) -> Self:
        var out = Self()
        # Indexed rather than `for ref`, because iterating a list through an
        # immutable `self` wants a copyable element and a hook is not one.
        for i in range(len(self.request)):
            out.request.append(self.request[i].copy())
        for i in range(len(self.response)):
            out.response.append(self.response[i].copy())
        return out^

    def __len__(self) -> Int:
        return len(self.request) + len(self.response)

    def on_request(mut self, call: def(var Request) raises thin -> Request):
        """Add a plain function to the request hooks."""
        self.request.append(erase_request_hook(RequestFunction(call)))

    def on_response(mut self, call: def(var Response) raises thin -> Response):
        """Add a plain function to the response hooks."""
        self.response.append(erase_response_hook(ResponseFunction(call)))

    def clear(mut self):
        self.request.clear()
        self.response.clear()
