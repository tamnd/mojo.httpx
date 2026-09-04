# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project follows [semantic versioning](https://semver.org/spec/v2.0.0.html).

Because Mojo is still moving, every release names the exact Mojo versions it was tested against, and a new Mojo minor version may need a patch release here.

## [Unreleased]

Nothing has been released yet. Everything below is what is on `main`, built and tested against Mojo 1.0.0 on macos-arm64, linux-x86_64 and linux-arm64.

### Added

Sockets, DNS and connecting. TCP over libc through FFI on both Linux and Darwin, non blocking with a deadline on every call, `getaddrinfo` resolution, and Happy Eyeballs style staggered connect racing the addresses a name resolves to.

TLS. OpenSSL 3.x opened by name at run time rather than linked, so a program that only speaks `http://` needs none of it. Certificate chain verification, hostname checking, SNI, ALPN, TLS 1.2 as the floor, client certificates, custom CA bundles by file or by hashed directory, and handshake failures reported with what to do about them rather than with OpenSSL's own wording.

HTTP/1.1. A sans-io state machine covering chunked framing, trailers, informational responses and keep alive, with the request smuggling defences on the machine rather than in the driver. Differentially fuzzed against h11.

HTTP/2 over TLS, offered with `Client(http2=True)` and used when the server agrees in the handshake. Framing, flow control, settings, HPACK with the full dynamic table. HPACK is differentially fuzzed against the `hpack` package. A connection carries one request at a time.

Connection pooling with per host and total limits, keepalive expiry, liveness checks before a connection is handed out, and eviction under the total limit.

The client. `Client`, the seven verb helpers, `request` and `stream`, `base_url`, merged headers and query parameters, cookies, timeouts split into connect, read, write and pool, opt in redirect following with history and cross origin credential stripping, event hooks, and `mounts=` for routing by URL pattern.

Bodies. `content=`, `text=`, `data=`, `files=`, `json=` and `content_stream=`, each carrying the content type that describes it, with two bodies at once raising and naming both. Multipart uploads. Response decoding for gzip, deflate, brotli and zstd, each through a library opened at run time, with `Accept-Encoding` naming only the ones that loaded and a bound on how large a decoded body may become.

Models. `URL` and `QueryParams` against the WHATWG suite, IDNA against the Unicode test suite, `Headers`, a `CookieJar` following RFC 6265 with the public suffix list, and a `Json` value with typed accessors.

Authentication. Basic, Digest, netrc, and an `Auth` trait for a scheme of your own.

Proxies. Forward proxying for `http://`, `CONNECT` tunnels for `https://` with the handshake running inside the tunnel to the real server, SOCKS5 with both authentication methods, proxy credentials, and `HTTP_PROXY` and friends read from the environment with curl's `NO_PROXY` rules.

Testing. `MockTransport` and `MockRouter` in the library rather than in a second package, so a test that never touches the network needs no extra dependency.

`AsyncClient`, over `http://`. Ordinary `with` blocks and ordinary calls, `gather` for sending several requests at once, streaming through `aiter_bytes` and the rest. It refuses `https://` rather than sending in the clear, because there is no async TLS handshake yet.

The `httpx` command line client, matching httpx2's flags, built with `pixi run cli`. Body only on stdout so it pipes, no decoration when stdout is not a terminal, colour off for `NO_COLOR` and `TERM=dumb`, the progress bar on stderr, and curl's exit codes. Startup is around 2 ms.

Documentation. Installation, QuickStart, Advanced usage, Async support, the compatibility guide, Mojo notes, Troubleshooting indexed by error message, and an API reference generated from `mojo doc` and committed. Every Mojo example in the docs is a whole program and is compiled in CI.

[Unreleased]: https://github.com/tamnd/mojo.httpx/commits/main
