# Proxies

A forward proxy is the oldest thing in HTTP that is still in daily use, and on a corporate network it is not optional. The client opens a connection to the proxy instead of to the server, writes the whole URL in the request line rather than just the path, and the proxy makes the real request and hands the answer back.

An `https://` request cannot work that way, because there is no URL for the proxy to read, so it asks for a tunnel instead. SOCKS5 is a third shape that is not HTTP at all. All three are here.

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

Mixing proxied and direct traffic is what `mounts=` is for, and it does it by having more than one pool rather than by teaching one pool to do both. [Mounts](#mounts) below.

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

## SOCKS5

Same `proxy=`, different scheme:

```mojo
var through = Proxy("socks5://localhost:1080")
with Client(proxy=Optional[Proxy](through^)) as client:
    var r = client.get("https://example.com/")
```

`socks5h://` is accepted too and means the same thing here. In curl the `h` asks for the name to be resolved at the proxy, and this client does that either way, so the letter is accepted and not acted on. The port defaults to 1080 when the URL leaves it out.

A SOCKS5 proxy is not an HTTP proxy and almost everything above stops applying. It never reads the request. It is told a host and a port in a short binary handshake, RFC 1928, and after that it copies bytes. So there is no absolute request line, no `Proxy-Authorization`, and no difference between an `http://` target and an `https://` one: both tunnel, and what the server receives is byte for byte the request that would have gone to it directly.

The target's name goes over as a name, always, and this is the part worth being deliberate about. Resolving the host locally and sending the four bytes of the answer would work against every SOCKS proxy in existence, and it would also hand the destination to whoever is watching the local resolver, which is one of the main reasons people run a SOCKS proxy in the first place. An address is only sent when the caller typed an address, because then there was no name to leak.

Credentials work the way they do everywhere else, in the URL:

```mojo
var through = Proxy("socks5://tam:hunter2@localhost:1080")
```

They come out of the URL the same as for an HTTP proxy, but they do not become a header, because SOCKS has no headers. RFC 1929 carries them as length prefixed bytes in the handshake, so they are kept as themselves on the `Proxy` and used there. Two consequences are worth knowing. They are limited to 255 bytes each, which is what a single length byte can describe. And they go to the proxy in the clear, on that hop, which is what the method is: the alternative in the specification is GSSAPI, almost nothing implements it, and a client that refused the method every SOCKS proxy actually deploys would not be usable.

A proxy that says no raises, with a message for the particular no it said. RFC 1928 has eight refusal codes and the difference between them is the difference between fixing a rule and fixing a network:

```
the SOCKS5 proxy would not reach example.com:443: its rules do not allow that
destination
```

Pooling is worth one note. Everything through SOCKS is a tunnel, and a tunnel is filed under the server on the far end of it, so two requests to the same server reuse a connection and two requests to different servers cannot. A forwarding HTTP proxy is the opposite: every `http://` request through it goes to the same address, so they all share. That is not a setting, it is what the two protocols are.

The async client cannot do SOCKS yet, and says so rather than quietly connecting straight to the target. It opens its sockets inside a coroutine and has nowhere to put a handshake that has to finish first. The same is true of `CONNECT` tunnels, for the same reason.

## Mounts

A client has one transport, and `mounts=` is how it gets more than one. Each entry pairs a URL pattern with a transport, the request's URL is matched against the patterns from most specific to least, and the first one that matches wins. Nothing matched means the client's own transport.

```mojo
var routes = Mounts()
routes.mount("all://internal.example.com", erase_transport(HTTPTransport()))
with Client(mounts=routes^) as client:
    var inside = client.get("https://internal.example.com/health")
    var outside = client.get("https://example.com/")
```

The table is a `Mounts` value built a mount at a time rather than a dictionary literal, because Mojo has no literal that can hold a transport. Adding a mount parses its pattern and files it in search order there and then, so a typo is an error where it was written rather than a mount that silently never fires.

### The pattern language

A pattern is written as a URL and not as a bare scheme, so `http://` and not `http`. The trailing punctuation is not decoration: `http` on its own is ambiguous between a scheme and a host, and httpx rejects it for the same reason. The scheme, the host and the port are each optional, and an omitted one matches anything.

| Pattern | Matches |
| --- | --- |
| `all://` | every request |
| `http://` | every `http://` request |
| `all://example.com` | that host, on any scheme, on any port |
| `https://example.com` | that host over TLS |
| `all://*.example.com` | strict subdomains, so not `example.com` itself |
| `all://*example.com` | `example.com` and its subdomains |
| `all://*:8080` | anything on port 8080 |
| `https://example.com:444` | all three at once |
| `all://10.0.0.0/8` | every address in that range |
| `all://[fd00::]/8` | the same for IPv6 |

Hosts are compared case insensitively, a subdomain wildcard only matches at a label boundary so `all://*example.com` does not match `notexample.com`, and an IPv6 literal is written with brackets, `all://[::1]`.

A host that is an address is compared as a number rather than as text, so `all://127.0.0.1` also matches a URL written `http://0177.0.0.1/`, which is the same address to every resolver on the machine. A prefix length is the only thing allowed after the authority, and two patterns that both name a range are ordered by prefix length, the tighter one first.

A port that the scheme implies anyway is dropped when the pattern is parsed. `https://example.com:443` means every ordinary request to that host over TLS, not only the ones somebody spelled with a port on them, because a URL does not carry a default port once it has been parsed and a pattern that insisted on 443 would match nothing at all. That is httpx's reading of it too.

### The order they are tried in

Most specific first, and specific means what httpx means by it: a pattern naming a port beats one that does not, then a longer host beats a shorter one, then a longer scheme beats a shorter one. Patterns that tie are tried in the order they were added.

The host comparison is on the host as written, `*` included, which is what makes `all://*.example.com` beat `all://example.com`. That is worth knowing because it is not what a reader would guess: the more specific looking exact host loses to the wildcard. It is httpx's ordering and changing it would mean a configuration copied over from httpx routing somewhere else.

### `proxy=` is a mount underneath

`Client(proxy=...)` builds a proxied transport and mounts it on `all://`. The client's own transport is always the unproxied one. So a mount you add yourself for a particular host is tried first and wins, and mounting `all://` yourself replaces the proxy entirely.

That arrangement is not an implementation detail that could have gone the other way. It is the only one in which an entry saying "no transport for this pattern" means anything useful, because falling back to the client's own transport is the way out of a proxy, and if the client's own transport were the proxied one there would be no way out.

### Taking one host back out of the proxy

That way out is `bypass`, which is httpx's `mounts={"...": None}`:

```mojo
var routes = Mounts()
routes.bypass("all://internal.example.com")
with Client(proxy=Optional[Proxy](Proxy("http://localhost:3128")), mounts=routes^) as client:
    var direct = client.get("http://internal.example.com/health")
    var proxied = client.get("http://example.com/")
```

Everything still goes through the proxy except `internal.example.com`, which goes straight out. On a client with no proxy a bypass changes nothing, because the client's own transport is where an unmatched request was going anyway. This is the mechanism `NO_PROXY` will be built on.

### Refusing a scheme

Bypassing is not blocking, and the two are separate calls because a hole in a proxy rule and a wall are not the same instruction. Blocking is a transport that raises, mounted like any other:

```mojo
var routes = Mounts()
routes.mount("http://", blocked("plaintext is not allowed from this service"))
```

A request that lands on it fails with `the request to http://example.com/ was not sent, because plaintext is not allowed from this service`, at the call rather than at the socket, and nothing leaves the machine. The reason is optional and there is a default. A caller who wants different behaviour, counting what was refused for instance, writes their own `Transport` and mounts that, which is the point of blocking being a transport rather than a flag.

### Closing, and the async client

Closing the client closes every transport mounted on it, in the same call that closes its own. A transport handed to two clients is closed by whichever one goes first, which is the same rule as `transport=`.

`AsyncClient` takes `AsyncMounts`, holding async transports, and routes the same way. `gather` routes each request in a round after the event hooks have run, since a hook can rewrite the URL, and then sends one batch per distinct transport. Requests that land on different mounts therefore do not overlap each other, which is a cost of routing by URL, so a batch that wants everything in flight at once wants to be going to one transport.

## Environment variables

`HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` and `NO_PROXY` are read, and a client built with nothing configured picks them up:

```mojo
# HTTP_PROXY=http://localhost:3128 NO_PROXY=localhost,10.0.0.0/8
with Client() as client:
    var outside = client.get("http://example.com/")     # through the proxy
    var inside = client.get("http://10.1.2.3/health")   # straight out
```

Each one becomes a mount, which is the whole reason mounts exist: `HTTP_PROXY` is a proxy on `http://`, `HTTPS_PROXY` is one on `https://`, `ALL_PROXY` is one on `all://`, and every entry in `NO_PROXY` is a bypass. So everything in the previous section applies, and a mount written in code beats anything the environment asked for because it is added afterwards.

The environment is only read when the client would otherwise have no proxy at all. Passing `proxy=` or `transport=` turns it off for that client, and so does `trust_env=False`, which is also the switch for the TLS trust store.

### Which spelling wins

Each variable is looked up in lower case first and then in upper case, and the first one with something in it is the answer. An empty value counts as unset, because `HTTP_PROXY=` is how a script says not through a proxy.

Lower case first is curl's rule. Python's own `urllib.request.getproxies` instead lets whichever spelling appears later in the environment block win, which makes the answer depend on the order a shell happened to export things in.

### The httpoxy check

CGI puts every request header into the environment with an `HTTP_` prefix, so a request carrying a header called `Proxy` arrives in the process as `HTTP_PROXY`. A client that reads it is taking routing instructions from whoever sent the request, and what it then sends is the server's own outgoing traffic with the server's own credentials on it. That is CVE-2016-5385.

The mitigation is the one everybody settled on: when `REQUEST_METHOD` is set, which is the marker that says this process is answering a CGI request, the upper case `HTTP_PROXY` is ignored. The lower case `http_proxy` still works, because no CGI server produces that name. Only `HTTP_PROXY` is affected, since there is no header that turns into `HTTPS_PROXY` or `ALL_PROXY`.

### `NO_PROXY`

A comma separated list, matched the way curl matches it rather than the way any one RFC says, because there is no RFC.

| Entry | Means |
| --- | --- |
| `example.com` | that name and everything under it, so `www.example.com` as well |
| `.example.com` | everything under it and not `example.com` itself |
| `localhost` | that name alone |
| `10.0.0.1` | that address, however it is spelled in the URL |
| `10.0.0.0/8` | every address in that range |
| `::1` | that address, brackets added on the way in |
| `fd00::/8` | every address in that range |
| `example.com:8080` | that name on that port |
| `https://example.com` | already a mount pattern, used as written |
| `*` | proxying off entirely, whatever the other variables said |

A bare name covering its subdomains is worth knowing, because it is the one entry that does more than it looks like it does. A leading dot is how the list says the domain itself is not exempt.

A range is a real range here. httpx keeps the network address and throws the prefix length away, so `NO_PROXY=192.168.0.0/16` exempts one address rather than sixty five thousand of them, and traffic to the rest of the network keeps going through the proxy. That is the sort of thing nobody notices until a request that should have stayed inside did not.

## Testing

`tests/server/proxy.py` is a real forward proxy in about three hundred lines, and `tests/unit/test_proxy.mojo` runs requests through it to `tests/server/server.py`. The proxy refuses an origin form request target with a 400 rather than guessing what was meant, so a passing test is proof the absolute form went out rather than proof that something lenient let it through.

It also answers with three headers that no real proxy sends. `X-Proxy-Target` is the absolute URL that arrived in the request line, `X-Proxy-Auth` is the `Proxy-Authorization` that came with it, and `X-Proxy-Conn` is an id for the client connection, which is how the reuse test can see that two requests shared one.

The tunnel tests run against `tests/server/server.py --tls`, which is the same server behind the self signed certificate in `tests/fixtures/tls`. None of them turns verification off. A test that did would pass just as happily against a client that never checked anything, which is the one property the tunnel tests exist to establish. The absence of `X-Proxy-Target` on a tunnelled response is what says it was tunnelled: the proxy adds that header to everything it forwards and to nothing it relays blind.

`tests/server/socks5.py` is a SOCKS5 proxy written from the RFC, because Python has no SOCKS server anywhere in its standard library. Its `--resolve NAME=ADDRESS` switch is what the important test is built on: the test asks for a name that resolves nowhere, the proxy answers it from the table, and a response at all is proof the name travelled as a name rather than through the local resolver. Its `--bound` switch chooses the form of the bound address on a successful reply, which is the only variable length field in the exchange and so the only place a client can miscount and leave bytes on the socket.

Squid, tinyproxy, Dante and mitmproxy on the local fleet are the interop checks for the milestone. [testing.md](testing.md) covers the fleet.
