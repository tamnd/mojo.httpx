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

The content encoders are still to come and land as separate arguments and
separate files. What is here now is a request going out over TCP and a parsed
response coming back, with the four timeouts and the client level headers, base
URL, query parameters and cookies honoured, either read whole or streamed a
chunk at a time, a redirect chain followed for anyone who asked for that, an
auth scheme answering a challenge around the outside of it, and event hooks
watching every send.

## Why there is one client and two names for it

`Client` and `AsyncClient` are the same struct with a different transport in
it. Nothing a client does depends on which one it got: merging headers,
resolving a relative URL against the base, writing the `Cookie` header, running
the hooks, following a redirect chain, answering an auth challenge and reading
the jar back out are all the same work either way, because all of them happen
either side of the transport call rather than inside it.

So `BaseClient` takes the transport handle as a compile time parameter and the
two public names are aliases for it. The alternative was this file copied into
`_aio_client.mojo` with `AnyTransport` changed to `AnyAsyncTransport`, and two
copies of a redirect loop is two redirect loops to fix when one of them is
wrong. `httpx._transport.handle` has the three calls the parameter has to
supply.

The second parameter is the function that builds a transport for a caller who
named none. It is a parameter rather than something the trait provides because
the choice of default belongs to the client: it is the client that was handed
`verify=`, `limits=` and `http2=` and has to turn them into something.
"""

from httpx._auth import AnyAuth
from httpx._bytes import Bytes
from httpx._codec.decode import accept_encoding
from httpx._config import Timeout
from httpx._content.encode import encode_request_body
from httpx._content.multipart import MultipartData
from httpx._exceptions import ErrorKind, new_error
from httpx._ffi.clock import unix_now
from httpx._io.deadline import Deadlines, now_ns
from httpx._hooks import EventHooks
from httpx._models.cookies import Cookies
from httpx._models.headers import Headers
from httpx._models.json import Json
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._models.stream import ByteStream
from httpx._models.url import URL, QueryParams
from httpx._pool.limits import Limits
from httpx._pool.proxy import Proxy
from httpx._redirects import DEFAULT_MAX_REDIRECTS, build_redirect_request
from httpx._stream.config import ClientCert, SSLVerify, TlsConfig
from httpx._transport.base import AnyTransport, erase_transport
from httpx._transport.handle import TransportHandle
from httpx._transport.http import HTTPTransport
from httpx._transport.mounts import Mounts
from httpx._util.charset import DefaultEncoding

comptime USER_AGENT = "mojo-httpx/0.0.1"
"""What this library calls itself.

