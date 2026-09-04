# Proxies

A forward proxy is the oldest thing in HTTP that is still in daily use, and on a corporate network it is not optional. The client opens a connection to the proxy instead of to the server, writes the whole URL in the request line rather than just the path, and the proxy makes the real request and hands the answer back.

An `https://` request cannot work that way, because there is no URL for the proxy to read, so it asks for a tunnel instead. Both are here.

This page describes what works now. [limitations.md](limitations.md) has the list of what does not, and [roadmap.md](roadmap.md) says when the rest lands.

## Sending everything through a proxy

```mojo
import httpx
from httpx import Client, Proxy

def main() raises:
    var through = Proxy("http://localhost:3128")
    with Client(proxy=Optional[Proxy](through^)) as client:
        var r = client.get("http://example.com/")
        print(r.status_code)
```

`AsyncClient` takes the same argument and does the same thing with it.

`proxy` is a `Proxy` rather than a string because building one parses a URL, and parsing can fail. httpx2 accepts either and sorts it out at runtime, which Mojo cannot do, so the one extra call is the cost of the error arriving where the mistake was made.

## Credentials

A proxy that wants credentials is answered with `Proxy-Authorization`, which is not `Authorization`. The first authenticates the client to the proxy and is consumed there. The second is for the server at the far end and passes through untouched. Sending one where the other belongs either fails to authenticate or hands the server's password to the proxy.

The usual way to carry proxy credentials is inside the proxy URL, because that is how `HTTP_PROXY` carries them:

```mojo
var through = Proxy("http://tam:hunter2@localhost:3128")
```

The credentials come straight back out of the URL and go into a `Proxy-Authorization: Basic ...` header. `through.url` is `http://localhost:3128/` and nothing anywhere else in this library ever sees the password. That matters because a proxy URL ends up in request lines, in log output and in whatever a user pastes into an issue, and a URL that still had the password in it would take it to all three.

Printing a `Proxy` prints the URL and not the headers, for the same reason.

A `Proxy-Authorization` set explicitly wins over anything in the URL:

```mojo
var headers = Headers()
headers["Proxy-Authorization"] = "Bearer opaque"
var through = Proxy("http://tam:hunter2@localhost:3128", headers^)
```

Whoever wrote the header meant it. Credentials in a URL are usually there because an environment variable put them there.

Any other header on a `Proxy` goes to the proxy on every request, and is not forwarded to the server, which is what httpx2's `Proxy(headers=...)` is for.

## What goes on the wire for a forwarded request

Two things change when an `http://` request goes through a proxy, and only two. A tunnelled request is different and has its own section below.

The request line carries the whole URL. `GET /items HTTP/1.1` becomes `GET http://api.example.com/items HTTP/1.1`, which is the absolute form in RFC 9112 section 3.2.2. A proxy needs it because it has no other way to know which server the request is for.

The `Host` header still names the server. RFC 9112 requires the two to agree about the origin, and a `Host` naming the proxy would produce a request the server routes to the wrong virtual host.

Everything else is the request the caller wrote. Cookies, `Authorization`, the body and the content type all go through unchanged.

`Proxy-Authorization` is added at the connection pool, below the event hooks and below the auth flow. That is deliberate and it is where httpx puts it too: the header belongs to the hop in front rather than to the request, so a hook that logs every request does not print the credential for the proxy.

## The proxy is a property of the pool

A client either has a proxy or it does not, and the choice is fixed when the client is built. That is httpcore's arrangement.

The reason is connection reuse. A pool files its idle connections by origin, and every forwarded request through a proxy goes to the same address whatever server it is aimed at. A pool that proxied some requests and not others would either file the proxy and the server under keys that do not tell them apart, which hands a proxy connection to a direct request, or file them apart and lose the reuse that makes the proxy path fast.

The visible consequence is a good one. Two requests to two different servers through one proxy share one connection.

A tunnel is filed under the server instead, and that is the same rule rather than an exception to it: a connection is keyed by what is on the far end of it, and the far end of a tunnel is the server.

Mixing proxied and direct traffic is what `mounts=` is for, and that is not here yet.

