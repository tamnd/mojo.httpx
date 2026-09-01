"""The thing a user actually holds.

A client is configuration plus a transport. It merges what the caller set once
against what they pass per request, turns that into a `Request`, hands it to
the transport, and returns what comes back. Everything underneath is reachable
on its own for anyone who wants it, and nobody has to want it.

The reason the client owns a transport rather than a pool is reuse. A client
that is kept alive keeps its connections alive, so the second request to a host
costs a round trip instead of a connect, a DNS lookup and, later, a handshake.
That is the whole argument for `Client` existing next to `httpx.get`, and it is
why the one shot helpers in `_api.mojo` are documented as the slow path.

Auth, cookies, event hooks and the content encoders are still to come and land
as separate arguments and separate files. What is here now is a request going
out over TCP and a parsed response coming back, with the four timeouts and the
client level headers, base URL and query parameters honoured, either read whole
or streamed a chunk at a time, and a redirect chain followed for anyone who
asked for that.
"""

from httpx._config import Timeout
from httpx._exceptions import ErrorKind, new_error
from httpx._models.headers import Headers
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._models.stream import ByteStream
from httpx._models.url import URL, QueryParams
from httpx._pool.limits import Limits
from httpx._redirects import DEFAULT_MAX_REDIRECTS, build_redirect_request
from httpx._stream.config import ClientCert, SSLVerify, TlsConfig
from httpx._transport.base import AnyTransport, erase
from httpx._transport.http import HTTPTransport

comptime USER_AGENT = "mojo-httpx/0.0.1"
"""What this library calls itself.

Held here rather than read from `__version__` because `httpx/__init__.mojo`
imports this file, and a module cannot import the package that imports it. The
release checklist checks the two agree.
"""


