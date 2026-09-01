# mojo.httpx

A full featured HTTP client for Mojo, with the same API and the same developer experience as [httpx2](https://github.com/pydantic/httpx2).

**Status: pre-alpha.** HTTP/1.1 requests work over TCP and over TLS today, so `http://` and `https://` both work. Streaming works: `client.stream()` returns as soon as the head has arrived and the body is read off the wire a chunk at a time with `iter_bytes`, `iter_text` or `iter_lines`. HTTP/2, redirects, auth and cookies do not exist yet. See the [roadmap](docs/roadmap.md) for what is landing and when. Do not use this in production.

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

Keep a `Client` as soon as there is a second request, because a client holds its connections open and the one shot helpers do not.

```mojo
import httpx
from httpx import Client, Headers, Timeout, URL

def main() raises:
    var headers = Headers()
    headers["Authorization"] = "Bearer hunter2"

    var slow = Timeout.uniform(Optional[Float64](30.0))

    with Client(
        base_url=URL("https://api.example.com"), headers=headers^, timeout=slow
    ) as client:
        var listing = client.get("/items")
        print(listing.status_code)

        var content = List[UInt8]()
        content.extend('{"name": "widget"}'.as_bytes())
        var created = client.post("/items", content=content^)
        print(created.status_code)
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

Streaming, redirects, cookies, auth, proxies, multipart uploads, event hooks, custom transports and a `MockTransport` for tests all work the way they do in httpx2.

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
| `async with AsyncClient()` | explicit `await client.aclose()` | Mojo has no async context managers |
| generator based iterators | iterator structs | Mojo has no generators |
| `**kwargs` config | typed builders | Mojo has no keyword argument packing |
| `timedelta` | `Duration` | no stdlib equivalent |

That is the short list. [Deviations](docs/deviations.md) has the full one, including the handful of places where copying httpx2 exactly was possible and we chose not to, and what the alternative was in each case.

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
- [JSON](docs/json.md) for reading a body, building one, and what the parser refuses
- [Deviations](docs/deviations.md) for every place this behaves differently from httpx2, and why
- [Roadmap](docs/roadmap.md) for milestones M0 through M9
- [Testing](docs/testing.md) for the test layers, the CI matrix, and the local hardware fleet

## License

Apache-2.0. See [LICENSE](LICENSE), and [NOTICE](NOTICE) for third party test material that keeps its own upstream license.
