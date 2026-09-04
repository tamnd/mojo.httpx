# Advanced usage

[QuickStart](quickstart.md) covers sending a request and reading the answer. This page is everything a `Client` can be configured to do, in roughly the order you run into it.

## Client instances

A `Client` holds a connection pool, a cookie jar, and the defaults every request it sends inherits. Keeping one is the difference between one round trip and three or four, because a connection stays open and a TLS handshake happens once.

```mojo
import httpx
from httpx import URL, Headers, Limits, Timeout


def main() raises:
    var headers = Headers()
    headers["User-Agent"] = "my-app/1.0"

    with httpx.Client(
        base_url=URL("https://api.example.com"),
        headers=headers^,
        timeout=Timeout.uniform(10.0),
        limits=Limits(max_connections=50, max_keepalive_connections=10),
        follow_redirects=True,
        http2=True,
    ) as client:
        print(client.get("/items").status_code)
```

Leaving the `with` block closes the pool. If the client's lifetime does not fit a block, call `client.close()` yourself, and remember that a client is destroyed at its last use rather than at the end of the scope, which is the one Mojo rule that catches people out here. [Mojo notes](mojo.md) has that in full.

`base_url` is joined with the path on each call using the ordinary URL rules, so `/items` on a base of `https://api.example.com/v1` gives `https://api.example.com/items` and `items` gives `https://api.example.com/v1/items`. That is standard relative resolution and it is what httpx2 does too. Pass an absolute URL to any method and the base is ignored.

Headers, cookies and query parameters given to the client are merged with the ones given to a call, with the call winning on a name they share. `timeout`, `auth` and `follow_redirects` given to a call replace the client's for that call only.

## Connection pooling

```mojo
from httpx import Client, Limits


def main() raises:
    var limits = Limits(
        max_connections=100,
        max_keepalive_connections=20,
        keepalive_expiry=5.0,
    )
    with Client(limits=limits) as client:
        print(client.get("https://example.com/").status_code)
```

`max_connections` is the ceiling on connections open at once across every host. A request that arrives with the pool full waits, and it waits under the `pool` timeout rather than forever, so a program that leaks responses fails with a pool timeout naming the problem instead of hanging.

`max_keepalive_connections` is how many idle connections are kept for reuse, and `keepalive_expiry` is how long an idle one is allowed to sit there in seconds. A connection older than that is closed rather than handed out, because the far end has usually closed it already and finding that out during a request is worse than opening a new one.

The defaults are httpx2's. Raising `max_connections` on a client that talks to one host mostly buys concurrency for the async client, since the synchronous one sends one request at a time.

## TLS

The defaults verify the chain, check the hostname, send SNI and refuse anything below TLS 1.2, with nothing to configure.

```mojo
from httpx import Client, ClientCert, SSLVerify


def main() raises:
    # A private CA.
    with Client(verify=SSLVerify.from_file("/etc/ssl/private-ca.pem")) as ca:
        print(ca.get("https://internal.example.com/").status_code)

    # A client certificate.
    var cert = ClientCert("/etc/ssl/client.pem", "/etc/ssl/client.key")
    with Client(cert=cert) as mtls:
        print(mtls.get("https://mtls.example.com/").status_code)
```

`SSLVerify.off()` exists and turns verification off for that client. It is the right answer roughly never, and the wrong answer with a private CA, which is what `from_file` is for. [TLS](tls.md) covers the defaults, where the trust store is found, and how to read a handshake failure.

## Authentication

```mojo
from httpx import Client, basic_auth, digest_auth, netrc_auth, no_auth


def main() raises:
    with Client(auth=basic_auth("alice", "s3cret")) as client:
        print(client.get("https://api.example.com/private").status_code)

        # Per request, which wins over the client's.
        var other = client.get(
            "https://api.example.com/other", auth=digest_auth("bob", "hunter2")
        )
        print(other.status_code)

        # And off, for one call, whatever the client was built with.
        var open = client.get("https://api.example.com/open", auth=no_auth())
        print(open.status_code)
```

Digest costs one extra round trip the first time, because there is nothing to answer until the server has sent a challenge, and none afterwards: the challenge is remembered and later requests go out authenticated straight away. The 401 that was answered stays in `r.history()`, the way a followed redirect does.

`netrc_auth()` reads `$NETRC` or `~/.netrc` once, when you build it, so a file that changes under a running program cannot give two requests in the same session two different identities.

`auth=("user", "pass")` from httpx2 is `auth=basic_auth("user", "pass")` here, because Mojo has no runtime type dispatch to fold a tuple overload back into the twenty methods that take an auth. Turning auth off for one call is `no_auth()` rather than `None`, because an absent `auth` already means take the client's.

