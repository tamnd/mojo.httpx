# Roadmap

Ten milestones. They are sequenced so each one ends with something that demonstrably works end to end, rather than a pile of layers that only integrate at the finish. Every milestone has a tracking issue and a GitHub milestone.

There are no dates. This is a spare time project on a language that still changes between releases, so a date would be fiction. The ordering is real and the exit criteria are real.

## M0 Foundations

The FFI layer, the error type, and the byte span conventions that everything else is written against. CI running the full matrix on macOS and Linux, plus the toolchain probes that tell us when a new Mojo release breaks an assumption.

Exit: a green build on all three platforms, and a probe suite that fails loudly on language drift.

## M1 Primitives

`URL`, `QueryParams`, `Headers` and `Cookies`, complete and correct. IDNA 2008 and percent encoding conformance against the Unicode and Web Platform Tests corpora.

Exit: the WHATWG URL test data passes, the IDNA test data passes, and the cookie matching rules pass the Public Suffix List cases.

## M2 Sync HTTP/1.1 over TCP

The first milestone with a user visible API. Sockets, DNS with Happy Eyeballs, the connection pool, the HTTP/1.1 state machine, chunked transfer coding, keep alive, and the four way timeout.

Exit: `httpx.get("http://example.com")` returns a parsed response, and the request smuggling tests pass.

## M3 TLS

OpenSSL bound over FFI, using the OpenSSL that already ships inside the Mojo distribution. Certificate verification, SNI, ALPN, custom CA bundles, and client certificates.

Exit: `https://` works, and every badssl.com case is rejected or accepted correctly.

## M4 Full client surface

All the verbs, redirects with history and cross origin credential stripping, the auth flow including Basic and Digest, every content type including multipart, streaming in both directions, event hooks, and `MockTransport`.

Exit: httpx2 parity for HTTP/1.1, measured by the parity suite comparing bytes on the wire.

## M5 HTTP/2

Framing, HPACK with a bounded decoder, flow control, multiplexing, and ALPN negotiation. The attack surface here is larger than the rest of the project put together, so the security tests land with the feature rather than after it.

Exit: the HPACK vectors pass, the h2 test suite passes, and the CONTINUATION flood, HPACK bomb and rapid reset cases are all bounded.

## M6 Async

An event loop on kqueue and epoll, and `AsyncClient` at feature parity with `Client`.

This is the riskiest milestone. Mojo has `async def` and `await` but no executor and no async I/O, and `Coroutine` is a linear type that cannot be stored or scheduled. The milestone opens with a go or no go on whether the language can support a real loop yet. If it cannot, the fallback is a thread pool behind the same API, so user code does not change when the real thing lands.

Exit: `AsyncClient` passes the same test suite as `Client`, or the fallback ships with the limitation documented.

## M7 Proxies and codecs

HTTP proxies, CONNECT tunnelling, SOCKS5, per pattern mounts, and the brotli and zstd codecs loaded at runtime so a missing library degrades instead of failing.

Exit: the proxy interop tests pass against Squid, tinyproxy and Dante.

## M8 CLI and docs

The `httpx` binary matching httpx2's CLI flag for flag, and the documentation site with a generated API reference. Every code example in the docs is compiled in CI and the offline ones are executed.

Exit: the CLI golden output tests pass, and no example in the docs fails to compile.

## M9 1.0

Conformance green, performance targets met, and the semver commitment.

Exit: the release checklist passes end to end on every supported platform.

## After 1.0

HTTP/3 is not in httpx2 so it is not in scope here, but the transport ABI reserves room for it so it can be added without a breaking change. The same is true of the connection upgrade path that WebSockets would need.
