"""Transports that answer out of a function or a table instead of a socket.

The reason the transport boundary is worth having. A test that swaps one of
these in keeps the client's redirect following, auth, cookies and header
handling, and loses only the network, so what it exercises is the program rather
than a hand rolled imitation of it.

There are two of them because there are two kinds of test. `MockTransport` takes
one handler and answers everything with it, which is what you want when the
reply depends on the request. `MockRouter` is a table of rules matched in order,
which is what you want when the test is about a handful of endpoints and writing
the branching by hand would bury the point of the test. This is the ground
`respx` covers for httpx2, in the tree rather than as a separate package.

The handler is a thin function pointer, which means it cannot capture. Mojo 1.0
has no storable closures, so a handler that needs state has to read it from
somewhere both it and the test can see. Recording is provided here instead,
because wanting to look at what was sent is the common case and having to build
a place to put it every time would be tedious.
"""

from httpx._exceptions import ErrorKind, new_error
from httpx._io.deadline import Deadlines
from httpx._models.headers import Headers
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._models.url import URL, QueryParams
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
        # The handler gets the real request, body and all, and the response
        # carries the copy. The other way round would hand the handler a
        # streaming body that had already been taken away from it.
        var recorded = request.copy()
        self.requests.append(request.copy())
        var response = self.handler(request^)
        response.set_request(recorded^)
        return response^

    def handle_stream(
        mut self, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        """Exactly `handle_request`, because there is nothing to stream from.

        The handler builds a whole response in memory before this returns, so
        the response is already read. A test that iterates it still works, since
        an already read body iterates out of the buffer.
        """
        return self.handle_request(request^, deadlines)

    def close(mut self):
        """Nothing to release. Kept so this is a transport like any other."""
        pass


struct _Reply(Movable):
    """One prepared answer.

    A route holds a list of these rather than a single one, so a test can say
    what happens on the first call and what happens after that, which is how a
    retry or a token refresh gets tested at all.
    """

    var status_code: Int
    var reason_phrase: String
    var headers: Headers
    var content: List[UInt8]

    def __init__(
        out self,
        status_code: Int,
        var reason_phrase: String,
        var headers: Headers,
        var content: List[UInt8],
    ):
        self.status_code = status_code
        self.reason_phrase = reason_phrase^
        self.headers = headers^
        self.content = content^

    def copy(self) -> Self:
        return Self(
            self.status_code,
            self.reason_phrase.copy(),
            self.headers.copy(),
            self.content.copy(),
        )


def _path_of(url: URL) raises -> String:
    """The path, with an empty one read as `/`.

    `http://example.com` and `http://example.com/` are the same resource, and a
    route written either way should match a request written the other way.
    """
    var path = url.path()
    if path.byte_length() == 0:
        return String("/")
    return path^


struct Route(Movable):
    """One rule: what to match on, and what to answer with.

    Built by chaining, because the alternative is a constructor with a dozen
    optional arguments that a reader has to count commas in. Each builder takes
    the route and gives it back, so `Route.get("/users").respond(200)` is one
    expression and the route is never half built.

    Anything left unset matches anything. A route made from a path matches that
    path on any host, which is what a test with one server wants, and a route
    made from an absolute URL pins the scheme, host and port as well.
    """

    var method: String
    """Uppercase, or empty to match any method."""

    var scheme: String
    var host: String
    var port: Optional[UInt16]
    var path: String
    """Empty means any path, which is only reachable through `Route.any()`."""

    var params: QueryParams
    """Query parameters that must be present, not the whole query.

    A subset rather than an equality, because a request carrying a cache buster
    or a tracking parameter the test does not care about is still the request
    the test meant.
    """

    var headers: Headers
    """Headers that must be present, with these values. Also a subset."""

    var calls: List[Request]
    """Every request this route answered, in order."""

    var _replies: List[_Reply]
    var _served: Int

    def __init__(out self, method: StringSpan, pattern: StringSpan) raises:
        """A route for `method` and `pattern`.

        `pattern` is either a path, starting with a slash, or an absolute URL.
        An empty pattern matches any URL.
        """
        self.method = String(method).upper()
        self.scheme = String()
        self.host = String()
        self.port = None
        self.path = String()
        self.params = QueryParams()
        self.headers = Headers()
        self.calls = List[Request]()
        self._replies = List[_Reply]()
        self._served = 0
        if pattern.byte_length() == 0:
            return
        var url = URL(pattern)
        if url.is_absolute_url():
            self.scheme = url.scheme()
            self.host = url.host()
            self.port = url.effective_port()
        self.path = _path_of(url)
        var query = url.params()
        if query:
            self.params = query^

    def copy(self) raises -> Self:
        var out = Self(self.method, "")
        out.scheme = self.scheme.copy()
        out.host = self.host.copy()
        out.port = self.port
        out.path = self.path.copy()
        out.params = self.params.copy()
        out.headers = self.headers.copy()
        out._served = self._served
        for i in range(len(self._replies)):
            out._replies.append(self._replies[i].copy())
        for i in range(len(self.calls)):
            out.calls.append(self.calls[i].copy())
        return out^

    @staticmethod
    def any() raises -> Self:
        """Matches every request, which is how a catch all is written.

        Routes are tried in order, so this is only useful last. Put it there and
        an unmatched request answers rather than raising.
        """
        return Self("", "")

    @staticmethod
    def request(method: StringSpan, pattern: StringSpan) raises -> Self:
        return Self(method, pattern)

    @staticmethod
    def get(pattern: StringSpan) raises -> Self:
        return Self("GET", pattern)

    @staticmethod
    def post(pattern: StringSpan) raises -> Self:
        return Self("POST", pattern)

    @staticmethod
    def put(pattern: StringSpan) raises -> Self:
        return Self("PUT", pattern)

    @staticmethod
    def patch(pattern: StringSpan) raises -> Self:
        return Self("PATCH", pattern)

    @staticmethod
    def delete(pattern: StringSpan) raises -> Self:
        return Self("DELETE", pattern)

    @staticmethod
    def head(pattern: StringSpan) raises -> Self:
        return Self("HEAD", pattern)

    @staticmethod
    def options(pattern: StringSpan) raises -> Self:
        return Self("OPTIONS", pattern)

    def with_params(var self, var params: QueryParams) -> Self:
        """Also require these query parameters."""
        self.params = params^
        return self^

    def with_headers(var self, var headers: Headers) -> Self:
        """Also require these headers."""
        self.headers = headers^
        return self^

    def respond(
        var self,
        status_code: Int,
        var content: List[UInt8] = List[UInt8](),
        var headers: Headers = Headers(),
        var reason_phrase: String = String(),
    ) -> Self:
        """Answer with this.

        Called more than once, the answers are used in order and the last one
        repeats. `respond(503).respond(200)` is a server that fails once, which
        is the shape a retry test needs.
        """
        self._replies.append(
            _Reply(status_code, reason_phrase^, headers^, content^)
        )
        return self^

    def respond_text(
        var self,
        status_code: Int,
        body: StringSpan,
        content_type: StringSpan = "text/plain; charset=utf-8",
    ) raises -> Self:
        var headers = Headers()
        headers["Content-Type"] = String(content_type)
        var content = List[UInt8]()
        content.extend(body.as_bytes())
        return self^.respond(status_code, content^, headers^)

    def respond_json(
        var self, status_code: Int, body: StringSpan
    ) raises -> Self:
        """The same, with a JSON content type.

        The body is the JSON text rather than a value, because building one from
        a literal needs a syntax Mojo does not have, and a test that wants a
        value can parse the response back.
        """
        return self^.respond_text(status_code, body, "application/json")

    def called(self) -> Bool:
        return len(self.calls) > 0

    def call_count(self) -> Int:
        return len(self.calls)

    def matches(self, request: Request) raises -> Bool:
        """Whether this route answers `request`."""
        if self.method and self.method != request.method:
            return False
        if self.scheme and self.scheme != request.url.scheme():
            return False
        if self.host and self.host != request.url.host():
            return False
        if self.port and self.port != request.url.effective_port():
            return False
        if self.path and self.path != _path_of(request.url):
            return False
        if self.params:
            var query = request.url.params()
            for key in self.params.keys():
                if query.get(key) != self.params[key]:
                    return False
        for key in self.headers.keys():
            if request.headers.get(key) != self.headers[key]:
                return False
        return True

    def _serve(mut self, var request: Request) raises -> Response:
        """Record `request` and hand back the next prepared answer."""
        self.calls.append(request.copy())
        if len(self._replies) == 0:
            return Response(200)
        # The last one repeats rather than running out. A route that answered
        # twice and then started raising would turn a loop in the code under
        # test into a failure that says nothing about the loop.
        var index = self._served
        if index >= len(self._replies):
            index = len(self._replies) - 1
        self._served += 1
        ref reply = self._replies[index]
        var headers = reply.headers.copy()
        # A real response says how long the body is, and a test asserting on
        # `Content-Length` should not have to know it came from a mock.
        if "content-length" not in headers:
            headers["Content-Length"] = String(len(reply.content))
        return Response(
            reply.status_code,
            reply.reason_phrase.copy(),
            String("HTTP/1.1"),
            headers^,
            reply.content.copy(),
        )


struct MockRouter(Transport):
    """A table of routes, matched in order, answering as a transport.

    First match wins, so the specific routes go first and `Route.any()` goes
    last. A request that matches nothing raises rather than answering, because a
    mock that quietly returned 404 for a URL the test never meant to hit would
    turn a typo into a plausible looking test failure somewhere else.
    """

    var routes: List[Route]

    var calls: List[Request]
    """Every request that reached the router, matched or not.

    Kept beside the per route recordings because the question `what did this
    program send` and the question `did this endpoint get hit` are different
    questions, and the first one is the one that finds the bug.
    """

    def __init__(out self):
        self.routes = List[Route]()
        self.calls = List[Request]()

    def add(mut self, var route: Route):
        """Add a route to the end of the table."""
        self.routes.append(route^)

    def __len__(self) -> Int:
        return len(self.routes)

    def all_called(self) -> Bool:
        """Whether every route answered at least one request.

        A route that never matched is usually a route whose pattern is wrong,
        and the test passing anyway is how that stays wrong.
        """
        for i in range(len(self.routes)):
            if not self.routes[i].called():
                return False
        return True

    def assert_all_called(self) raises:
        """Raise unless every route answered at least one request."""
        for i in range(len(self.routes)):
            if not self.routes[i].called():
                raise new_error(
                    ErrorKind.INVALID_ARGUMENT,
                    String(
                        "route ",
                        self.routes[i]
                        .method if self.routes[i]
                        .method else String("ANY"),
                        " ",
                        self.routes[i]
                        .path if self.routes[i]
                        .path else String("*"),
                        " was never called",
                    ),
                )

    def reset(mut self):
        """Forget every recorded call, and start the answers over."""
        self.calls.clear()
        for i in range(len(self.routes)):
            self.routes[i].calls.clear()
            self.routes[i]._served = 0

    def handle_request(
        mut self, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        """The deadlines are accepted and ignored, as in `MockTransport`."""
        self.calls.append(request.copy())
        var recorded = request.copy()
        for i in range(len(self.routes)):
            if self.routes[i].matches(request):
                var response = self.routes[i]._serve(request^)
                response.set_request(recorded^)
                return response^
        raise new_error(
            ErrorKind.INVALID_ARGUMENT,
            String(
                "no route matched ", request.method, " ", String(request.url)
            ),
        )

    def handle_stream(
        mut self, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        """Exactly `handle_request`, because there is nothing to stream from."""
        return self.handle_request(request^, deadlines)

    def close(mut self):
        """Nothing to release. Kept so this is a transport like any other."""
        pass
