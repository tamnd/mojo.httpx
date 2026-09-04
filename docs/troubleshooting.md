# Troubleshooting

This page is indexed by the message you just read, so that pasting one into a search engine or scanning this page finds the same entry. Every heading is the text the library actually prints, or enough of it to recognise.

The messages all begin with the kind, as in `ConnectError: could not resolve example.invalid`. That leading token is not decoration: it is how `httpx.kind_of(e)` recovers the kind, and it is the same word httpx2 puts on the front of the same failure. The headings below leave it off where it varies.

If the message came from the compiler rather than from the library, [Mojo notes](mojo.md) has the ones people hit first.

## Connecting

### `ConnectError: could not resolve NAME`

DNS said no. The name does not exist, or the resolver could not be reached. This is the same failure `curl` reports as `Could not resolve host`, and there is nothing the client can do about it.

Worth checking that the host really is what you meant, because a `base_url` with a typo in it produces exactly this and points at the URL you did not look at.

### `ConnectError: resolver returned no addresses for NAME` or `no usable addresses for NAME`

The name resolved but nothing came back that this client can connect to. Usually a name with only IPv6 addresses on a machine with no IPv6 route, or the other way round.

### `ConnectTimeout: ...`

The connection did not complete inside the connect budget. The default is five seconds. Raise it with `Timeout(connect_seconds=30.0, read_seconds=5.0, write_seconds=5.0, pool_seconds=5.0)`, or with `Timeout.uniform(30.0)` if every phase should get the same.

A connect timeout against a host that is up usually means a firewall dropping packets rather than refusing them, because a refusal comes back immediately as a `ConnectError`.

### `PoolTimeout: all N connections are in use and none can be freed, so there is no way to reach ORIGIN`

Your own program is holding more connections than it allowed itself. Almost always this is a leaked response: a streamed response that was never closed holds its connection out of the pool for as long as it is alive.

```mojo
from httpx import Client


def main() raises:
    with Client() as client:
        # The `with` is what gives the connection back.
        with client.stream("GET", "https://example.com/big.log") as r:
            print(r.status_code)
```

If the code is right and you genuinely need more, raise `Limits(max_connections=...)`. If it hangs rather than raising, the pool timeout is off and the fix is to give it one.

## TLS

### `ConnectError: the TLS certificate from HOST was rejected: ...`

The chain did not verify. OpenSSL's own words for the reason follow the colon, and for the results people actually hit there is a sentence after that saying what to do, because "certificate verify failed" on its own says nothing about which certificate or what was wrong with it.

The three usual causes are a private CA that is not in the system trust store, an expired certificate, and a server that sent only its leaf without the intermediate. The expiry one is worth a second look before you go hunting on the server: a machine whose clock is set forward has exactly the same symptom.

For a private CA, point the client at the bundle rather than turning verification off.

```mojo
from httpx import Client, SSLVerify


def main() raises:
    var bundle = SSLVerify.from_file("/etc/ssl/private-ca.pem")
    with Client(verify=bundle) as client:
        print(client.get("https://internal.example.com/").status_code)
```

`SSLVerify.off()` exists and makes the message go away without making the problem go away. [TLS](tls.md) has the full list of handshake failures and what each one means.

### `... The certificate is valid but was not issued for 'HOST'`

Right chain, wrong name. Check whether you are connecting by IP address, or through something that terminates TLS under a name of its own.

### `ConnectError: the connection to HOST closed during the TLS handshake`

The peer hung up rather than answering. A server speaking plain HTTP on the port you gave it does exactly this, so check the scheme and the port number first.

### `ConnectError: could not load the certificates at 'PATH'`

The file is not there, is not readable, or is not PEM. `SSLVerify.from_file` wants a PEM bundle and `SSLVerify.from_directory` wants an OpenSSL hashed directory, and passing one where the other was expected produces this.

### `UnsupportedProtocol: ... libssl ...`

OpenSSL was not found. It is opened at run time by name rather than linked, so this means no `libssl` of version 3.0 or newer is on the loader path. Inside a pixi environment it comes from the `openssl` dependency, and outside one it comes from the system. Plain `http://` needs none of it.

## Timeouts and slow servers

### `ReadTimeout: ...`

The server stopped sending partway through, or never started. The read budget is per read rather than per response, so a download that keeps arriving is never stopped for being large, and a server that goes quiet mid body is.

Raise `read_seconds`, or stream the response so that a slow body is being consumed as it arrives rather than waited for in one go.

### `WriteTimeout: ...`

A request body could not be pushed inside its budget. Nearly always a large upload against a slow link. Raise `write_seconds`.

### The request hangs and nothing is raised

Something was built with the timeout switched off. `Timeout.disabled()` is a real setting for a program that does its own supervision, and a trap otherwise. Every default in this library has a limit on it, so a hang means one was removed deliberately somewhere.

## Redirects

### `TooManyRedirects: Exceeded maximum allowed redirects.`

The chain went past `max_redirects`. Usually a genuine loop, and occasionally a site that needs a cookie you are not carrying and keeps sending you back to a login page. `r.history()` on the error path is not available, so the way to see the loop is to send it again with `follow_redirects=False` and walk `next_request()` by hand.

