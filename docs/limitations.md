# Limitations

Everything this library does not do yet, or does less well than it should, collected in one place. The point of the page is that you find these out here rather than from a stack trace or from a request that quietly did something you did not ask for.

This is not the same page as [deviations](deviations.md). That one covers the places where the API differs from httpx2 while doing the same job, usually because Mojo has no generators or no keyword argument packing. This one is about things that are missing, and about behaviour that is worse than httpx2's rather than merely spelled differently.

Everything here is either tracked on the [roadmap](roadmap.md) or written up in the page that owns the subject. Nothing on this page is a surprise to the library: each one is refused with a message that says so, or is stated where it would matter, and none of them is a case of doing something almost right and hoping.

## The async client

`AsyncClient` is real and it is not at parity with `Client` yet. [async.md](async.md) has the whole picture, including what Mojo 1.0.0 allows a coroutine to do, which is what most of this list comes down to.

- No `https://`. There is no async TLS handshake, because OpenSSL's socket BIO does its own blocking reads and writes on the descriptor, which is exactly what the async path exists to avoid. Doing it properly needs memory BIOs. An https URL raises with a message saying so rather than being sent in the clear.
- No HTTP/2, for the same reason. HTTP/2 is negotiated in the TLS handshake, so no async TLS means no async ALPN and no async h2.
- No streaming request bodies and no `Expect: 100-continue`. Both need a second source driven between writes, which is another suspending loop, and the async driver refuses them with an invalid argument error.
- No cancellation. Nothing that stands for a request in flight can be handed to a user, so what stops a request is its deadline or closing its response. `tests/unit/test_aio_cancel.mojo` is the whole of what those do.
- `gather` raises the first failure and drops the other responses, the way `asyncio.gather` does by default. There is no `return_exceptions` equivalent, because the pool underneath reports a batch as one outcome rather than as a list of them.
- No `gather` for streams. Each `read_chunk` blocks the thread that called it, so several bodies cannot be read at once. Doing it means driving several sources under one task group, which is a design rather than a missing argument.
- Every entry point blocks the calling thread. The point of the async path is that a request waiting on a socket does not hold a worker, not that the caller's thread is free.
- Waiting is polling rather than a wake up. Mojo has no way to complete a task from a callback, so a ready socket is noticed after up to the number of waiters divided by the number of workers, in milliseconds. Sixteen waiters on four workers is four milliseconds.
- A DNS lookup holds a worker. `getaddrinfo` has no non blocking form on either platform, so resolution is done in synchronous code before the race starts, and a caller with a cold resolver cache pays for it.

## Protocols

- HTTP/2 carries one request at a time per connection. The state machine underneath multiplexes and the stream identifiers are already per stream, so nothing has to be redesigned, but a synchronous client has no way to be waiting on two responses at once.
- HTTP/2 only over TLS, negotiated by ALPN. There is no `h2c`, no prior knowledge mode and no upgrade from HTTP/1.1.
- No HTTP/3. httpx2 does not have it either, so it is not in scope before 1.0, though the transport ABI leaves room for it.
- No WebSocket and no connection upgrade path. Also after 1.0, and also left room for.
- Digest `auth-int` is refused with a protocol error. httpx2 refuses it too. It covers the request body in the hash, so the whole body has to be in memory and hashed before the headers can go out, and no server in the wild asks for it.
- Certificate revocation is not checked. Neither OCSP nor CRLs. [tls.md](tls.md) says what that means and what the industry does about it.

## Content

- gzip, deflate, brotli and zstd are all decoded, but only where the library is on the machine. zlib, libbrotlidec and libzstd are each opened by name at run time, and `Accept-Encoding` names only the ones that loaded, so a machine missing libbrotlidec is never sent `br` in the first place. A server that sends a coding it was not asked for gets a protocol error naming the missing library, rather than a body of compressed bytes calling itself text.
- A response whose body is compressed is bounded at 256 MiB of output. httpx2 has no such bound. `iter_raw` is the way past it, and [deviations.md](deviations.md) says why the default is what it is.
- Trailers arrive on `read()` and not through the iterators. A response read through an iterator never sees them, because the response cannot reach back into an iterator it has already handed out.

## Proxies

- Forward proxying works for `http://` targets. `Client(proxy=Proxy("http://localhost:3128"))` sends every request through it, in absolute form, with `Proxy-Authorization` built from any credentials in the proxy URL. The async client does the same.
- `https://` targets work too, through a `CONNECT` tunnel, with the TLS handshake running inside the tunnel to the real server and the real certificate. The tunnel is pooled under the server rather than under the proxy, so two requests to one server share it and two requests to different servers do not.
- A tunnel through an `https://` proxy raises. That would be TLS inside TLS, and the stream layer wraps a socket rather than another stream. Forwarding a plain `http://` request over an `https://` proxy does work.
- SOCKS5 works, with both the no auth and the username and password methods, and the target's name is sent to the proxy rather than resolved locally. `socks5://` and `socks5h://` mean the same thing here, and the port defaults to 1080. Everything through a SOCKS proxy is a tunnel, `http://` targets included, so two requests to different servers cannot share a connection through one.
- The async client cannot tunnel, of either kind. It opens its sockets inside a coroutine and has nowhere to put a handshake that has to finish first, so a `CONNECT` or a SOCKS proxy raises there rather than being ignored. Forwarding an `http://` request through an HTTP proxy is the one proxy shape it does.
- A mount cannot be added to a client after it has been built. `mounts=` is a constructor argument and `client._mounts` is private, where httpx leaves `client._mounts` reachable and mutable in practice. Routing that changes while requests are in flight is not a thing this client will do.
- All of the above is tested against Squid, tinyproxy, mitmproxy and Dante with `pixi run interop-proxy`, which needs Docker and runs on the local fleet rather than in CI.

## Tooling

- No CLI. The `httpx` binary matching httpx2's flags is M8.
- No documentation site and no generated API reference. Also M8, along with compiling every example in the docs in CI.

## Platforms

- Three platforms are tested: macos-arm64, linux-x86_64 and linux-arm64. Those are the ones CI runs on every pull request.
- Windows has no native Mojo build, so the library runs there under WSL2 and that is what the hardware fleet checks. There is no plan for a native Windows build before Mojo has one.
- Loading OpenSSL sets SIGPIPE to ignored, once, on Linux only, and only for a program that is going to speak TLS. It is the one thing in the library that reaches outside its own objects. [tls.md](tls.md) says why and what puts it back.

## Where the shapes come from

Several things that look like limitations are the language rather than the library, and they are all in [deviations.md](deviations.md) with the reason next to each: iterators are `has_next` and `next` because Mojo has no generators, errors are matched with `is_timeout(e)` rather than by type because Mojo has one error type, configuration is typed builders rather than `**kwargs`, and JSON is an arena of nodes because Mojo 1.0 has no recursive structs.

The async ones are worse and they are in [async.md](async.md). Eleven compiler limits shaped every coroutine in `httpx/_io/` and `httpx/_proto/h1/aio.mojo`, and each of them has a reproducer at the bottom of `tools/probe/async.mojo` so a later toolchain can be re-asked rather than guessed at. When one of them starts working, the workaround it forced is the thing to delete.
