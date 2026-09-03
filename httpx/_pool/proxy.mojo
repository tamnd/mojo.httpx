"""Where to send a request that is not going straight to the server.

A forward proxy is the oldest thing in HTTP that is still in daily use, and on a
corporate network it is not optional. The client opens a connection to the proxy
instead of to the server, writes the whole URL in the request line rather than
just the path, and the proxy makes the real request and hands the answer back.

Two details are load bearing and both are about credentials. `Proxy-Authorization`
is not `Authorization`: it authenticates the client to the proxy and is consumed
by the proxy, whereas `Authorization` is for the server at the far end and must
pass through untouched. Sending one where the other belongs either fails to
authenticate or hands the server's password to the proxy. And the credentials
that arrive inside a proxy URL, which is how every environment variable carries
them, are turned into that header here and taken out of the URL, so they cannot
also end up in a request line, a log or an error message.
"""

from httpx._exceptions import ErrorKind, new_error
from httpx._models.headers import Headers
from httpx._models.request import Request
from httpx._models.url import URL
from httpx._pool.origin import Origin, origin_for
from httpx._proto.h1.writer import TargetForm
from httpx._util.base64 import base64_encode

comptime PROXY_AUTHORIZATION = "Proxy-Authorization"


def proxy_basic_auth(username: StringSpan, password: StringSpan) -> String:
    """A `Proxy-Authorization` value for a proxy asking for Basic.

    The same credential Basic builds anywhere else, under the header a proxy
    reads. Spelled out as its own function rather than reusing the one in
    `_auth`, because that one is an auth flow that signs requests for the server
    at the far end and this is a fixed header for the hop in front, and the two
    being one call would make it easy to reach for the wrong one.
    """
    var joined = List[UInt8]()
    joined.extend(username.as_bytes())
    joined.append(UInt8(ord(":")))
    joined.extend(password.as_bytes())
    return String("Basic ", base64_encode(Span(joined)))


struct Proxy(Movable, Writable):
    """One proxy, and the headers that go to it rather than through it.

    Copied explicitly rather than implicitly, because `URL` is, and because a
    value holding a credential is one worth having to name a copy of.
    """

    var url: URL
    """Where the connection goes. Never carries credentials.

    Anything in the userinfo has been turned into a `Proxy-Authorization`
    header and removed, because a URL with a password in it ends up in error
    messages and in whatever the user pastes into an issue.
    """

    var headers: Headers
    """Sent to the proxy and not forwarded to the server.

    `Proxy-Authorization` is the one that matters and is usually the only one.
    A caller can put others here for a proxy that wants them, which is what
    httpx2's `Proxy(headers=...)` is for.
    """

    def __init__(
        out self, var url: URL, var headers: Headers = Headers()
    ) raises:
        """A proxy at `url`, with its credentials moved out of the URL.

        An explicit `Proxy-Authorization` in `headers` wins over anything in
        the URL, because the caller who wrote the header meant it and the
        credentials in a URL are usually there because an environment variable
        put them there.
        """
        var scheme = url.scheme()
        if scheme != "http" and scheme != "https":
            raise new_error(
                ErrorKind.UNSUPPORTED_PROTOCOL,
                String(
                    "'",
                    scheme,
                    (
                        "' is not a proxy scheme this client speaks, expected"
                        " http or https"
                    ),
                ),
            )

        self.headers = headers^
        var username = url.username()
        var password = url.password()
        if username != "" or password != "":
            if PROXY_AUTHORIZATION not in self.headers:
                self.headers[PROXY_AUTHORIZATION] = proxy_basic_auth(
                    username, password
                )
            # Rebuilt from the parts that are safe to keep rather than edited
            # in place, so there is one code path and no way for a fragment of
            # the credential to survive in the raw bytes.
            self.url = URL(String(scheme, "://", url.netloc()))
            return
        self.url = url^

    def __init__(
        out self, url: StringSpan, var headers: Headers = Headers()
    ) raises:
        """The same, from a string, which is how a proxy is usually written."""
        self = Self(URL(url), headers^)

    def copy(self) -> Self:
        var out = Self()
        out.url = self.url.copy()
        out.headers = self.headers.copy()
        return out^

    def __init__(out self):
        """An empty proxy, for `copy` to fill in. Not useful on its own."""
        self.url = URL()
        self.headers = Headers()

    def origin(self) raises -> Origin:
        """What the pool keys the connection to the proxy under."""
        return origin_for(self.url)

    def apply(self, mut request: Request) raises:
        """Add the headers that belong to the hop rather than to the request.

        Set rather than defaulted. These are ours, not the caller's: a header
        the caller happened to name the same thing is not a credential for this
        proxy, and letting it win would send the wrong one and be very hard to
        see.
        """
        for field in self.headers.items():
            request.headers[field[0]] = field[1]

    def write_to[W: Writer](self, mut writer: W):
        """The URL and nothing else, because the headers hold a password."""
        writer.write(self.url)


struct Hop(ImplicitlyCopyable, Movable):
    """Where the socket goes, and what the request line says.

    The two answers come apart the moment a proxy is involved: the connection is
    to the proxy and the request target names the server. Returned together
    because working one out without the other is how a request ends up asking a
    proxy for `/path`, which every proxy answers with a 400.
    """

    var origin: Origin
    """The host to open a connection to, and the key a pool files it under."""

    var form: TargetForm
    """The request target shape to write."""

    def __init__(out self, origin: Origin, form: TargetForm):
        self.origin = origin
        self.form = form


def route_through(
    proxy: Optional[Proxy], mut request: Request, form: TargetForm
) raises -> Hop:
    """Decide the hop for one request, and put on it whatever the hop needs.

    Without a proxy this is the identity: connect to the server named in the URL
    and write the path. With one, the connection goes to the proxy, the request
    line carries the whole URL so the proxy knows what to fetch, and the proxy's
    own headers go on. `Proxy-Authorization` is added here, below the event hooks
    and the auth flow, because it belongs to this hop rather than to the request
    the caller wrote, and a hook that logged the request should not be printing
    the credential for the proxy.

    A form the caller asked for that is not `ORIGIN` is left alone. Those are
    `CONNECT` and `OPTIONS *`, which are already addressed at the hop in front
    and would be wrong in absolute form.

    Shared by both pools rather than written twice, so the synchronous and the
    async client cannot disagree about what a proxied request looks like.
    """
    var target = origin_for(request.url)
    if not proxy:
        return Hop(target, form)

    ref via = proxy.value()
    if target.is_secure():
        raise new_error(
            ErrorKind.PROXY_ERROR,
            String(
                "reaching ",
                target,
                " through the proxy at ",
                via.url,
                (
                    " needs a CONNECT tunnel, which this client cannot open"
                    " yet, so only http:// targets can go through a proxy"
                ),
            ),
        )

    via.apply(request)
    var wire = form
    if wire == TargetForm.ORIGIN:
        wire = TargetForm.ABSOLUTE
    return Hop(via.origin(), wire)