### The redirect was not followed at all

That is the default, and it matches httpx2. The library does not follow a 3xx unless asked, because a client that follows silently can be sent somewhere the caller never named. Pass `follow_redirects=True` on the client or on the call.

The command line client does follow by default, which is a deliberate difference and is in [Command line client](cli.md).

### The `Authorization` header disappeared after a redirect

That is on purpose. Credentials are dropped when a hop crosses an origin, so no server can talk this client into handing your password to an address you never named. Same origin hops keep it.

## Reading a response

### `ResponseNotRead: the body of this response has not been read, call read()`

You asked a streamed response for `text()`, `json()` or `content()` without reading the body first. A streamed response has not got a body in memory, by design.

```mojo
from httpx import Client


def main() raises:
    with Client() as client:
        with client.stream("GET", "https://example.com/") as r:
            r.read()
            print(r.text())
```

Or read it as it arrives with `iter_bytes` and friends, which is the reason to be streaming at all.

### `StreamConsumed: this response body has already been streamed, ...`

The body was handed to an iterator, or read, and something asked for it again. A body arrives once. If you need it twice, read it into memory with `read()` and use `content()`, which can be asked as often as you like.

### `StreamClosed: this response is closed and has nothing left to read`

The response was closed, or its `with` block was left, and then something tried to read it. This is also what you get from a response whose block ended early: the connection was given up and the rest of the body is gone.

Note that reading a closed response raises rather than handing back the empty list sitting there, because an empty body and a body nobody is going to read are different answers.

### `RequestNotRead: this request's body was a stream and has already been ...`

A request with a `content_stream=` body was sent twice, usually because a redirect was followed. A streaming body exists once, so `Request.copy()` produces a copy that remembers it has no body rather than one that quietly uploads nothing.

Read the body into memory and use `content=` if it has to go more than once.

### `InvalidArgument: next() was called with nothing left to read, check has_next()`

The iterators are `has_next` and `next` rather than a `for` loop, and `next` past the end raises. [Mojo notes](mojo.md) says why there is no `for` loop here, and it is a good reason.

### `RuntimeError: elapsed() is only available once the response has been read or closed`

Same as httpx2. A number covering only the status line would quietly answer a different question than the one asked, since a response is slow because of its body far more often than because of its headers. Read the body, or close the response, and then ask.

A response you built by hand was never sent, so this raises for one of those whatever you call on it.

## Content and encoding

### `DecodingError: invalid JSON at line N column M`

The body is not JSON. Nine times in ten it is an error page from something in the middle, a proxy or a load balancer, sent with a JSON content type or with none. Print `r.text()` and you will usually see HTML.

The parser is strict on purpose. A body that lies about its encoding still reads through `r.text()`, which replaces undecodable bytes, so the strict reading is available exactly where it matters.

### `ProtocolError: the server answered with Content-Encoding: X, which this client cannot decode and did not ask for`

The coding is not one of gzip, deflate, br or zstd. There is no fifth coding to install and no way to switch it on, because the client never offered it. Read the body with `iter_raw` and undo it yourself.

### `ProtocolError: this BODY body expanded past the N byte limit, from M bytes on the wire`

A compressed body decoded to more than the bound allows. Compressed bodies are the case where the sender chooses how much memory the receiver spends, so every decoder here has a ceiling: 256 MiB of output, and 1032 times the compressed size once 64 KiB has arrived. httpx2 has no bound at all and fails by exhausting the process instead.

`iter_raw` is the way past it. It hands over the compressed bytes untouched and lets you decide what to do with them.

### `ProtocolError: the server answered with Content-Encoding: X, which was not asked for on this machine`

The server compressed with something this machine cannot undo. `Accept-Encoding` is built from which shared libraries actually loaded, zlib for gzip and deflate, libbrotlidec for `br` and libzstd for `zstd`, so a machine missing one never asks for that coding. A server that sends it anyway is answering a question nobody asked.

Install the library, or read the body with `iter_raw` and decode it yourself.

### `r.text()` came back as mojibake

The server named an encoding this library does not implement, or named none and the body is not UTF-8. The set here is UTF-8, UTF-16 and UTF-32 in both byte orders, Latin-1, Windows-1252 and ASCII. Anything else falls back to `default_encoding`.

Set `default_encoding=DefaultEncoding("iso-8859-1")` on the client if you know what the API answers with, or take `r.content()` and decode it yourself if it is something like Shift-JIS that needs a code page table an HTTP client should not be carrying.

## The async client

### An https request through the async client is slower than the same one through `Client`

One request at a time, it will be, by roughly the length of a handshake. The synchronous handshake sits in `poll` until the socket moves. The async one comes back around its loop several times a second to look at the deadline, so a handshake that needs four round trips can spend a millisecond or two waiting to notice each one. That is the same trade every wait in the async path makes, and it is written up under waiting in [async](docs/async.md).

It is the wrong measurement anyway. Send four requests with `gather` and the four handshakes overlap, which is what the async client is for. One request at a time has nothing to overlap with, so `Client` is the better answer for it.