A scheme of your own is a struct implementing `Auth`, wrapped with `erase_auth`. The trait is a state machine: it is handed the request, and it either signs it and stops or asks for the response and gets another turn, which is how digest answers a challenge and how anything token based can refresh.

Credentials are redacted everywhere this library writes a header out. Printing a `Headers`, a `Request` or a `Response` shows `[secret, 28 bytes]` in place of `Authorization`, `Proxy-Authorization`, `Cookie` and `Set-Cookie`. Asking for the value by name still gives you the value.

## Cookies

A client keeps a jar, so a login and the request after it are a session.

```mojo
from httpx import Client


def main() raises:
    with Client() as client:
        var login = client.post(
            "https://example.com/login", follow_redirects=True
        )
        print(login.status_code)

        # Seed one by hand, and read one back.
        client.cookies["preference"] = "dark"
        var page = client.get("https://example.com/account")
        print(client.cookies["session"], page.status_code)
```

`client.cookies` is a plain mutable field, so it can be seeded before the first request and read after any of them. `cookies=` on a single call merges over the client's for that call only. `r.cookies()` is the narrower question of what one response set, which is not the same as what the client is now holding.

RFC 6265 is followed rather than approximated. A cookie is scoped by domain, by path and by `Secure`, a `Set-Cookie` naming a domain the responding host does not belong to is dropped, so is one scoped to a public suffix, an expired one deletes rather than stores, and the `Cookie` header goes out ordered longest path first with creation time breaking ties, which is the order servers quietly depend on. A `Cookie` header you write yourself is left exactly as you wrote it.

## Redirects

```mojo
from httpx import Client


def main() raises:
    with Client() as client:
        # Off by default. Inspect the hop before taking it.
        var r = client.get("https://example.com/old")
        if r.is_redirect():
            print("would go to", r.next_request().url)

        # Or ask for them, per call or per client.
        var followed = client.get(
            "https://example.com/old", follow_redirects=True
        )
        print(followed.status_code, followed.url())
        for i in range(len(followed.history())):
            print(followed.history()[i].status_code)
```

`Authorization` is dropped when a hop crosses an origin, so no server can talk this client into handing your credentials to an address you never named. The chain is bounded, and going past the bound raises an error `is_too_many_redirects` recognises. `max_redirects=` on the client changes the bound.

The command line client follows redirects by default and the library does not. That is deliberate in both directions: the caller of a library is code that can check, and the caller at a prompt is a person who typed a URL and wants the page.

## Event hooks

Hooks are the seam for logging, metrics and tracing, without anything being subclassed or wrapped.

```mojo
import httpx
from httpx import EventHooks, Request, Response


def log_request(var request: Request) raises -> Request:
    print(">", request.method, request.url)
    return request^


def log_response(var response: Response) raises -> Response:
    print("<", response.status_code, response.request().url)
    return response^


def main() raises:
    var hooks = EventHooks()
    hooks.on_request(log_request)
    hooks.on_response(log_response)

    with httpx.Client(event_hooks=hooks^) as client:
        var r = client.get("https://example.com/", follow_redirects=True)
        print(r.status_code)
```

A hook takes the value and hands it back rather than being given a mutable reference, because a thin function pointer cannot take a `mut` parameter in Mojo 1.0 and thin function pointers are what make a hook storable at all. Return what you were given unless you meant to change it.

A hook runs once per send, so a call that follows two redirects runs it three times and a digest handshake runs it twice. The request hook sees the request the transport is about to be handed, with the client's headers and cookies already on it. The response hook runs before the body has been read, so it can read it, stream it, or leave it alone. Raising from a hook stops the call and the error reaches the caller.

`client.event_hooks` is a plain mutable field, so hooks can go on after the client was built. A hook that has to remember something across calls is a struct implementing `RequestHook` or `ResponseHook`, added with `erase_request_hook`, and `state[T]()` reads it back afterwards.

## Testing without a network

Swap the transport rather than the library. Everything above the transport still runs, so redirects are still followed, cookies are still stored and sent, and auth still answers a challenge.

```mojo
from httpx import Client, MockRouter, Route, erase_transport


def main() raises:
    var router = MockRouter()
    router.add(Route.get("/users/1").respond_json(200, '{"name": "alice"}'))
    router.add(Route.post("/users").respond(201))
    router.add(Route.any().respond(404))

    var transport = erase_transport(router^)
    var handle = transport.copy()

    var client = Client(transport^)
    var r = client.get("https://api.example.com/users/1")
    print(r.status_code, r.json()["name"].as_string())

    ref seen = handle.state[MockRouter]()
    print(seen.routes[0].call_count())
    print(String(seen.calls[0].url))
```