Held here rather than read from `__version__` because `httpx/__init__.mojo`
imports this file, and a module cannot import the package that imports it. The
release checklist checks the two agree.
"""


struct BaseClient[
    H: TransportHandle,
    make_default: def(
        var Limits, var TlsConfig, var Optional[Proxy]
    ) raises thin -> H,
](Movable):
    """A configured HTTP client with a transport behind it.

    Held by users as `Client` or as `AsyncClient`, which are the two aliases at
    the bottom of this file and in `httpx._aio_client`. Nothing below refers to
    which one it is.
    """

    var headers: Headers
    """Sent on every request, unless the request overrides the same field."""

    var params: QueryParams
    """Merged into the query of every request, with request params winning."""

    var base_url: URL
    """What a relative URL is resolved against. Empty means there is none."""

    var cookies: Cookies
    """The jar every response writes into and every request is filled from.

    Public and mutable, so a caller can seed it before the first request and
    read it after any of them. This is the piece of a client that makes a
    sequence of requests a session rather than a series of unrelated ones.
    """

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

    var event_hooks: EventHooks
    """Callbacks run on every request sent and every response received.

    Public and mutable, like httpx's property of the same name, so hooks can go
    on after the client was built. Every hop of a redirect chain and every auth
    retry is a send and runs them.
    """

    var auth: Optional[AnyAuth]
    """The scheme used when a request does not name its own.

    Public and mutable, like httpx's property of the same name, so credentials
    can be attached to a client that already exists. `auth=no_auth()` on a
    single call is how one request goes out without it.
    """

    var default_encoding: DefaultEncoding
    """What to read a body as when the response does not say.

    Every response this client produces gets a copy of it. httpx puts it on the
    client for the same reason: an API that answers `text/plain` with no charset
    is an API where the answer is the same every time, and repeating it on every
    call would be noise.
    """

    var _transport: Self.H
    """Where a request goes when no mount claims it, and never a proxied one.

    A `proxy=` becomes a mount on `all://` rather than settings on this pool.
    `httpx._transport.mounts` explains why that is the only arrangement in which
    an entry saying "not through the proxy" has anywhere to send the request.
    """

    var _mounts: Mounts[Self.H]
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
        var cookies: Cookies = Cookies(),
        timeout: Optional[Timeout] = None,
        limits: Optional[Limits] = None,
        verify: SSLVerify = SSLVerify(),
        cert: Optional[ClientCert] = None,
        trust_env: Bool = True,
        http2: Bool = False,
        var proxy: Optional[Proxy] = None,
        follow_redirects: Bool = False,
        max_redirects: Int = DEFAULT_MAX_REDIRECTS,
        var auth: Optional[AnyAuth] = None,
        var event_hooks: EventHooks = EventHooks(),
        var default_encoding: DefaultEncoding = DefaultEncoding(),
        var transport: Optional[Self.H] = None,
        var mounts: Mounts[Self.H] = Mounts[Self.H](),
    ) raises:
        """Every option, all of them keyword only.

        Keyword only because there are sixteen of them and no order anybody
        would remember. httpx does the same, for the same reason.

        `transport` replaces the one this would otherwise build, which is how a
        mock goes under a client that still has its base URL, its headers and
        its redirect policy. Giving one makes `limits`, `verify`, `cert`,
        `trust_env`, `http2` and `proxy` dead letters, since those describe a
        connection pool that no longer exists.

        `proxy` sends every request through a forward proxy. It is a `Proxy`
        rather than a string because building one parses a URL and so can raise,
        and `Proxy("http://localhost:3128")` is the one extra call that buys.

        `mounts` routes by URL, and is how one client sends some traffic through
        a proxy and the rest direct, answers one domain from a mock, or refuses a
        scheme outright. Entries are tried most specific first and the first one
        that matches wins, so a `mounts` entry overrides `proxy`, which is itself
        a mount on `all://`. `httpx._transport.mounts` has the pattern language
        and the ordering rule.

        `http2` offers HTTP/2 in the TLS handshake rather than demanding it. A
        server that does not want it says so and gets HTTP/1.1, and a plain
        `http://` request is HTTP/1.1 whatever this says, because there is no
        handshake to negotiate in. Off by default, the same as httpx, since
        offering it costs a few bytes on every connection and the answer for
        most servers is no.
        """
        self.headers = headers^
        self.params = params^
        self.base_url = base_url^
        self.cookies = cookies^
        self.timeout = timeout.value() if timeout else Timeout()
        self.follow_redirects = follow_redirects
        self.max_redirects = max_redirects
        self.event_hooks = event_hooks^
        self.auth = auth^
        self.default_encoding = default_encoding^
        self._mounts = Mounts[Self.H]()
        if transport:
            self._transport = transport.take()
        else:
            var tls = TlsConfig()
            tls.verify = verify
            tls.cert = cert.copy()
            tls.trust_env = trust_env
            tls.http2 = http2
            var bounds = limits.value() if limits else Limits()
            self._transport = Self.make_default(bounds, tls, None)
            if proxy:
                self._mounts.mount(
                    "all://", Self.make_default(bounds, tls, proxy^)
                )
        # After the proxy, so that a caller who mounts `all://` themselves gets
        # theirs rather than the proxy, and so that a bypass they wrote lands on
        # a table where the proxy is already the thing being bypassed.
        self._mounts.extend(mounts^)
        self._closed = False

    def __init__(out self, var transport: Self.H) raises:
        """A client over a transport the caller built, and nothing else set.

        A shorthand for the keyword form, since a test that swaps the transport
        and configures nothing else is the common case. Anything more than that
        wants `Client(transport=..., base_url=...)`.
        """
        self = Self(transport=Optional[Self.H](transport^))

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
        self._mounts.close()

    def aclose(mut self):
        """The same as `close`, spelled the way httpx spells it.

        httpx has both because closing a pool of sockets there means awaiting
        the shutdown of each connection. Here it does not: nothing about
        letting go of a file descriptor suspends, so there is one
        implementation and this is a second name for it. It exists so that code
        moved over from httpx keeps reading the way it did, and so that a
        reader looking for `aclose` on the async client finds it rather than
        concluding it was forgotten.
        """
        self.close()

    def is_closed(self) -> Bool:
        return self._closed

    def _dispatch(
        mut self, var request: Request, deadlines: Deadlines, stream: Bool
    ) raises -> Response:
        """Hand the request to whichever transport its URL routes to.

        Every send goes through here, redirect hops and auth retries included,
        and each one is routed on its own URL rather than on the URL the caller
        started from. A redirect that leaves a mounted domain leaves its
        transport with it, which is the only reading that does not send a
        request somewhere the routing table says it should not go.

        The branch on `stream` is here rather than at the two call sites so that
        the routing is written once. The mounted case reaches through the
        `Optional` on the entry, which `route_for` has already established is
        occupied.
        """
        var at = self._mounts.route_for(request.url)
        if at < 0:
            if stream:
                return self._transport.handle_stream(request^, deadlines)
            return self._transport.handle_request(request^, deadlines)
        ref mounted = self._mounts.entries[at].transport.value()
        if stream:
            return mounted.handle_stream(request^, deadlines)
        return mounted.handle_request(request^, deadlines)

    def build_request(
        self,
        method: StringSpan,
        url: StringSpan,
        *,
        var headers: Headers = Headers(),
        var content: List[UInt8] = List[UInt8](),
        text: StringSpan = "",
        var data: QueryParams = QueryParams(),
        var files: MultipartData = MultipartData(),
        var json: Optional[Json] = None,
        var content_stream: Optional[ByteStream] = None,
        var params: QueryParams = QueryParams(),
        var cookies: Cookies = Cookies(),
    ) raises -> Request:
        """Merge the client configuration with this call and produce a request.

        Public because it is how a caller inspects what would be sent without
        sending it, and because `send` takes what it returns. httpx has the same
        pair for the same reason.

        There are six ways to give a body and they are six arguments. `content`
        is bytes already in memory, `text` is a string encoded as UTF-8, `data`
        is a urlencoded form, `files` is a multipart one, `json` is a document
        serialized compactly, and `content_stream` is a body pulled as it is
        written. httpx2 folds the first two into one `content=` and tells them
        apart at runtime, which Mojo cannot do, and naming them apart is better
        than a wrapper whose only job is to hide which one the caller meant.

        Passing two of them raises, except for `data` with `files`, which is one
        multipart body carrying both. The `Content-Type` the encoding implies is
        applied only if the caller did not write one, so an explicit header
        always wins.
        """
        var target = self._resolve(url)
        if len(params) > 0 or len(self.params) > 0:
            target = target.copy_merge_params(self.params.merge(params))

        var body = encode_request_body(
            Bytes(content^), text, data^, files^, json^
        )
        if content_stream and len(body) > 0:
            raise new_error(
                ErrorKind.INVALID_ARGUMENT,
                String(
                    "content_stream= cannot be combined with another body"
                    " argument"
                ),
            )

        var merged = self._headers_for(headers^)
        if body.has_content_type():
            merged.setdefault("Content-Type", body.content_type)
        self._apply_cookies(target, cookies^, merged)
        if content_stream:
            return Request.streaming(
                method, target^, content_stream.take(), merged^
            )
        var raw = body.take_content()
        return Request(method, target^, merged^, raw.take_list())

    def _apply_cookies(
        self, url: URL, var cookies: Cookies, mut headers: Headers
    ) raises:
        """Write the `Cookie` header for `url` from the jar, if there is one.

        A caller who wrote their own `Cookie` header keeps it exactly as they
        wrote it. That is what urllib's `add_cookie_header` does underneath
        httpx, and the reason is that a hand written `Cookie` is nearly always
        somebody reproducing a captured request, where a jar quietly folding its
        own values in would change the request being reproduced.

        An empty result means no header at all rather than an empty one, because
        `Cookie:` with nothing after it is a different message and some servers
        read it as such.
        """
        if "cookie" in headers:
            return
        var jar = self.cookies.copy()
        jar.update(cookies)
        if not jar:
            return
        var value = jar.header_for(url, unix_now())
        if value:
            headers["Cookie"] = value

    def send(
        mut self,
        var request: Request,
        timeout: Optional[Timeout] = None,
        stream: Bool = False,
        follow_redirects: Optional[Bool] = None,
        var auth: Optional[AnyAuth] = None,
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

        var scheme = auth^
        if not scheme and self.auth:
            # A copy of the client's scheme rather than the scheme itself,
            # because the send path needs it mutably and the client is only
            # borrowed here. The copy shares the same state, so a digest client
            # that has already been challenged stays challenged.
            scheme = Optional[AnyAuth](self.auth.value().copy())
        if not scheme:
            return self._send_following_redirects(
                request^, budget, stream, follow
            )

        var chosen = scheme.take()
        return self._send_handling_auth(
            request^, budget, stream, follow, chosen
        )

    def _send_handling_auth(
        mut self,
        var request: Request,
        budget: Timeout,
        stream: Bool,
        follow: Bool,
        mut auth: AnyAuth,
    ) raises -> Response:
        """Send, and send again if the scheme says the answer was a challenge.

        Auth is outside redirects rather than inside because a challenge can
        come back from the end of a redirect chain, and answering it means
        starting the chain again from the original URL. The other order would
        answer a challenge from an intermediate hop, which is a different
        server asking a different question.

        The 401 is read before the retry goes out, for the same reason a
        redirect is: an unread body is a connection that cannot go back to the
        pool, and the retry is about to want one to the same host.
        """
        var current = auth.sign(request^)
        var prior: Optional[Response] = None
        while True:
            var response = self._send_following_redirects(
                current^, budget, stream, follow, prior^
            )
            var following: Optional[Request]
            try:
                if auth.requires_response_body():
                    response.read()
                following = auth.next_request(response)
            except e:
                response.close()
                raise e
            if not following:
                return response^

            try:
                response.read()
            except e:
                response.close()
                raise e
            prior = Optional[Response](response^)
            current = following.take()

    def _send_following_redirects(
        mut self,
        var request: Request,
        budget: Timeout,
        stream: Bool,
        follow: Bool,
        var earlier: Optional[Response] = None,
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

        `earlier` is the chain an auth retry already accumulated, threaded in so
        that the history a caller finally sees spans both, in the order things
        happened. It is empty for a first attempt.
        """
        var current = request^
        var prior = earlier^
        var hops = 0
        while True:
            # Indexed rather than `for ref`, which wants a copyable element and
            # a hook is not one.
            for i in range(len(self.event_hooks.request)):
                var passed = self.event_hooks.request[i].call(current^)
                current = passed^

            var response: Response
            # Per hop rather than for the chain, so every response in the
            # history reports how long its own exchange took. A caller who wants
            # the total adds them up; one who wants to know which hop was slow
            # cannot recover that from a single number.
            var started = now_ns()
            response = self._dispatch(current^, budget.deadlines(), stream)
            response.begin_timing(started)
            # Before anything reads the body, since a hook calling `text()` on
            # a response with no charset on it should get the client's answer
            # rather than the bare default.
            response.default_encoding = self.default_encoding.copy()

            # Every response, not just the last one. A login that answers 302
            # with the session cookie on it is the ordinary case, and a jar that
            # only read the end of the chain would miss it.
            _ = self.cookies.extract(
                response.request().url, response.headers, unix_now()
            )

            # After the jar, so a hook sees the cookies the response already
            # stored, and before the history is attached, which is the order
            # httpx runs them in. A hook that raises took the response with it
            # and the connection is released as that frame unwinds, so there is
            # nothing to close here.
            for i in range(len(self.event_hooks.response)):
                var passed = self.event_hooks.response[i].call(response^)
                response = passed^

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

            # The redirect builder strips `Cookie` on every hop, so this is what
            # puts it back, computed for where the request is now going rather
            # than carried over from where it was going before. Per request
            # cookies are deliberately not carried across, matching httpx: they
            # were an argument about one call to one URL.
            self._apply_cookies(following.url, Cookies(), following.headers)

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
        text: StringSpan = "",
        var data: QueryParams = QueryParams(),
        var files: MultipartData = MultipartData(),
        var json: Optional[Json] = None,
        var content_stream: Optional[ByteStream] = None,
        var params: QueryParams = QueryParams(),
        var cookies: Cookies = Cookies(),
        timeout: Optional[Timeout] = None,
        follow_redirects: Optional[Bool] = None,
        var auth: Optional[AnyAuth] = None,
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
            text=text,
            data=data^,
            files=files^,
            json=json^,
            content_stream=content_stream^,
            params=params^,
            cookies=cookies^,
        )
        return self.send(
            built^,
            timeout,
            stream=True,
            follow_redirects=follow_redirects,
            auth=auth^,
        )

    def request(
        mut self,
        method: StringSpan,
        url: StringSpan,
        *,
        var headers: Headers = Headers(),
        var content: List[UInt8] = List[UInt8](),
        text: StringSpan = "",
        var data: QueryParams = QueryParams(),
        var files: MultipartData = MultipartData(),
        var json: Optional[Json] = None,
        var content_stream: Optional[ByteStream] = None,
        var params: QueryParams = QueryParams(),
        var cookies: Cookies = Cookies(),
        timeout: Optional[Timeout] = None,
        follow_redirects: Optional[Bool] = None,
        var auth: Optional[AnyAuth] = None,
    ) raises -> Response:
        var built = self.build_request(
            method,
            url,
            headers=headers^,
            content=content^,
            text=text,
            data=data^,
            files=files^,
            json=json^,
            content_stream=content_stream^,
            params=params^,
            cookies=cookies^,
        )
        return self.send(
            built^, timeout, follow_redirects=follow_redirects, auth=auth^
        )

    def get(
        mut self,
        url: StringSpan,
        *,
        var headers: Headers = Headers(),
        var params: QueryParams = QueryParams(),
        var cookies: Cookies = Cookies(),
        timeout: Optional[Timeout] = None,
        follow_redirects: Optional[Bool] = None,
        var auth: Optional[AnyAuth] = None,
    ) raises -> Response:
        # No body argument, on any of the four verbs below. RFC 9110 says a body
        # on these has no defined semantics, and httpx leaves it out of the
        # signature for the same reason.
        return self.request(
            "GET",
            url,
            headers=headers^,
            params=params^,
            cookies=cookies^,
            timeout=timeout,
            follow_redirects=follow_redirects,
            auth=auth^,
        )

    def head(
        mut self,
        url: StringSpan,
        *,
        var headers: Headers = Headers(),
        var params: QueryParams = QueryParams(),
        var cookies: Cookies = Cookies(),
        timeout: Optional[Timeout] = None,
        follow_redirects: Optional[Bool] = None,
        var auth: Optional[AnyAuth] = None,
    ) raises -> Response:
        return self.request(
            "HEAD",
            url,
            headers=headers^,
            params=params^,
            cookies=cookies^,
            timeout=timeout,
            follow_redirects=follow_redirects,
            auth=auth^,
        )

    def options(
        mut self,
        url: StringSpan,
        *,
        var headers: Headers = Headers(),
        var params: QueryParams = QueryParams(),
        var cookies: Cookies = Cookies(),
        timeout: Optional[Timeout] = None,
        follow_redirects: Optional[Bool] = None,
        var auth: Optional[AnyAuth] = None,
    ) raises -> Response:
        return self.request(
            "OPTIONS",
            url,
            headers=headers^,
            params=params^,
            cookies=cookies^,
            timeout=timeout,
            follow_redirects=follow_redirects,
            auth=auth^,
        )

    def delete(
        mut self,
        url: StringSpan,
        *,
        var headers: Headers = Headers(),
        var params: QueryParams = QueryParams(),
        var cookies: Cookies = Cookies(),
        timeout: Optional[Timeout] = None,
        follow_redirects: Optional[Bool] = None,
        var auth: Optional[AnyAuth] = None,
    ) raises -> Response:
        return self.request(
            "DELETE",
            url,
            headers=headers^,
            params=params^,
            cookies=cookies^,
            timeout=timeout,
            follow_redirects=follow_redirects,
            auth=auth^,
        )

    def post(
        mut self,
        url: StringSpan,
        *,
        var content: List[UInt8] = List[UInt8](),
        text: StringSpan = "",
        var data: QueryParams = QueryParams(),
        var files: MultipartData = MultipartData(),
        var json: Optional[Json] = None,
        var content_stream: Optional[ByteStream] = None,
        var headers: Headers = Headers(),
        var params: QueryParams = QueryParams(),
        var cookies: Cookies = Cookies(),
        timeout: Optional[Timeout] = None,
        follow_redirects: Optional[Bool] = None,
        var auth: Optional[AnyAuth] = None,
    ) raises -> Response:
        return self.request(
            "POST",
            url,
            headers=headers^,
            content=content^,
            text=text,
            data=data^,
            files=files^,
            json=json^,
            content_stream=content_stream^,
            params=params^,
            cookies=cookies^,
            timeout=timeout,
            follow_redirects=follow_redirects,
            auth=auth^,
        )

    def put(
        mut self,
        url: StringSpan,
        *,
        var content: List[UInt8] = List[UInt8](),
        text: StringSpan = "",
        var data: QueryParams = QueryParams(),
        var files: MultipartData = MultipartData(),
        var json: Optional[Json] = None,
        var content_stream: Optional[ByteStream] = None,
        var headers: Headers = Headers(),
        var params: QueryParams = QueryParams(),
        var cookies: Cookies = Cookies(),
        timeout: Optional[Timeout] = None,
        follow_redirects: Optional[Bool] = None,
        var auth: Optional[AnyAuth] = None,
    ) raises -> Response:
        return self.request(
            "PUT",
            url,
            headers=headers^,
            content=content^,
            text=text,
            data=data^,
            files=files^,
            json=json^,
            content_stream=content_stream^,
            params=params^,
            cookies=cookies^,
            timeout=timeout,
            follow_redirects=follow_redirects,
            auth=auth^,
        )

    def patch(
        mut self,
        url: StringSpan,
        *,
        var content: List[UInt8] = List[UInt8](),
        text: StringSpan = "",
        var data: QueryParams = QueryParams(),
        var files: MultipartData = MultipartData(),
        var json: Optional[Json] = None,
        var content_stream: Optional[ByteStream] = None,
        var headers: Headers = Headers(),
        var params: QueryParams = QueryParams(),
        var cookies: Cookies = Cookies(),
        timeout: Optional[Timeout] = None,
        follow_redirects: Optional[Bool] = None,
        var auth: Optional[AnyAuth] = None,
    ) raises -> Response:
        return self.request(
            "PATCH",
            url,
            headers=headers^,
            content=content^,
            text=text,
            data=data^,
            files=files^,
            json=json^,
            content_stream=content_stream^,
            params=params^,
            cookies=cookies^,
            timeout=timeout,
            follow_redirects=follow_redirects,
            auth=auth^,
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
        # What this process can actually undo, which is decided at run time by
        # whether libz loaded rather than at build time by what was compiled in.
        # Asking for a coding we cannot decode would mean handing the caller
        # compressed bytes and calling them the body, so a machine without zlib
        # sends `identity` and gets plain responses.
        out.setdefault("Accept-Encoding", accept_encoding())
        out.setdefault("Connection", "keep-alive")
        out.setdefault("User-Agent", USER_AGENT)
        return out^


def _default_transport(
    var limits: Limits, var tls: TlsConfig, var proxy: Optional[Proxy]
) raises -> AnyTransport:
    """The pool a synchronous client gets when the caller named no transport."""
    return erase_transport(HTTPTransport(limits^, tls^, proxy^))


comptime Client = BaseClient[AnyTransport, _default_transport]
"""The synchronous client. See `BaseClient` for everything it can do."""