### `h2` is never negotiated on the async client

The async pool asks for HTTP/1.1 only in ALPN, whatever `http2=` was set to on the client, because it speaks HTTP/1.1 and offering `h2` would get a settings frame back where it expected a status line. Use `Client(http2=True)` for HTTP/2 today.

### A tunnel or a SOCKS proxy raises on the async client

The async client opens its sockets inside a coroutine and has nowhere to put a proxy handshake that has to finish before the connection is usable at all, so `CONNECT` and SOCKS5 both raise rather than being ignored. A TLS handshake fits because it folds into the connect loop, and neither of these does. Forwarding a plain `http://` request through an HTTP proxy is the one proxy shape it does.

### `gather` raised and I lost the other responses

That is `asyncio.gather`'s default behaviour and it is what happens here. The first failure is raised and the rest are dropped. Every request still runs to the end first, so no connection is left leased. A `return_exceptions` equivalent is wanted and is not written yet.

### A request is slow to notice that its socket is ready

Mojo has no way to complete a task from a callback, so waiting is polling rather than being woken. With more waiters than workers, each one gets its turn periodically: the delay is the number of waiters divided by the number of workers, in milliseconds. Sixteen waiters on four workers is four milliseconds. [Async support](async.md) has the measurements.

## Proxies

### `ProxyError: the proxy answered STATUS PHRASE to the CONNECT for HOST:PORT`

The proxy refused the tunnel. A 407 means it wants credentials, which go in the proxy URL as `http://user:pass@host:port`. A 403 usually means the target is not on its allow list.

### `ProxyError: the SOCKS5 proxy rejected every authentication method offered`

The proxy wants a method this client does not implement, or wants credentials that were not in the URL. Both the no auth and the username and password methods are supported, and nothing else is.

### A tunnel through an `https://` proxy raises

That would be TLS inside TLS, and the stream layer here wraps a socket rather than another stream. Forwarding a plain `http://` request over an `https://` proxy does work.

### `NO_PROXY` is not being honoured the way you expect

The rules are curl's rather than httpx2's, and the difference is real: `NO_PROXY=192.168.0.0/16` is a range here and is one single address in httpx2, which keeps `192.168.0.0` and drops the `/16`. Also the lower case `http_proxy` wins over `HTTP_PROXY` here rather than whichever the shell exported last. Both are in the [Compatibility guide](deviations.md).

## Cookies

### `CookieConflict: multiple cookies named NAME`

`client.cookies["session"]` asks for one value and the jar holds more than one cookie with that name, scoped to different domains or paths. That is legal and common. Ask with the scope instead, or iterate the jar.

### A cookie was not stored

The likely reasons, in order: the `Set-Cookie` named a domain the responding host does not belong to, it was scoped to a public suffix, it was already expired, or it was `Secure` and arrived over `http://`. All four are RFC 6265 saying no, and all four are silent because a warning per dropped cookie would be noise on the open web.

## URLs

### `InvalidURL: a SCHEME url has to name a host`

A relative URL reached a client with no `base_url`, or the URL is missing its authority. `client.get("/items")` needs the client to have been built with `base_url=URL("https://api.example.com")`.

### `InvalidURL: unclosed bracket in the host of ...`

An IPv6 literal without its closing bracket. The bracketed form is the only one a URL can carry: `http://[::1]:8080/`.

### A mount pattern raised where httpx2 accepted it

Two patterns are stricter here. A path on a pattern, `all://example.com/api`, is an error, because routing looks at scheme, host and port and httpx2 silently ignores the path, matching more than the author asked for. An IPv6 address wants brackets, `all://[::1]`, because the unbracketed form parses as a host and a port and matches nothing ever.

## Statuses

### `HTTPStatusError: ...`

`raise_for_status()` on a response outside 2xx. The message names the class of status, the code, the phrase the server sent and the URL, plus the redirect location when a 3xx got through because following was off.

A 4xx or a 5xx is not an error until you ask for it. If you want the status without the exception, read `r.status_code` and `r.is_success()`.

## Building the library

### `error: package 'httpx' has no declaration 'NAME'`

The name is not public. `httpx/__init__.mojo` is the whole public surface, and a name not in that file is not exported whatever it is spelled like. The [API reference](api.md) is generated from that file, so if it is not on that page it is not there.

### `error: cannot call function that may raise in a context that cannot raise`

A missing `raises` on the enclosing `def`. Mojo 1.0 does not infer it. [Mojo notes](mojo.md) has the other compiler messages that come up.

### The build cannot find `httpx` at all

`-I` wants the directory that contains the `httpx` directory, not the `httpx` directory itself. [Installation](install.md) has the paths.

## Nothing here matches

Open an issue with the Mojo version, the operating system and architecture, a minimal reproduction and what you expected instead. For anything at the protocol level, the raw bytes on the wire are the most useful thing you can attach. [Contributing](../CONTRIBUTING.md) has the rest, and [SECURITY.md](../SECURITY.md) covers anything with a security impact, which does not go in a public issue.
