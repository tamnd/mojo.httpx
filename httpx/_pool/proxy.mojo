"""Where to send a request that is not going straight to the server.

A forward proxy is the oldest thing in HTTP that is still in daily use, and on a
corporate network it is not optional. The client opens a connection to the proxy
instead of to the server, writes the whole URL in the request line rather than
just the path, and the proxy makes the real request and hands the answer back.

That only works for `http://`. An `https://` request is encrypted end to end, so
there is no URL for the proxy to read and no response for it to hand back, and
the client asks for a tunnel instead: a `CONNECT` naming the host and port, and
after the 200 the socket is a pipe the proxy relays without looking at. The TLS
handshake then runs inside it, to the real server, with the real certificate. See
`httpx._proto.h1.tunnel`.

A SOCKS5 proxy is the third shape and the simplest of the three, because it is
not an HTTP proxy at all. It is told a host and a port in a short binary
handshake and then relays bytes, so there is no request line to rewrite and no
distinction between an `http://` target and an `https://` one: both tunnel. See
`httpx._proto.socks5`.

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
from httpx._pool.origin import Origin, origin_for, proxy_origin_for
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

    var username: String
    """The SOCKS5 username, and empty for every other kind of proxy.

    SOCKS5 carries credentials as length prefixed bytes in its own handshake
    rather than as a header, so there is nowhere for `headers` to hold them and
    they have to survive as themselves. An HTTP proxy's credentials do not end
    up here: they become a `Proxy-Authorization` in the constructor and the
    plaintext is not kept, because a field that holds a password is one more
    place a password can be printed from.
    """

    var password: String
    """The SOCKS5 password. See `username`."""

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
        var socks = scheme == "socks5" or scheme == "socks5h"
        if not socks and scheme != "http" and scheme != "https":
            raise new_error(
                ErrorKind.UNSUPPORTED_PROTOCOL,
                String(
                    "'",
                    scheme,
                    (
                        "' is not a proxy scheme this client speaks, expected"
                        " http, https, socks5 or socks5h"
                    ),
                ),
            )

        self.headers = headers^
        self.username = String()
        self.password = String()
        var username = url.username()
        var password = url.password()
        if username != "" or password != "":
            if socks:
                self.username = username^
                self.password = password^
            elif PROXY_AUTHORIZATION not in self.headers:
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
        out.username = self.username.copy()
        out.password = self.password.copy()
        return out^

    def __init__(out self):
        """An empty proxy, for `copy` to fill in. Not useful on its own."""
        self.url = URL()
        self.headers = Headers()
        self.username = String()
        self.password = String()

    def origin(self) raises -> Origin:
        """Where the connection to the proxy goes.

        `proxy_origin_for` rather than `origin_for` because a proxy may be a
        scheme no request could name. This is not always what the pool keys the
        connection under: for a tunnel of either kind the key is the target,
        since that is what is on the far end.
        """
        return proxy_origin_for(self.url)

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
    """Where the socket goes, how it gets there, and what the request line says.

    The answers come apart the moment a proxy is involved. A forwarded request
    connects to the proxy and names the server in its request target. A tunnelled
    one connects to the proxy and then reaches the server, and its request target
    is an ordinary path again. Returned together because working one out without
    the other is how a request ends up asking a proxy for `/path`, which every
    proxy answers with a 400.
    """

    var origin: Origin
    """The far end of the connection, and the key a pool files it under.

    The server for a direct request and for a tunnel, the proxy for a plain
    http request being forwarded. A tunnel is keyed by the server because that
    is what it reaches: it is a private pipe to one host, and handing it to a
    request for a different host would send that request somewhere it never
    asked to go. A forwarding connection is keyed by the proxy because that is
    what it reaches too, and any other request through the same proxy can use it.
    """

    var form: TargetForm
    """The request target shape to write."""

    var connect_via: Optional[Origin]
    """The proxy to open a tunnel through, when there is one.

    Nothing on a direct request and nothing on a plain http request being
    forwarded, because neither of those tunnels. When it is set the socket goes
    to this address, the handshake on it names `origin`, and everything after
    that is between us and `origin` with the proxy relaying bytes it cannot read.

    Which handshake is read off the scheme here. An `http` proxy means a
    `CONNECT`, a `socks5` one means the RFC 1928 exchange, and the difference
    stops at the pool: everything above it sees a socket that reaches the target.
    """

    def __init__(
        out self,
        origin: Origin,
        form: TargetForm,
        var connect_via: Optional[Origin] = None,
    ):
        self.origin = origin
        self.form = form
        self.connect_via = connect_via^


def route_through(
    proxy: Optional[Proxy], mut request: Request, form: TargetForm
) raises -> Hop:
    """Decide the hop for one request, and put on it whatever the hop needs.

    Four outcomes. Without a proxy this is the identity: connect to the server
    named in the URL and write the path. With a proxy and an `http://` target the
    connection goes to the proxy, the request line carries the whole URL so the
    proxy knows what to fetch, and the proxy's own headers go on. With a proxy and
    an `https://` target neither of those would work, because the request is about
    to be encrypted and the proxy could not read the URL if it wanted to, so the
    hop says to open a tunnel and the request is left exactly as it was. And with
    a SOCKS proxy the target's scheme does not come into it, because a SOCKS proxy
    relays bytes rather than reading requests, so everything tunnels.

    `Proxy-Authorization` is added here, below the event hooks and the auth flow,
    because it belongs to this hop rather than to the request the caller wrote,
    and a hook that logged the request should not be printing the credential for
    the proxy.

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
    var hop_origin = via.origin()

    if hop_origin.is_socks():
        # No `via.apply` and no rewritten request line. A SOCKS proxy is finished
        # with before the first byte of HTTP goes out, so the request that
        # travels is the one the caller wrote, addressed to the server exactly as
        # it would be without a proxy at all.
        return Hop(target, form, Optional(hop_origin))

    if target.is_secure():
        if hop_origin.is_secure():
            # Refused here rather than when the socket is opened, so that
            # nothing has been evicted from a pool for a connection that was
            # never going to be made.
            raise new_error(
                ErrorKind.UNSUPPORTED_PROTOCOL,
                String(
                    "reaching ",
                    target,
                    " through the https proxy at ",
                    hop_origin,
                    (
                        " needs TLS inside TLS, which this client cannot do"
                        " yet, so an https target needs an http:// proxy"
                    ),
                ),
            )

        # A tunnel, and deliberately without `via.apply`. The proxy's headers go
        # on the CONNECT that opens the pipe, and putting them on the request
        # inside it as well would send the proxy's password end to end to a
        # server that has no business seeing it. The pool reads them off its own
        # `proxy` when it opens the tunnel.
        return Hop(target, form, Optional(hop_origin))

    via.apply(request)
    var wire = form
    if wire == TargetForm.ORIGIN:
        wire = TargetForm.ABSOLUTE
    return Hop(hop_origin, wire)
