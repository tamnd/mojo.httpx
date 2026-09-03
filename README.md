# mojo.httpx

A full featured HTTP client for Mojo, with the same API and the same developer experience as [httpx2](https://github.com/pydantic/httpx2).

**Status: pre-alpha.** HTTP/1.1 requests work over TCP and over TLS today, so `http://` and `https://` both work. Streaming works in both directions: `client.stream()` returns as soon as the head has arrived and the body is read off the wire a chunk at a time with `iter_bytes`, `iter_text` or `iter_lines`, and `content_stream=` sends a request body that is pulled as it is written. HTTP/2 works over TLS when you ask for it with `Client(http2=True)`, which offers `h2` in the handshake and speaks it if the server agrees, though a connection still carries one request at a time rather than multiplexing. See the [roadmap](docs/roadmap.md) for what is landing and when. Do not use this in production.

## Why

Mojo has no HTTP client and no networking in the standard library. There is no socket module, no TLS module, no async runtime. So this project is not a thin wrapper over something that already exists. It is the whole stack: sockets over libc FFI, TLS over the OpenSSL that already ships inside the Mojo distribution, HTTP/1.1 and HTTP/2 framing, connection pooling, and the client API on top.

The target is httpx2's API rather than something new, for a simple reason. Millions of developers already know that API from `requests` and `httpx`, the design has had ten years of real use behind it, and copying it means people can move code between Python and Mojo without relearning anything.

## What works today

```mojo
import httpx

def main() raises:
    var r = httpx.get("https://example.com/")
    print(r.status_code, r.text())
```

That request verifies the certificate chain, checks the hostname, sends SNI and refuses anything below TLS 1.2, with nothing to configure. See [TLS](docs/tls.md) for private CAs, client certificates, and what the failure messages mean.

There is one of those helpers per verb, `get`, `head`, `options`, `delete`, `post`, `put` and `patch`, plus `request` for a method you name yourself and `stream` for a body you read as it arrives. They take everything that describes a single request, and they take `verify`, `cert` and `trust_env` as well, so a first request against a private CA is still one line.

Keep a `Client` as soon as there is a second request, because a client holds its connections open and the one shot helpers do not.

```mojo
import httpx
from httpx import Client, Headers, Json, Timeout, URL

def main() raises:
    var headers = Headers()
    headers["Authorization"] = "Bearer hunter2"

    var slow = Timeout.uniform(Optional[Float64](30.0))

    with Client(
        base_url=URL("https://api.example.com"), headers=headers^, timeout=slow
    ) as client:
        var listing = client.get("/items")
        print(listing.status_code)

        var payload = Json.object()
        payload.set("name", Json("widget"))
        var created = client.post("/items", json=payload^)
        print(created.status_code)
```

A body goes on with `content=` for bytes, `text=` for a string, `data=` for a form, `files=` for a multipart upload, `json=` for a document, or `content_stream=` for one pulled as it is written. httpx2 folds the first two into a single `content=` and tells them apart at runtime, which Mojo cannot do, so they are separate arguments.

```mojo
import httpx
from httpx import FileUpload, MultipartData, QueryParams

def main() raises:
    with httpx.Client() as client:
        var form = QueryParams().add("q", "mojo").add("page", "2")
        var found = client.post("https://example.com/search", data=form^)
        print(found.status_code)

        var files = MultipartData()
        files.add("caption", "on holiday")
        files.add_file(FileUpload("photo", "beach.jpg", "the jpeg bytes"))
        var sent = client.post("https://example.com/upload", files=files^)
        print(sent.status_code)
```

Each of those carries the content type that describes it, and an explicit `Content-Type` in `headers=` wins over it, so `json=` works against an API with its own media type. Passing two bodies raises and names both, rather than dropping one and letting you find out from the server, which is what httpx2 does with `data=` and `json=` together. The one combination that is allowed is `data=` with `files=`, which is not two bodies but one multipart body carrying the fields and the files, exactly as a browser sends it. [Request bodies](docs/content.md) covers all six.

On the way back, `r.status_code`, `r.text()`, `r.json()` and `r.content()` are the usual four. `r.raise_for_status()` turns anything outside 2xx into an `HTTPStatusError` naming the code, the phrase the server sent and the URL. `r.elapsed()` says how long the exchange took, as a `Duration`, once the body is in. `r.link_url("next")` reads the `Link` header a paginated API answers with and hands back somewhere to go, resolved against the URL the response came from.

```mojo
import httpx

def main() raises:
    with httpx.Client() as client:
        var url = String("https://api.example.com/items")
        while True:
            var r = client.get(url)
            r.raise_for_status()
            print(r.json(), r.elapsed().milliseconds())

            var next = r.link_url("next")
            if not next:
                break
            url = String(next.value())
```

A body too large to want in memory, or one that does not end, is read with `stream` instead.

```mojo
import httpx

def main() raises:
    with httpx.Client() as client:
        with client.stream("GET", "https://example.com/big.log") as r:
            var lines = r.iter_lines()
            while lines.has_next():
                print(lines.next())
```

The `with` around the response is not decoration. The connection that body is arriving on goes back to the pool when the body ends and is closed if the block is left before that, and both of those happen because the response was destroyed at the end of the block.

Both requests in the client block above go over one connection. `Timeout` holds a separate limit for connect, read, write and pool, because those four fail for different reasons and deserve different answers, and every one of them is a deadline that is checked all the way down to the socket call.

A redirect is not followed unless you ask for it, which is httpx2's default and the right one. A client that follows silently is a client that can be sent somewhere else without the caller ever knowing.

```mojo
import httpx

def main() raises:
    with httpx.Client(follow_redirects=True) as client:
        var r = client.get("https://example.com/old")
        print(r.status_code, r.url())

        var history = r.history()
        for i in range(len(history)):
            print(history[i].status_code, history[i].url())
```

`follow_redirects=` is also an argument on every request method, so one call can differ from the client it was made on. Left off, a 3xx comes back as it is and `r.next_request()` holds the request that would have been sent, which is how a caller inspects or rewrites a hop before taking it. `Authorization` is dropped when a hop crosses an origin, so no server can talk this client into handing your credentials to an address you never named.

Basic, digest and netrc authentication all work, on the client or on one request.

```mojo
import httpx
from httpx import basic_auth, digest_auth

def main() raises:
    with httpx.Client(auth=basic_auth("alice", "s3cret")) as client:
        var r = client.get("https://api.example.com/private")
        print(r.status_code)

        # And per request, which wins over whatever the client was given.
        var other = client.get(
            "https://api.example.com/other", auth=digest_auth("bob", "hunter2")
        )
        print(other.status_code)
```

Digest costs one extra round trip the first time, because there is nothing to answer until the server has sent a challenge, and none after that: the challenge is remembered and every later request goes out authenticated straight away. The 401 that was answered stays in `r.history()`, the same way a followed redirect does. `netrc_auth()` reads `$NETRC` or `~/.netrc` once, when you build it, so a file that changes under a running program cannot give two requests in the same session two different identities.

`auth=no_auth()` on a single call sends it unauthenticated, whatever the client was built with. httpx2 writes that as `auth=None`, which it can only do because it keeps a separate sentinel for an argument that was not passed at all. Here an absent `auth` already means take the client's, so switching it off has to be a value rather than an absence.

Credentials are redacted everywhere this library writes a header out. Printing a `Headers`, a `Request` or a `Response` shows `[secret, 28 bytes]` in place of `Authorization`, `Proxy-Authorization`, `Cookie` and `Set-Cookie`, so a debug print or a logged repr cannot leak a password. Asking for the value by name still gives you the value.

A client keeps a cookie jar, so a login and the request after it are a session rather than two unrelated calls.

```mojo
import httpx

def main() raises:
    with httpx.Client() as client:
        # Whatever the login sets is stored, including a Set-Cookie that
        # arrives on a 302 rather than on the page at the end of it.
        var login = client.post(
            "https://example.com/login", follow_redirects=True
        )
        print(login.status_code)

        # And goes back out on its own, to the hosts and paths it is scoped to.
        var page = client.get("https://example.com/account")
        print(client.cookies["session"])
        print(page.status_code)
```

The jar is `client.cookies` and it is a plain mutable field, so a caller can seed it before the first request with `client.cookies["session"] = "..."` and read it after any of them. `cookies=` on a single call merges over the client's for that call only. `r.cookies()` is the narrower question of what one response set, which is not the same thing as what the client is holding.

RFC 6265 is followed rather than approximated. A cookie is scoped by domain, by path and by `Secure`, a `Set-Cookie` naming a domain the responding host does not belong to is dropped, so is one scoped to a public suffix, an expired one deletes rather than stores, and the `Cookie` header is ordered longest path first with creation time breaking ties, which is the order servers quietly depend on. A `Cookie` header you write yourself is left exactly as you wrote it.

`r.text()` reads the body using the charset the response named. When it named none, or named one nothing can decode, the client's `default_encoding` decides, and every response a client produces carries a copy of it.

```mojo
import httpx
from httpx import DefaultEncoding

def main() raises:
    with httpx.Client(default_encoding=DefaultEncoding("iso-8859-1")) as client:
        var r = client.get("https://legacy.example.com/report.txt")
        print(r.text())
```

The default is UTF-8, which is what the content nearly always is and what httpx2 falls back to as well. Setting it on the client rather than on each call is worth it against an API that answers `text/plain` with no charset, because that answer is the same on every endpoint it has. `default_encoding` also takes a function, which is the seam a statistical charset detector plugs into, the way `charset_normalizer` does in httpx2. Nothing here ships one, because a bad detector is worse than none.

Event hooks are the seam for logging, metrics and tracing. A hook sees every request on its way out and every response on its way in, without anything having to be subclassed or wrapped.

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

A hook takes the value and gives it back rather than being handed a mutable reference, which is the one place the API differs from httpx2 and is forced by what a function pointer can carry in Mojo. Return what you were given unless you meant to change it. A hook runs once per send, so a call that follows two redirects runs it three times and a digest auth handshake runs it twice, and it sees the request the transport is about to be handed, with the client's headers and cookies already on it. A response hook runs before the body has been read, so it can read it, stream it or leave it alone. Raising from a hook stops the call and the error reaches the caller.

`client.event_hooks` is a plain mutable field, so hooks can go on after the client was built. A hook that needs to remember something across calls is a struct implementing `RequestHook` or `ResponseHook`, added with `erase_request_hook`, and `state[T]()` reads it back afterwards.

Tests of your own code swap the transport rather than the library. A `MockRouter` is a table of routes matched in order, and everything above the transport still runs, so redirects are still followed, cookies are still stored and sent, and auth still answers a challenge.

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

A route written as a path matches that path on any host, and one written as an absolute URL pins the scheme, host and port too. `with_params` and `with_headers` narrow it further, and both are subset matches, so a tracking parameter the test does not care about does not stop the match. `respond` called more than once queues the answers and the last one repeats, which is how a fail once then succeed retry gets tested. A request that matches no route raises and says what it was, rather than answering 404 and turning a typo into a puzzling failure somewhere else.

The recording is the other half. `router.calls` is every request that reached the router and `route.calls` is what each route answered, with `called()` and `call_count()` on top, and `assert_all_called()` catches a route whose pattern was wrong. Taking a `copy()` of the erased transport before handing it to the client is how you read any of that back afterwards, because a copy is the same transport. `MockTransport` is the simpler one: a single function that answers everything, for when the reply depends on the request.

`AsyncClient` is the same client over a pool that does not hold a runtime worker while a request waits on a socket. Everything is spelled the same, because it is the same code with a different transport in it.

```mojo
import httpx
from httpx import AsyncClient, URL

def main() raises:
    with AsyncClient(base_url=URL("http://api.example.com")) as client:
        var r = client.get("/users")
        print(r.status_code)
```

Sending several at once is `gather`, which is the point of any of it.

```mojo
import httpx
from httpx import AsyncClient, URL

def main() raises:
    with AsyncClient(base_url=URL("http://api.example.com")) as client:
        var pending = List[httpx.Request]()
        pending.append(client.build_request("GET", "/users/1"))
        pending.append(client.build_request("GET", "/users/2"))

        var answers = httpx.gather(client, pending^)
        for i in range(len(answers)):
            print(answers[i].status_code)
```

The answers come back in the order the requests went out. Everything the client does for one request it does for each of these: the hooks run per send, the cookie jar is read and written, redirects are followed for anyone who asked, and an auth scheme gets its retry. The first failure is raised and the rest are dropped, which is what `asyncio.gather` does unless told otherwise.

It takes a list rather than being something you assemble yourself, because Mojo 1.0.0 will not let a coroutine be stored in a variable or handed around, so there is no way to give you a request in progress. [async](docs/async.md) has the whole of that argument.

Streaming works the same way it does on the synchronous client, and the body comes out through `aiter_bytes`, `aiter_text`, `aiter_lines` and `aiter_raw`.

```mojo
from httpx import AsyncClient

def main() raises:
    with AsyncClient() as client:
        with client.stream("GET", "http://example.com/big.log") as r:
            var lines = r.aiter_lines()
            while lines.has_next():
                print(lines.next())
```

Each of those is the same call as the name without the `a`, because what differs between a synchronous stream and an async one is the source underneath and the iterator cannot tell which it has. The names exist so that code ported from httpx keeps its shape, and so do `aread` and `aclose` on a response.

One thing it will not do yet, and it says so rather than doing something almost right: `https://`, because there is no async TLS handshake. `close()` and `aclose()` are the same call, since nothing about closing a client suspends. See [async](docs/async.md) for the whole picture, including what Mojo 1.0.0 does and does not allow a coroutine to do.

## What it will look like

```mojo
from httpx import get, Client

def main() raises:
    var r = get("https://api.example.com/users")
    print(r.status_code)
    print(r.json()["users"][0]["name"].as_string())

    var client = Client(base_url="https://api.example.com", http2=True)
    var resp = client.post("/items", json={"name": "widget"})
    resp.raise_for_status()
```

Proxies, multipart uploads and custom transports all work the way they do in httpx2.

## Planned feature set

| Area | Scope |
| --- | --- |
| Protocols | HTTP/1.1 and HTTP/2, keep alive, pipelined multiplexing on h2 |
| TLS | OpenSSL 3.x via FFI, ALPN, SNI, mTLS, custom CA bundles |
| Client | Sync `Client`, async `AsyncClient`, top level one shot helpers |
| Pooling | Connection pool with per host and total limits, keepalive expiry |
| Timeouts | Separate connect, read, write and pool deadlines, enforced everywhere |
| Redirects | Opt in following, history, cross origin credential stripping |
| Auth | Basic, Digest, netrc, and a pluggable `Auth` state machine |
| Proxies | HTTP, CONNECT tunnelling, SOCKS5, per pattern mounts |
| Content | multipart, form encoding, JSON, gzip, deflate, brotli, zstd |
| Testing | `MockTransport` and `MockRouter`, no separate package needed |
| CLI | An `httpx` binary matching httpx2's CLI flag for flag |

## Differences from httpx2

Mojo is not Python, and a few things cannot be copied directly. Every deviation is deliberate and documented rather than accidental.

| httpx2 | mojo.httpx | Reason |
| --- | --- | --- |
| `r.json()` returns `Any` | returns a typed `Json` value with accessors | Mojo has no dynamic `Any` |
| `except httpx.TimeoutException` | `if httpx.is_timeout(e)` | Mojo has one error type and no exception subclassing |
| duck typed transports | a generic transport plus an erased vtable | Mojo has no trait objects |
| `async with AsyncClient()` | `with AsyncClient() as client` | Mojo has no async context managers, and nothing about closing a client suspends, so the ordinary one does the job. `aclose()` exists as a second name for `close()` |
| generator based iterators | iterator structs | Mojo has no generators |
| `**kwargs` config | typed builders | Mojo has no keyword argument packing |
| `timedelta` | `Duration` | no stdlib equivalent |

That is the short list. [Deviations](docs/deviations.md) has the full one, including the handful of places where copying httpx2 exactly was possible and we chose not to, and what the alternative was in each case.

The list is not maintained by hand alone. `pixi run -e parity parity` runs the same scenarios through both libraries against one recording server and compares the raw bytes each one put on the wire, hop by hop, plus what each made of an answer written by hand. Two differences are signed off today, both listed above; anything else fails the run, and so does a sign off that stops matching. See [testing](docs/testing.md).

## Requirements

Mojo 1.0.0 or newer. The project pins the exact toolchain in `pixi.toml`, because the language is still moving fast enough that building against a different version is a real source of confusion.

OpenSSL 3.0 or newer, for `https://`. It is loaded at runtime rather than linked, so there is no build step and no headers to install, and the copy that ships inside the Mojo toolchain's own environment is found first. Plain `http://` needs nothing.

| Platform | Status |
| --- | --- |
| macOS arm64 | Supported, tested in CI |
| Linux x86_64 | Supported, tested in CI and on real hardware |
| Linux arm64 | Supported, tested in CI |
| Windows | Under WSL2 only, tested on real hardware before each release |

Mojo has no native Windows build, so there is nothing to install on Windows directly. WSL2 works and is tested. That is a Modular limitation rather than one of ours.

## Development

```bash
git clone https://github.com/tamnd/mojo.httpx
cd mojo.httpx
pixi install
pixi run test
pixi run lint
```

Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request. It lists a small number of rules that are easy to break without noticing, such as parsing over byte spans rather than `String` and never issuing an I/O call without a deadline.

## Documentation

- [Architecture](docs/architecture.md) for the layer model and the design decisions behind it
- [TLS](docs/tls.md) for the defaults, custom CA bundles, client certificates, and reading a handshake failure
- [Request bodies](docs/content.md) for the six body arguments, the content type each implies, and why passing two raises
- [JSON](docs/json.md) for reading a body, building one, and what the parser refuses
- [Deviations](docs/deviations.md) for every place this behaves differently from httpx2, and why
- [Async](docs/async.md) for what Mojo's scheduler can and cannot do, measured, and the design that follows from it
- [Roadmap](docs/roadmap.md) for milestones M0 through M9
- [Testing](docs/testing.md) for the test layers, the CI matrix, and the local hardware fleet

## License

Apache-2.0. See [LICENSE](LICENSE), and [NOTICE](NOTICE) for third party test material that keeps its own upstream license.