A route written as a path matches that path on any host, and one written as an absolute URL pins the scheme, host and port too. `with_params` and `with_headers` narrow it further, and both are subset matches, so a tracking parameter the test does not care about does not stop the match. `respond` called more than once queues the answers and the last one repeats, which is how a fail once then succeed retry gets tested. A request matching no route raises and says what it was, rather than answering 404 and turning a typo into a puzzle somewhere else.

The recording is the other half. `router.calls` is every request that reached the router, `route.calls` is what each route answered, `called()` and `call_count()` sit on top, and `assert_all_called()` catches a route whose pattern was wrong. Taking a `copy()` of the erased transport before handing it to the client is how any of that is read back, because a copy is the same transport.

`MockTransport` is the simpler one: a single function that answers everything, for when the reply depends on the request.

## Custom transports

A transport is the seam below the client and above the socket. Implement `Transport` and you get retries, caching, recording, rate limiting or anything else, with the whole client still running on top.

```mojo
from httpx import (
    Client,
    Deadlines,
    HTTPTransport,
    Request,
    Response,
    Transport,
    erase_transport,
)


struct CountingTransport(Transport):
    var inner: HTTPTransport
    var sent: Int

    def __init__(out self) raises:
        self.inner = HTTPTransport()
        self.sent = 0

    def handle_request(
        mut self, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        self.sent += 1
        return self.inner.handle_request(request^, deadlines)

    def handle_stream(
        mut self, var request: Request, deadlines: Deadlines
    ) raises -> Response:
        self.sent += 1
        return self.inner.handle_stream(request^, deadlines)

    def close(mut self):
        self.inner.close()


def main() raises:
    var transport = erase_transport(CountingTransport())
    var handle = transport.copy()

    with Client(transport^) as client:
        print(client.get("https://example.com/").status_code)

    print(handle.state[CountingTransport]().sent)
```

`erase_transport` is how a concrete transport becomes the one type a client holds. Mojo has no trait objects, so the erasure is a reference counted box with a vtable, and `state[T]()` is how you get the concrete value back. `AsyncTransport` is a second trait rather than a method on the first, because the async one has `handle_many` and the synchronous one never will: a transport with nothing to wait for has nothing to overlap.

## Routing to different transports

`mounts=` splits traffic by URL pattern, so some hosts go through a proxy and the rest go direct, one domain is answered by a mock while everything else goes out for real, and a scheme can be refused outright.

```mojo
from httpx import (
    Client,
    HTTPTransport,
    MockRouter,
    Mounts,
    Route,
    blocked,
    erase_transport,
)


def main() raises:
    var mock = MockRouter()
    mock.add(Route.any().respond_json(200, '{"stub": true}'))

    var routes = Mounts()
    routes.mount("all://test.example.com", erase_transport(mock^))
    routes.mount("http://", blocked())

    with Client(mounts=routes^) as client:
        print(client.get("https://test.example.com/x").json()["stub"].as_bool())
```

Patterns are matched most specific first, and the order is settled as each entry goes in rather than recomputed on the first request. `bypass` is httpx2's `None` entry, which sends those requests to the client's own transport and is the no proxy escape hatch. `blocked()` is the thing httpx2 has no spelling for at all: a transport that refuses, naming the URL it would not send.

A pattern with a path on it raises, because routing looks at the scheme, host and port and there is no reading of a path that would work. An IPv6 address wants brackets, `all://[::1]`, because the unbracketed form parses as a host and a port and matches nothing ever.

## Proxies

```mojo
from httpx import Client, Proxy


def main() raises:
    with Client(proxy=Proxy("http://localhost:3128")) as http:
        print(http.get("https://example.com/").status_code)

    with Client(proxy=Proxy("socks5://localhost:1080")) as socks:
        print(socks.get("https://example.com/").status_code)
```

An `http://` target is sent through in absolute form and an `https://` one gets a `CONNECT` tunnel, with the TLS handshake running inside the tunnel to the real server and its real certificate. `Proxy-Authorization` is built from any credentials in the proxy URL. SOCKS5 works with both the no auth and the username and password methods, and the target's name is resolved at the proxy rather than locally.

`HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` and `NO_PROXY` are read from the environment unless `trust_env=False`, with curl's matching rules for `NO_PROXY` including address ranges, and with the CGI check that stops a request header from choosing where a server sends its own traffic. [Proxies](proxies.md) has the wire level detail and the interop matrix.