struct Client(Movable):
    """A configured HTTP client with a connection pool behind it."""

    var headers: Headers
    """Sent on every request, unless the request overrides the same field."""

    var params: QueryParams
    """Merged into the query of every request, with request params winning."""

    var base_url: URL
    """What a relative URL is resolved against. Empty means there is none."""

    var timeout: Timeout
    """The four phase timeout used when a request does not name its own."""

    var follow_redirects: Bool
    """Whether a 3xx with a `Location` is followed rather than returned.

    Off by default, which is httpx's choice and not the one most libraries make.
    A client that follows redirects silently will happily turn one request into
    a request somewhere else entirely, and the caller who wrote the URL never
    sees that it happened. Off means the redirect comes back as a response with
    a `next_request` on it, and following it is something the caller asked for.
    """

    var max_redirects: Int
    """How many hops before `TooManyRedirects`. Twenty, as in httpx."""

    var _transport: AnyTransport
    var _closed: Bool

    def __init__(out self) raises:
        """A client with the defaults, which is what nearly every caller wants.

        Separate from the configuring constructor because the defaults are
        built by code that can raise, and Mojo will not call a raising function
        to fill in a default argument.
        """
        self = Self(headers=Headers())

    def __init__(
        out self,
        *,
        var headers: Headers = Headers(),
        var params: QueryParams = QueryParams(),
        var base_url: URL = URL(),
        timeout: Optional[Timeout] = None,
        limits: Optional[Limits] = None,
        verify: SSLVerify = SSLVerify(),
        cert: Optional[ClientCert] = None,
        trust_env: Bool = True,
        follow_redirects: Bool = False,
        max_redirects: Int = DEFAULT_MAX_REDIRECTS,
    ) raises:
        self.headers = headers^
        self.params = params^
        self.base_url = base_url^
        self.timeout = timeout.value() if timeout else Timeout()
        self.follow_redirects = follow_redirects
        self.max_redirects = max_redirects
        var tls = TlsConfig()
        tls.verify = verify
        tls.cert = cert.copy()
        tls.trust_env = trust_env
        var transport = HTTPTransport(
            limits.value() if limits else Limits(), tls^
        )
        self._transport = erase(transport^)
        self._closed = False

    def __init__(out self, var transport: AnyTransport) raises:
        """A client over a transport the caller built.

        This is the seam `MockTransport` plugs into. It is a constructor rather
        than an argument on the one above because a transport cannot be an
        `Optional` default without being copyable, and a transport that could be
        copied silently would be a connection pool that could be duplicated.
        """
        self.headers = Headers()
        self.params = QueryParams()
        self.base_url = URL()
        self.timeout = Timeout()
        self.follow_redirects = False
        self.max_redirects = DEFAULT_MAX_REDIRECTS
        self._transport = transport^
        self._closed = False

    def __enter__(var self) -> Self:
        """Hand the client to the `with` block, which then owns it.

        Consuming rather than borrowing, because Mojo 1.0 will not enter a
        `with` on a value that is neither copyable nor transferred, and a client
        that could be copied implicitly would be a connection pool that could be
        duplicated by accident. The block owning it is what closes it: the
        client is destroyed at the end of the block, the pool goes with it, and
        every socket it held is closed by its own destructor.
        """
        return self^

    def close(mut self):
        """Close the pool. Doing it twice is not an error.

        Calling it is not required for correctness, since the pool closes its
        sockets when it is destroyed, but a client that is going to live a while
        after its last request should not be holding file descriptors open.
        """
        if self._closed:
            return
        self._closed = True
        self._transport.close()

    def is_closed(self) -> Bool:
        return self._closed

    def build_request(
        self,
        method: StringSpan,
        url: StringSpan,
        *,
        var headers: Headers = Headers(),
        var content: List[UInt8] = List[UInt8](),
        var content_stream: Optional[ByteStream] = None,
        var params: QueryParams = QueryParams(),
    ) raises -> Request:
        """Merge the client configuration with this call and produce a request.

        Public because it is how a caller inspects what would be sent without
        sending it, and because `send` takes what it returns. httpx has the same
        pair for the same reason.

        `content` is a body that is already in memory and `content_stream` is
        one that is pulled as it is written. httpx2 takes either through a
        single `content=`, because Python can tell bytes from an iterable at
        runtime. Here they are two arguments because they are two types, and
        naming them apart is better than a wrapper whose only job is to hide
        which one the caller meant.
        """
        var target = self._resolve(url)
        if len(params) > 0 or len(self.params) > 0:
            target = target.copy_merge_params(self.params.merge(params))
        var merged = self._headers_for(headers^)
        if content_stream:
            return Request.streaming(
                method, target^, content_stream.take(), merged^
            )
        return Request(method, target^, merged^, content^)

    def send(
        mut self,
        var request: Request,
        timeout: Optional[Timeout] = None,
        stream: Bool = False,
        follow_redirects: Optional[Bool] = None,
    ) raises -> Response:
        """Send a request that is already built.

        The deadlines are worked out here, at the last moment before the
        transport is called, so that all four phases start from one instant and
        a slow build does not eat the connect budget.

        With `stream` set the call returns as soon as the head has arrived and
        the body is left on the connection, which also means the connection
        stays out of the pool until the response is read, closed or dropped.
        """
        if self._closed:
            raise Error("RuntimeError: the client is closed")
        var budget = timeout.value() if timeout else self.timeout
        var follow = (
            follow_redirects.value() if follow_redirects else self.follow_redirects
        )
        return self._send_following_redirects(request^, budget, stream, follow)

    def _send_following_redirects(
        mut self,
        var request: Request,
        budget: Timeout,
        stream: Bool,
        follow: Bool,
    ) raises -> Response:
        """Send, and keep sending while the answer says to go somewhere else.

        The whole loop runs on one timeout, applied to each hop rather than to
        the chain, because each hop is a separate exchange with a separate
        server and a chain that shared one budget would fail a request for being
        redirected rather than for being slow.

        The deadlines are built fresh for every hop for the same reason.

        Each response carries the request that produced it, which is what makes
        the loop possible at all: the request went into the transport and came
        back out inside the answer, so the next hop can be built from it without
        the client having kept a copy.
        """
        var current = request^
        var prior: Optional[Response] = None
        var hops = 0
        while True:
            var response: Response
            if stream:
                response = self._transport.handle_stream(
                    current^, budget.deadlines()
                )
            else:
                response = self._transport.handle_request(
                    current^, budget.deadlines()
                )
            if prior:
                response.inherit_history(prior.take())
            if not response.is_redirect():
                return response^

            if follow and hops >= self.max_redirects:
                response.close()
                raise new_error(
                    ErrorKind.TOO_MANY_REDIRECTS,
                    String("Exceeded maximum allowed redirects."),
                )

            var status = response.status_code
            var location = response.headers["location"]
            var following: Request
            try:
                following = build_redirect_request(
                    response.request(), status, location
                )
            except e:
                # A streamed response is still holding a connection at this
                # point and nothing above here will ever see it again.
                response.close()
                raise e

            if not follow:
                response.set_next_request(following^)
                return response^

            try:
                # Drained rather than left behind. A streamed redirect is
                # holding a connection out of the pool, and the next hop is very
                # likely to want it.
                response.read()
            except e:
                response.close()
                raise e

            hops += 1
            prior = Optional[Response](response^)
            current = following^

    def stream(
        mut self,
        method: StringSpan,
        url: StringSpan,
        *,
        var headers: Headers = Headers(),
        var content: List[UInt8] = List[UInt8](),
        var content_stream: Optional[ByteStream] = None,
        var params: QueryParams = QueryParams(),
        timeout: Optional[Timeout] = None,
        follow_redirects: Optional[Bool] = None,
    ) raises -> Response:
        """Send a request and get the response back before the body arrives.

        For a body too large to want in memory, or one that does not end, such
        as an event stream. Walk it with `iter_bytes`, `iter_text` or
        `iter_lines`, or call `read()` to give up and buffer it after all.

        ```mojo
        with client.stream("GET", "/big.bin") as r:
            var chunks = r.iter_bytes(65536)
            while chunks.has_next():
                sink.write(chunks.next())
        ```

        The `with` is not decoration. The connection this response is holding
        goes back to the pool when the body ends and is closed if the block is
        left before that, and both of those happen because the response was
        destroyed at the end of the block.
        """
        var built = self.build_request(
            method,
            url,
            headers=headers^,
            content=content^,
            content_stream=content_stream^,
            params=params^,
        )
        return self.send(
            built^, timeout, stream=True, follow_redirects=follow_redirects
        )

    def request(
        mut self,
        method: StringSpan,
        url: StringSpan,
        *,
        var headers: Headers = Headers(),
        var content: List[UInt8] = List[UInt8](),
        var content_stream: Optional[ByteStream] = None,
        var params: QueryParams = QueryParams(),
        timeout: Optional[Timeout] = None,
        follow_redirects: Optional[Bool] = None,
    ) raises -> Response:
        var built = self.build_request(
            method,
            url,
            headers=headers^,
            content=content^,
            content_stream=content_stream^,
            params=params^,
        )
        return self.send(built^, timeout, follow_redirects=follow_redirects)

    def get(
        mut self,
        url: StringSpan,
        *,
        var headers: Headers = Headers(),
        var params: QueryParams = QueryParams(),
        timeout: Optional[Timeout] = None,
        follow_redirects: Optional[Bool] = None,
    ) raises -> Response:
        # No body argument, on any of the four verbs below. RFC 9110 says a body
        # on these has no defined semantics, and httpx leaves it out of the
        # signature for the same reason.
        return self.request(
            "GET",
            url,
            headers=headers^,
            params=params^,
            timeout=timeout,
            follow_redirects=follow_redirects,
        )

    def head(
        mut self,
        url: StringSpan,
        *,
        var headers: Headers = Headers(),
        var params: QueryParams = QueryParams(),
        timeout: Optional[Timeout] = None,
        follow_redirects: Optional[Bool] = None,
    ) raises -> Response:
        return self.request(
            "HEAD",
            url,
            headers=headers^,
            params=params^,
            timeout=timeout,
            follow_redirects=follow_redirects,
        )

    def options(
        mut self,
        url: StringSpan,
        *,
        var headers: Headers = Headers(),
        var params: QueryParams = QueryParams(),
        timeout: Optional[Timeout] = None,
        follow_redirects: Optional[Bool] = None,
    ) raises -> Response:
        return self.request(
            "OPTIONS",
            url,
            headers=headers^,
            params=params^,
            timeout=timeout,
            follow_redirects=follow_redirects,
        )

    def delete(
        mut self,
        url: StringSpan,
        *,
        var headers: Headers = Headers(),
        var params: QueryParams = QueryParams(),
        timeout: Optional[Timeout] = None,
        follow_redirects: Optional[Bool] = None,
    ) raises -> Response:
        return self.request(
            "DELETE",
            url,
            headers=headers^,
            params=params^,
            timeout=timeout,
            follow_redirects=follow_redirects,
        )

    def post(
        mut self,
        url: StringSpan,
        *,
        var content: List[UInt8] = List[UInt8](),
        var content_stream: Optional[ByteStream] = None,
        var headers: Headers = Headers(),
        var params: QueryParams = QueryParams(),
        timeout: Optional[Timeout] = None,
        follow_redirects: Optional[Bool] = None,
    ) raises -> Response:
        return self.request(
            "POST",
            url,
            headers=headers^,
            content=content^,
            content_stream=content_stream^,
            params=params^,
            timeout=timeout,
            follow_redirects=follow_redirects,
        )

    def put(
        mut self,
        url: StringSpan,
        *,
        var content: List[UInt8] = List[UInt8](),
        var content_stream: Optional[ByteStream] = None,
        var headers: Headers = Headers(),
        var params: QueryParams = QueryParams(),
        timeout: Optional[Timeout] = None,
        follow_redirects: Optional[Bool] = None,
    ) raises -> Response:
        return self.request(
            "PUT",
            url,
            headers=headers^,
            content=content^,
            content_stream=content_stream^,
            params=params^,
            timeout=timeout,
            follow_redirects=follow_redirects,
        )

    def patch(
        mut self,
        url: StringSpan,
        *,
        var content: List[UInt8] = List[UInt8](),
        var content_stream: Optional[ByteStream] = None,
        var headers: Headers = Headers(),
        var params: QueryParams = QueryParams(),
        timeout: Optional[Timeout] = None,
        follow_redirects: Optional[Bool] = None,
    ) raises -> Response:
        return self.request(
            "PATCH",
            url,
            headers=headers^,
            content=content^,
            content_stream=content_stream^,
            params=params^,
            timeout=timeout,
            follow_redirects=follow_redirects,
        )

    def _resolve(self, url: StringSpan) raises -> URL:
        """This call's URL, against the base URL when there is one.

        RFC 3986 resolution, not concatenation, which is what makes
        `base_url="https://x.com/api"` and `"/users"` come out as
        `https://x.com/users`. That surprises people, and httpx does exactly
        this, so matching it matters more than being intuitive.
        """
        # No host means no base URL. A base URL without one could not be
        # resolved against anyway, and testing for the host rather than for an
        # empty string keeps `Client(base_url=URL())` and a client that was
        # never given one on the same path.
        if self.base_url.raw_host().__len__() == 0:
            return URL(url)
        return self.base_url.join(url)

    def _headers_for(self, var headers: Headers) raises -> Headers:
        """The client headers, then this call's, then whatever is still missing.

        The order is the merge rule: a field the caller set on the request
        replaces the same field on the client, and the defaults only fill in
        what neither of them named. `Host` is not here because it comes from the
        URL when the request is serialized, and a client that let a header
        contradict the URL would be a client that could be pointed at one host
        while addressing another.
        """
        var out = self.headers.copy()
        out.update(headers^)
        out.setdefault("Accept", "*/*")
        # `identity` rather than the `gzip, deflate` httpx sends, because asking
        # for a coding this client cannot undo would mean handing the caller
        # compressed bytes and calling them the body. The codecs land in M4 and
        # this becomes the list of what is compiled in, so the header follows
        # what the client can actually do rather than what it hopes for.
        out.setdefault("Accept-Encoding", "identity")
        out.setdefault("Connection", "keep-alive")
        out.setdefault("User-Agent", USER_AGENT)
        return out^