## `https://` through a tunnel

Nothing to configure. The same `proxy=` covers it, and the client picks the tunnel because the target is `https://`.

```mojo
var through = Proxy("http://localhost:3128")
with Client(proxy=Optional[Proxy](through^)) as client:
    var r = client.get("https://example.com/")
```

What happens on the wire is `CONNECT example.com:443 HTTP/1.1`, with a `Host` naming the same authority and the proxy's own headers on it. The proxy opens a TCP connection to the server, answers `200 Connection established`, and from that point copies bytes in both directions without reading them. The TLS handshake then runs inside the pipe, to the real server, and the certificate that comes back is the server's own.

That last part is the whole point and it is worth being explicit about. The proxy is not in the trust path. It never sees the URL, the headers, the body or the response, and a proxy that tried to substitute its own certificate would fail verification like any other party in the middle. What a proxy does see is the host and port in the CONNECT, which it has to.

Three things follow from how a tunnel works, and they are all visible:

`Proxy-Authorization` goes on the CONNECT and nowhere else. The credential authenticates this hop, the proxy consumes it, and it never enters the tunnel. A copy of it inside would travel end to end to a server that has no business seeing the proxy's password.

A tunnel is pooled under the server rather than under the proxy. Two `https://` requests to the same server through the same proxy share one tunnel, which saves a CONNECT round trip and a full TLS handshake. Two requests to different servers cannot share one, because a tunnel reaches exactly one host.

A proxy that refuses raises rather than returning a response, and the message names the status:

```
the proxy answered 407 Proxy Authentication Required to the CONNECT for
example.com:443, so it wants credentials: put them in the proxy URL or set
Proxy-Authorization on the Proxy
```

There is nowhere for that to arrive as a `Response` the way a refused forwarded request does. A 407 to a CONNECT means the tunnel was never opened, so there is no channel for a response to come back through and nothing for `raise_for_status` to act on.

### An `https://` proxy is not the same thing

`Proxy("https://...")` means TLS to the proxy itself, which is a separate question from whether the target is `https://`. Forwarding a plain `http://` request over one works. Tunnelling through one does not, because it would mean a TLS session inside a TLS session, and the stream layer here wraps a socket rather than another stream. It raises and says so.

Almost nobody needs it. All an `https://` proxy adds to a tunnel is encryption on the hop between the client and the proxy, and the only thing that hop carries in the clear is the host and port in the CONNECT, which the proxy has to be told anyway. Everything after the 200 is already encrypted end to end.

## Environment variables

`HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` and `NO_PROXY` are ignored. A proxy has to be passed in code. `trust_env` reaches the TLS trust store and nothing else so far. Reading the environment is M7 and comes with the `NO_PROXY` matching rules and with the httpoxy check, which is the one where a CGI process reads `HTTP_PROXY` out of a request header called `Proxy` and sends its traffic wherever the attacker said.

## Testing

`tests/server/proxy.py` is a real forward proxy in about three hundred lines, and `tests/unit/test_proxy.mojo` runs requests through it to `tests/server/server.py`. The proxy refuses an origin form request target with a 400 rather than guessing what was meant, so a passing test is proof the absolute form went out rather than proof that something lenient let it through.

It also answers with three headers that no real proxy sends. `X-Proxy-Target` is the absolute URL that arrived in the request line, `X-Proxy-Auth` is the `Proxy-Authorization` that came with it, and `X-Proxy-Conn` is an id for the client connection, which is how the reuse test can see that two requests shared one.

The tunnel tests run against `tests/server/server.py --tls`, which is the same server behind the self signed certificate in `tests/fixtures/tls`. None of them turns verification off. A test that did would pass just as happily against a client that never checked anything, which is the one property the tunnel tests exist to establish. The absence of `X-Proxy-Target` on a tunnelled response is what says it was tunnelled: the proxy adds that header to everything it forwards and to nothing it relays blind.

Squid, tinyproxy, Dante and mitmproxy on the local fleet are the interop checks for the milestone. [testing.md](testing.md) covers the fleet.