## Text encoding

```mojo
from httpx import Client, DefaultEncoding


def main() raises:
    with Client(default_encoding=DefaultEncoding("iso-8859-1")) as client:
        print(client.get("https://legacy.example.com/report.txt").text())
```

`r.text()` uses the charset the response named. When it named none, or named one nothing here can decode, `default_encoding` decides, and every response a client produces carries a copy of it. The default is UTF-8.

Setting it on the client rather than per call is worth it against an API that answers `text/plain` with no charset, because that answer is the same on every endpoint it has. `DefaultEncoding` also takes a function, which is the seam a statistical charset detector plugs into the way `charset_normalizer` does in httpx2. Nothing here ships one, because a bad detector is worse than none.

The set of encodings is smaller than Python's: UTF-8, UTF-16 and UTF-32 in both byte orders and with or without a mark, Latin-1, Windows-1252 and ASCII. A label outside that set falls back to `default_encoding` the way a missing label does. [Compatibility guide](deviations.md) says why the CJK code page tables are not in an HTTP client.

## Streaming a request body

`content_stream=` sends a body that is pulled as it is written, so a large upload never has to be in memory at once.

```mojo
from httpx import ByteSource, Client, Headers, erase_source


struct Counting(ByteSource):
    var left: Int

    def __init__(out self, chunks: Int):
        self.left = chunks

    def read_chunk(mut self) raises -> List[UInt8]:
        if self.left == 0:
            return List[UInt8]()
        self.left -= 1
        var line = String("a line of the upload\n")
        return List[UInt8](line.as_bytes())

    def close(mut self):
        self.left = 0

    def trailers(self) -> Headers:
        return Headers()


def main() raises:
    with Client() as client:
        var body = erase_source(Counting(1000))
        var r = client.post("https://example.com/upload", content_stream=body^)
        print(r.status_code)
```

A source returning an empty chunk is the end. The body goes out as `Transfer-Encoding: chunked`, unless you set a `Content-Length` in `headers=` yourself, which is worth doing when you know the size in advance and want the server to know it too. `trailers()` is read once the body has ended, for the fields that come after it, and returning an empty `Headers` is the right answer for a source that carries none.

A streaming body exists once, so `Request.copy()` on a request carrying one produces a copy with no body that remembers it is missing one, and sending that copy raises rather than quietly uploading nothing to a redirect target. Read the body into memory and use `content=` if it has to go more than once.

## Reading the response as it arrives

```mojo
from httpx import Client


def main() raises:
    with Client() as client:
        with client.stream("GET", "https://example.com/big.json") as r:
            r.raise_for_status()
            print(r.headers["content-type"])

            var chunks = r.iter_bytes(65536)
            var total = 0
            while chunks.has_next():
                total += len(chunks.next())
            print(total, chunks.num_bytes_downloaded())
```

`iter_raw` is the one that hands over the bytes exactly as they arrived, still compressed if they were compressed, which is the way past the decoded body size bound for a caller who genuinely downloads large things.

`num_bytes_downloaded` is on the iterator as well as on the response, because a response hands its stream to the iterator and cannot see another byte afterwards. For a progress bar, the iterator is what has the number.

A response the caller closes partway gives its connection up rather than pooling it, because the rest of the body is still on the wire and a connection whose next byte is the middle of somebody else's response is not one to hand to the next request.

## Errors

Every failure is one `Error`, and httpx2's class hierarchy is a set of predicates rather than types to catch.

```mojo
import httpx


def main() raises:
    with httpx.Client() as client:
        try:
            print(client.get("https://example.com/").status_code)
        except e:
            if httpx.is_connect_timeout(e):
                print("could not get there in time")
            elif httpx.is_timeout(e):
                print("some phase ran out of time")
            elif httpx.is_transport_error(e):
                print("the network:", httpx.message_of(e))
            else:
                print(httpx.kind_of(e).name(), httpx.message_of(e))
```

The predicates nest the way the classes do, so ask the specific one first. `kind_of(e).name()` gives back httpx2's class name, so a log line reads the same in both libraries, and `message_of(e)` is the message without the kind prefix on the front.

`new_error(kind, message)` is how a transport or an auth scheme of your own raises something the predicates recognise, rather than a bare error that answers no question truthfully.

## Where to go next

[Async support](async.md) for `AsyncClient` and `gather`. [Compatibility guide](deviations.md) for anything that behaved differently from what httpx2 taught you to expect. [API reference](api.md) for the exact signature of everything named on this page.
