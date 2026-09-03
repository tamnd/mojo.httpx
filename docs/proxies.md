# Proxies

A forward proxy is the oldest thing in HTTP that is still in daily use, and on a corporate network it is not optional. The client opens a connection to the proxy instead of to the server, writes the whole URL in the request line rather than just the path, and the proxy makes the real request and hands the answer back.

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

## What goes on the wire

Two things change when a request goes through a proxy, and only two.

The request line carries the whole URL. `GET /items HTTP/1.1` becomes `GET http://api.example.com/items HTTP/1.1`, which is the absolute form in RFC 9112 section 3.2.2. A proxy needs it because it has no other way to know which server the request is for.

The `Host` header still names the server. RFC 9112 requires the two to agree about the origin, and a `Host` naming the proxy would produce a request the server routes to the wrong virtual host.

Everything else is the request the caller wrote. Cookies, `Authorization`, the body and the content type all go through unchanged.

`Proxy-Authorization` is added at the connection pool, below the event hooks and below the auth flow. That is deliberate and it is where httpx puts it too: the header belongs to the hop in front rather than to the request, so a hook that logs every request does not print the credential for the proxy.

## The proxy is a property of the pool

A client either has a proxy or it does not, and the choice is fixed when the client is built. That is httpcore's arrangement.

The reason is connection reuse. A pool files its idle connections by origin, and every request through a proxy goes to the same address whatever server it is aimed at. A pool that proxied some requests and not others would either file the proxy and the server under keys that do not tell them apart, which hands a proxy connection to a direct request, or file them apart and lose the reuse that makes the proxy path fast.

The visible consequence is a good one. Two requests to two different servers through one proxy share one connection.

Mixing proxied and direct traffic is what `mounts=` is for, and that is not here yet.

## `https://` through a proxy

Not yet. It raises, and the message names what is missing:

```
reaching https://example.com through the proxy at http://localhost:3128/ needs a
CONNECT tunnel, which this client cannot open yet, so only http:// targets can go
through a proxy
```

An `https://` target cannot use the absolute form, because the proxy would have to read a request it has no key for. What happens instead is `CONNECT host:port`, which asks the proxy to open a raw pipe to the server, after which the TLS handshake runs through the pipe end to end and the proxy sees nothing but ciphertext. The request writer already knows how to write that request line. What is missing is running a handshake over a stream that already has bytes on it. That is the next piece of M7.

Raising is the only honest answer in the meantime. The alternative is sending the request to the proxy in the clear, on a URL whose whole point was that it would not be.

## Environment variables

`HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` and `NO_PROXY` are ignored. A proxy has to be passed in code. `trust_env` reaches the TLS trust store and nothing else so far. Reading the environment is M7 and comes with the `NO_PROXY` matching rules and with the httpoxy check, which is the one where a CGI process reads `HTTP_PROXY` out of a request header called `Proxy` and sends its traffic wherever the attacker said.

## Testing

`tests/server/proxy.py` is a real forward proxy in about two hundred lines, and `tests/unit/test_proxy.mojo` runs requests through it to `tests/server/server.py`. The proxy refuses an origin form request target with a 400 rather than guessing what was meant, so a passing test is proof the absolute form went out rather than proof that something lenient let it through.

It also answers with three headers that no real proxy sends. `X-Proxy-Target` is the absolute URL that arrived in the request line, `X-Proxy-Auth` is the `Proxy-Authorization` that came with it, and `X-Proxy-Conn` is an id for the client connection, which is how the reuse test can see that two requests shared one.

Squid, tinyproxy, Dante and mitmproxy on the local fleet are the interop checks for the milestone. [testing.md](testing.md) covers the fleet.
