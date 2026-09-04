# Compatibility guide

The goal is that code written against httpx2 reads the same here, and that a request going out over the wire has the same bytes in it. Where that is not possible, the difference is deliberate and it is written down on this page rather than left for somebody to find at three in the morning.

The file is still called `deviations.md` because a lot of code comments point at it by name. This is the page to read when you are porting something.

This page is about behaving differently while doing the same job. Things that are simply not here yet, such as HTTP/2 on the async client, are on [limitations.md](limitations.md) instead.

Two kinds of difference show up. The first kind is forced by the language: Mojo has no dynamic `Any`, no exception subclassing, no generators and no keyword argument packing, so anything built on those has to be spelled differently. The second kind is a judgement call, where copying httpx2 exactly was possible and we chose not to. The second kind is much shorter and each entry says what the alternative was.

The migration table below is the quick reference, every httpx2 name beside its Mojo form. The two sections after it are the reasons behind the rows that changed.

## The migration table

Every httpx2 API beside the Mojo form of it. Where a row is identical in both, it is here anyway, because knowing a thing did not change is worth as much as knowing it did.

Two conventions run through the whole table and are not repeated on every row. An attribute in httpx2 that can fail or has to compute something is a method here, so `r.text` is `r.text()`, and one that is a plain stored field stays a field, so `r.status_code` is `r.status_code`. And a value handed to a constructor is handed over rather than lent, so an argument built beforehand goes in with `^`, as in `headers=headers^`. [Mojo notes](mojo.md) explains both.

### Top level

| httpx2 | mojo.httpx |
| --- | --- |
| `httpx.get(url)` | `httpx.get(url)` |
| `httpx.post`, `put`, `patch`, `delete`, `head`, `options` | the same six |
| `httpx.request("REPORT", url)` | `httpx.request("REPORT", url)` |
| `with httpx.stream("GET", url) as r` | `var r = httpx.stream("GET", url)` |
| `httpx.__version__` | `httpx.__version__` |

The one shot `stream` is an ordinary function rather than a context manager, and the connection is not reused afterwards. That is the one row above with a behaviour difference behind it, and it has a section of its own further down.

### Client

| httpx2 | mojo.httpx |
| --- | --- |
| `httpx.Client()` | `httpx.Client()` |
| `httpx.AsyncClient()` | `httpx.AsyncClient()` |
| `with httpx.Client() as client` | `with httpx.Client() as client` |
| `async with httpx.AsyncClient() as client` | `with httpx.AsyncClient() as client` |
| `client.close()`, `await client.aclose()` | `client.close()`, `client.aclose()`, the same call |
| `base_url="https://api.example.com"` | `base_url=URL("https://api.example.com")` |
| `headers={"Accept": "application/json"}` | a `Headers` built up, passed as `headers=headers^` |
| `params={"q": "mojo"}` | `params=QueryParams().add("q", "mojo")^` |
| `cookies={"session": "abc"}` | a `Cookies` built up, passed as `cookies=cookies^` |
| `auth=("user", "pass")` | `auth=basic_auth("user", "pass")` |
| `timeout=5.0` | `timeout=Timeout.uniform(5.0)` |
| `limits=httpx.Limits(...)` | `limits=Limits(...)` |
| `proxy="http://localhost:3128"` | `proxy=Proxy("http://localhost:3128")` |
| `mounts={"all://x": t, "all://y": None}` | a `Mounts` with `mount` and `bypass` on it |
| `verify=True` | the default |
| `verify="/path/ca.pem"` | `verify=SSLVerify.from_file("/path/ca.pem")` |
| `verify=False` | `verify=SSLVerify.off()` |
| `cert=("client.pem", "client.key")` | `cert=ClientCert("client.pem", "client.key")` |
| `follow_redirects=True` | `follow_redirects=True` |
| `max_redirects=20` | `max_redirects=20` |
| `http2=True` | `http2=True` |
| `trust_env=False` | `trust_env=False` |
| `default_encoding="iso-8859-1"` | `default_encoding=DefaultEncoding("iso-8859-1")` |
| `event_hooks={"request": [...]}` | an `EventHooks` with `on_request` and `on_response` |
| `transport=t` | `transport=erase_transport(t^)`, or the positional shorthand `Client(erase_transport(t^))` |
| `client.headers`, `client.cookies`, `client.params` | the same three, mutable |
| `client.build_request(...)` | `client.build_request(...)` |
| `client.send(request)` | `client.send(request^)` |
| `client.get("/items")` and the six others | the same seven |
| `client.stream("GET", url)` | `client.stream("GET", url)` |
| `httpx.gather` does not exist, you use `asyncio.gather` | `httpx.gather(client, requests^)` |

### Request bodies

| httpx2 | mojo.httpx |
| --- | --- |
| `content=b"..."` | `content=` for bytes, `text=` for a string |
| `content=<an iterable>` | `content_stream=erase_source(source^)` |
| `data={"a": "b"}` | `data=QueryParams().add("a", "b")^` |
| `files={"f": ("name.jpg", data)}` | a `MultipartData` with `add_file(FileUpload(...))` |
| `json={"a": 1}` | a `Json.object()` with `set` on it, passed as `json=doc^` |

### Response

| httpx2 | mojo.httpx |
| --- | --- |
| `r.status_code` | `r.status_code` |
| `r.reason_phrase` | `r.reason_phrase` |
| `r.http_version` | `r.http_version` |
| `r.headers` | `r.headers` |
| `r.url` | `r.url()` |
| `r.request` | `r.request()` |
| `r.content` | `r.content()`, a `Span[UInt8]` |
| `r.text` | `r.text()` |
| `r.json()` | `r.json()`, a typed `Json` |
| `r.encoding` | `r.encoding()` |
| `r.charset_encoding` | `r.charset_encoding()` |
| `r.cookies` | `r.cookies()` |
| `r.links` | `r.links()`, a list, plus `r.link_url("next")` |
| `r.history` | `r.history()` |
| `r.next_request` | `r.next_request()` |
| `r.elapsed` | `r.elapsed()`, a `Duration` |
| `r.num_bytes_downloaded` | `r.num_bytes_downloaded()`, and on the iterator too |
| `r.is_closed`, `r.is_stream_consumed` | the same two, as fields |
| `r.is_success`, `r.is_error` and the rest | the same, as methods |
| `r.raise_for_status()` returning the response | `r.raise_for_status()` returning nothing |
| `r.read()`, `await r.aread()` | `r.read()`, `r.aread()` |
| `r.close()`, `await r.aclose()` | `r.close()`, `r.aclose()` |

### Reading a body as it arrives

| httpx2 | mojo.httpx |
| --- | --- |
| `for b in r.iter_bytes()` | `var c = r.iter_bytes()` then `while c.has_next(): c.next()` |
| `iter_text`, `iter_lines`, `iter_raw` | the same three, same shape |
| `async for b in r.aiter_bytes()` | `r.aiter_bytes()`, the same call as `iter_bytes` |

### URL

| httpx2 | mojo.httpx |
| --- | --- |
| `httpx.URL("https://example.com")` | `URL("https://example.com")` |
| `url.scheme`, `url.host`, `url.port` | `url.scheme()`, `url.host()`, `url.port()` |
| `url.path`, `url.query`, `url.fragment` | `url.path()`, `url.raw_query()`, `url.fragment()` |
| `url.params` | `url.params()`, a `QueryParams` |
| `url.username`, `url.password`, `url.userinfo` | the same three, as methods |
| `url.netloc`, `url.raw_path` | `url.netloc()`, `url.raw_path()` |
| `url.is_absolute_url`, `url.is_relative_url` | the same two, as methods |
| `url.copy_with(...)` | `url.copy_with(...)` |
| `url.copy_set_param`, `copy_add_param`, `copy_remove_param`, `copy_merge_params` | the same four |
| `url.join("../x")` | `url.join("../x")` |

### Headers, params and cookies

| httpx2 | mojo.httpx |
| --- | --- |
| `httpx.Headers({"A": "b"})` | `Headers()` then `headers["A"] = "b"` |
| `headers["a"]`, `headers.get("a", "d")` | the same two |
| `headers.get_list("set-cookie")` | `headers.get_list("set-cookie")` |
| `headers.keys()`, `values()`, `items()`, `multi_items()` | the same four |
| `headers.update(other)`, `setdefault` | the same two |
| `del headers["a"]` | `headers.discard("a")` |
| `httpx.QueryParams("a=1&b=2")` | `QueryParams("a=1&b=2")` |
| `params.set`, `add`, `remove`, `merge` | the same four, each returning a new value |
| `params.get`, `get_list`, `keys`, `values`, `items`, `multi_items` | the same six |
| `httpx.Cookies()` | `Cookies()` |
| `cookies["session"]`, `cookies.set(...)`, `cookies.delete(...)`, `cookies.clear(...)` | the same |
| `cookies.keys()`, `values()`, `items()` | the same three |

### Configuration types

| httpx2 | mojo.httpx |
| --- | --- |
| `httpx.Timeout(5.0)` | `Timeout.uniform(5.0)` |
| `httpx.Timeout(connect=3.0, read=30.0, write=10.0, pool=5.0)` | `Timeout(connect_seconds=3.0, read_seconds=30.0, write_seconds=10.0, pool_seconds=5.0)` |
| `httpx.Timeout(None)` | `Timeout.disabled()` |
| `timeout.connect` and the other three | the same four, as fields |
| `httpx.Limits(max_connections=100, max_keepalive_connections=20, keepalive_expiry=5.0)` | the same three arguments |
| `httpx.Proxy(url, auth=("u", "p"))` | `Proxy("http://u:p@host:port")`, or a header built by `proxy_basic_auth` |
| `datetime.timedelta` from `r.elapsed` | `Duration`, with `seconds()`, `milliseconds()`, `microseconds()` |

The `Timeout` phase arguments are named for their unit because `read` and `write` are already spoken for as argument conventions in Mojo. The fields keep the httpx2 names.

### Authentication

| httpx2 | mojo.httpx |
| --- | --- |
| `auth=("user", "pass")` | `auth=basic_auth("user", "pass")` |
| `httpx.BasicAuth("user", "pass")` | `basic_auth("user", "pass")` |
| `httpx.DigestAuth("user", "pass")` | `digest_auth("user", "pass")` |
| `httpx.NetRCAuth()` | `netrc_auth()` |
| `auth=None` on a call, to send it unauthenticated | `auth=no_auth()` |
| subclassing `httpx.Auth` | a struct implementing `Auth`, wrapped with `erase_auth` |

### Transports and testing

| httpx2 | mojo.httpx |
| --- | --- |
| `httpx.HTTPTransport()` | `HTTPTransport()` |
| `httpx.AsyncHTTPTransport()` | `AsyncHTTPTransport()` |
| `httpx.MockTransport(handler)` | `MockTransport(handler)` |
| `respx` or a hand rolled router | `MockRouter` and `Route`, in the library |
| any object with `handle_request` | a struct implementing `Transport`, wrapped with `erase_transport` |
| `{"http://": None}` in `mounts` | `mounts.bypass("http://")` |
| nothing, there is no spelling for it | `blocked("reason")`, a transport that refuses and says why |

### Errors

httpx2 catches types. Here you ask questions, because Mojo has one error type. Each predicate is true exactly where the corresponding `except` clause would catch.

| httpx2 | mojo.httpx |
| --- | --- |
| `except httpx.HTTPError` | `if httpx.is_http_error(e)` |
| `except httpx.RequestError` | `is_request_error(e)` |
| `except httpx.TransportError` | `is_transport_error(e)` |
| `except httpx.TimeoutException` | `is_timeout(e)` |
| `except httpx.ConnectTimeout` | `is_connect_timeout(e)` |
| `except httpx.ReadTimeout` | `is_read_timeout(e)` |
| `except httpx.WriteTimeout` | `is_write_timeout(e)` |
| `except httpx.PoolTimeout` | `is_pool_timeout(e)` |
| `except httpx.NetworkError` | `is_network_error(e)` |
| `except httpx.ConnectError` | `is_connect_error(e)` |
| `except httpx.ProtocolError` | `is_protocol_error(e)` |
| `except httpx.LocalProtocolError` | `is_local_protocol_error(e)` |
| `except httpx.RemoteProtocolError` | `is_remote_protocol_error(e)` |
| `except httpx.ProxyError` | `is_proxy_error(e)` |
| `except httpx.UnsupportedProtocol` | `is_unsupported_protocol(e)` |
| `except httpx.DecodingError` | `is_decoding_error(e)` |
| `except httpx.TooManyRedirects` | `is_too_many_redirects(e)` |
| `except httpx.HTTPStatusError` | `is_status_error(e)` |
| `except httpx.InvalidURL` | `is_invalid_url(e)` |
| `except httpx.StreamError` | `is_stream_error(e)` |
| `except httpx.CookieConflict` | `is_cookie_conflict(e)` |
| `type(e).__name__` for a log line | `httpx.kind_of(e).name()`, the same string |
| `str(e)` | `httpx.message_of(e)`, without the kind on the front |
| `raise httpx.ConnectError("...")` in your own transport | `raise httpx.new_error(ErrorKind.CONNECT_ERROR, "...")` |

The predicates nest the way the classes do, so ask the specific one first. `is_timeout` is true for all four timeouts, `is_transport_error` for every network layer failure, and `is_http_error` for anything raised for a request.

### Async

| httpx2 | mojo.httpx |
| --- | --- |
| `async def main()` | `def main() raises`, there is no async entry point |
| `await client.get(url)` | `client.get(url)` |
| `async with AsyncClient() as c` | `with AsyncClient() as c` |
| `await asyncio.gather(*coros)` | `httpx.gather(client, requests^)` |
| `task.cancel()` | close the response, or give the request a timeout |
| `async for chunk in r.aiter_bytes()` | `r.aiter_bytes()` with `has_next` and `next` |

## Forced by the language

| httpx2 | mojo.httpx | Reason |
| --- | --- | --- |
| `r.json()` returns `Any` | returns a typed `Json` value with accessors | Mojo has no dynamic `Any`, so the type check has to happen at the point of access |
| `except httpx.TimeoutException` | `if httpx.is_timeout(e)` | Mojo has one error type and no exception subclassing |
| duck typed transports | a generic transport plus an erased vtable | Mojo has no trait objects |
| `async with AsyncClient()` | `with AsyncClient() as client` | Mojo has no async context managers, and nothing about closing a client suspends, so the ordinary one does the job. `aclose()` exists as a second name for `close()` |
| `for chunk in r.iter_bytes()` | `while chunks.has_next(): chunks.next()` | Mojo has no generators, and a `for` loop swallows an error raised out of `__next__` |
| `async for chunk in r.aiter_bytes()` | `r.aiter_bytes()`, the same call as `iter_bytes` | the asynchrony is in the source underneath, which neither the response nor the iterator can see. The `a` names exist so ported code keeps its shape |
| `task.cancel()` on a request in flight | close the response, or give it a timeout | nothing that stands for a request in flight can be handed to a user, since `Coroutine` is linear and `Task` is not `Movable`, and `TaskGroup` has no cancel either. `docs/async.md` says what stops a request instead |
| `content=` takes bytes or an iterable | `content=` for bytes, `content_stream=` for a source | Mojo cannot tell the two apart at runtime, so they are two arguments |
| `**kwargs` config | typed builders | Mojo has no keyword argument packing |
| `timedelta` | `Duration` | no stdlib equivalent |
| `json.loads` on arbitrarily nested input | an arena of nodes indexed by integer | Mojo 1.0 has no recursive structs, so a tree cannot hold itself |

None of these change what goes on the wire. They change what the calling code looks like.

### The iterators are not iterators

This one is worth spelling out because it is the ugliest thing in the library and it is not a style choice.

Mojo 1.0 drops an error raised out of `__next__`. A `for` loop over an iterator whose `__next__` raises stops as if the iterator had run out, and the error never reaches the caller. The compiler goes further and warns that a `try` around the loop is unreachable, so wrapping the loop does not help either.

For an HTTP client that is the worst possible failure mode. A connection that dies halfway through a response body would end the loop quietly, and the truncated body would be indistinguishable from a complete one. Nothing anywhere would say that half the data is missing.

So `ByteChunks`, `TextChunks` and `LineChunks` do not implement the iterator protocol. They have `has_next` and `next`, `next` raises the way any other read does, and a caller writes a `while` loop:

```mojo
var chunks = response.iter_bytes(4096)
while chunks.has_next():
    process(chunks.next())
```

`tests/unit/test_language.mojo` pins the compiler behaviour that forced this, so if a later Mojo release fixes it we find out from a failing test.

### `is_closed` goes true when the stream is handed out

httpx2 sets `is_closed` when the iterator finishes, in a `finally`. Here it goes true at the moment `iter_raw`, `iter_text` or `iter_lines` hands the stream over, before a single chunk has been read.

The reason is that the iterator would have to reach back into the response to update it, and a back reference means a raw pointer inside `_models`, which is a layer where the unsafe lint does not allow one. The alternative would be moving the models into an unsafe layer to hold one pointer, which is a much worse trade than moving a flag one step earlier.

What the flag means in practice is the same either way: from that moment the response itself cannot produce anything, and a second reader has to be turned away. `is_stream_consumed` goes true at the same moment in both libraries.

### A streaming request body cannot be sent twice

httpx2 has the same rule and the same error. It is worth stating here anyway, because this library enforces it a step earlier.

A body that is pulled as it is written exists once. `Request.copy()` on a request that has one produces a copy with no body at all, which remembers that it is missing one, so sending the copy raises `RequestNotRead` with a message saying to read the body into memory and use `content=` if it has to go more than once. The alternative would be a copy that quietly sent an empty body to a redirect target, which is the kind of failure that shows up as a support ticket about a missing upload rather than as an error.

### An event hook returns the request or response instead of mutating it

httpx2 hands a hook the object and lets it change what it was given. Here the signature is `def(var Request) raises -> Request`, so a hook takes ownership and hands it back, and one that changes nothing writes `return request^`.

A thin function pointer cannot take a `mut` parameter in Mojo 1.0, and thin function pointers are what make a hook storable in a list at all. Passing ownership through is the only shape that fits. The consolation is that a hook that raises has taken the response with it, so the connection is released by destruction on the way out rather than by an explicit close in the client.

Everything else about hooks matches: `client.event_hooks` is mutable, hooks run once per send rather than once per call, the request hook sees the fully merged request, and the response hook runs before the body is read.

### `httpx.stream()` does not reuse its connection

`client.stream()` matches httpx2 exactly, including the `with` block, because a response has an `__enter__` and is destroyed at the end of the block. The one shot `httpx.stream()` is the one that differs.

In httpx2 the top level helper is a context manager, so the client it built stays alive for as long as the block runs and the connection goes back into that client's pool at the end. Here the helper is an ordinary function that has to return, which means the client is closed before the caller sees the response. The response still works: the connection carrying the body was never in the pool to be closed, and the pool stays alive as long as the response holds a handle on it. What is lost is the reuse. There is no live pool to put the connection back into by the time the body ends, so it is closed instead.

That costs one connection on a call that was already the slow path, since a one shot helper pays a connect and a handshake regardless. Anything streaming more than once should hold a `Client`, which is the same advice the other one shot helpers carry.

## Judgement calls

### `Accept-Encoding` is decided at run time, and can be shorter

Both clients send `Accept-Encoding: gzip, deflate, br, zstd` on an ordinary machine, so the header usually matches byte for byte. What differs is where the list comes from. httpx2 decides it from which Python packages are installed at import time. Here it is built from which shared libraries `dlopen` actually found: zlib for gzip and deflate, libbrotlidec for `br`, libzstd for `zstd`, each opened by name the first time a response needs it.

So the header is shorter on a machine that is missing one of them, and `identity` on a machine missing all three, and in both cases the client gets larger responses instead of failing on every compressed one. Asking for a coding you cannot undo is worse than not asking: the server compresses, the client cannot decompress, and `response.text()` hands back a string built out of the compressed bytes and calls it the body.

### A decoded body has a size limit and httpx2's does not

A compressed body is one where the sender chooses how much memory the receiver spends. Deflate reaches 1032 to 1, so forty kilobytes on the wire can become forty megabytes in memory, and a few megabytes can become several gigabytes. httpx2 has no bound on this at all: the body is trusted about its own size, and the failure mode is the process rather than an exception.

Here every decoder is built with a `DecodeLimits`, which stops a body at 256 MiB of output and at 1032 times its compressed size, measured once 64 KiB has arrived. The ratio bound cannot fire on gzip or deflate data that a real encoder produced, because 1032 is deflate's own ceiling, so for those two it sits behind the output bound. brotli and zstd have no such ceiling: a zstd frame built out of RLE blocks sustains about thirty two thousand to one and brotli's static dictionary does better still, so for those two the ratio is a bound that can actually fire. The same 1032 covers all four because real documents land between five and fifty to one, and it is the bound that still protects a caller who raised `max_output` because they genuinely download large things.

A caller who really is downloading something larger has `iter_raw`, which hands over the compressed bytes untouched and lets them decide what to do with them.

### Headers go out in a different order

Both clients send the same headers with the same values; they order them differently. We put the ones the caller set immediately after `Host`, so a trace shows what the request was about before it shows the boilerplate, and the framing headers last, because the writer is what adds them. httpx2 puts its own defaults first and the caller's after, and writes `Content-Length` before `Content-Type`.

Field order carries no meaning in HTTP for any header either client sends, so there is nothing to be right about here. It is written down because the parity suite compares order and would otherwise be reporting a difference with no explanation attached.

### `proxy=` takes a `Proxy` and not a string

httpx2 accepts `proxy="http://localhost:3128"` or `proxy=httpx.Proxy(...)` and sorts out which it got at runtime. Here it is `proxy=Optional[Proxy](Proxy("http://localhost:3128"))`.

Mojo has no runtime type dispatch, so the string form would have to be a second overload of the client constructor, which already has seventeen keyword arguments. And building a `Proxy` parses a URL, which can fail, so the string form would move that failure from where the mistake was written to somewhere inside the first request. The extra call names what it builds and puts the error where it belongs.

The same reasoning as the auth tuple below, and the same shape of answer.

### `mounts=` is a table built a mount at a time

httpx2 takes a dictionary, `mounts={"all://example.com": transport, "all://internal": None}`. Here it is a `Mounts` value with `mount` and `bypass` on it, handed to the client with `mounts=routes^`.

Mojo has no dictionary literal that can hold a transport, since a transport is a move only value and the keys have to be parsed before they mean anything. Building the table a mount at a time is the same amount of typing and it moves two failures earlier: a pattern that is a typo raises where it was written rather than becoming a mount that never fires, and the search order is settled as each entry goes in rather than being recomputed on the first request. `None` becoming a named call, `bypass`, is the part of this that reads better than the original, because an empty entry in a dict does not say which of the two empty things it means.

### Blocking a pattern is a transport, and httpx has no spelling for it

`mounts={"http://": None}` in httpx2 does not block plaintext. It sends those requests to the client's own transport, which is the no proxy escape hatch and nothing more, and a reader who expected a wall gets the opposite of one. httpx2's own documentation calls the feature "no-proxy support" for that reason.

So the two are separate here. `bypass` is httpx2's `None`, byte for byte the same behaviour, and refusing a request is `blocked()`, a transport that raises naming the URL it would not send. Blocking had to be added rather than left out, because a client that cannot say no to a scheme is a client that leaks one, and it is a transport rather than a flag on the table so that a caller who wants to count refusals or word them differently writes an ordinary `Transport` instead of asking for another flag.

### A mount pattern is parsed more strictly

Two patterns that httpx2 accepts raise here.

A path on a pattern, `all://example.com/api`, is an error. httpx2 parses it and then ignores the path, so the mount matches every request to that host and the author of the configuration believes they narrowed it. Routing looks at the scheme, the host and the port and there is no reading of a path that would work, so saying so is better than matching more than was asked for.

An IPv6 address without brackets, `all://::1`, is an error rather than being taken as the host `:` on port 1. That is the reading a URL parser gives it and it matches nothing ever, which is the failure mode the whole parser is trying to avoid. `all://[::1]` is the way to write it.

### The lower case proxy variable wins, rather than whichever was exported last

httpx reads the environment through `urllib.request.getproxies`, which walks the environment block twice and lets the later entry win. With both `http_proxy` and `HTTP_PROXY` set, the answer depends on the order a shell happened to export them in, and nothing about that order is under anyone's control.

Here the lower case name is looked up first and the upper case one is the fallback, which is curl's rule and is stable. An empty value counts as unset in both, so `HTTP_PROXY=` means not through a proxy rather than a proxy with no name.

### `NO_PROXY` ranges are ranges

`NO_PROXY=192.168.0.0/16` is a range in curl and in Go's proxy support, and it is a range here. httpx parses the entry, keeps `192.168.0.0` and drops the `/16`, so exactly one address out of the sixty five thousand is exempt and everything else on the network keeps going through the proxy.

That is not a spelling difference, it is a rule that quietly does a thousandth of what it says, so it was not worth copying. The same machinery makes an address compare as a number rather than as text, which closes the other half of it: `all://127.0.0.1` matches a URL written `http://0177.0.0.1/`, and a rule written about an address cannot be walked around by writing the address in another base.

### The auth tuple shorthand is a function

httpx2 lets you write `auth=("user", "pass")` and turns the pair into a `BasicAuth` behind your back. Here it is `auth=basic_auth("user", "pass")`, with `digest_auth` and `netrc_auth` alongside it.

The tuple form would have to be another overload of every method that takes an auth, and there are eleven of those on `Client` and nine more in `_api.mojo`, because Mojo has no runtime type dispatch to fold them back together. The function is the same amount of typing, it names the scheme it builds, and `auth=basic_auth(...)` reads as the thing it is rather than as a pair of strings that happens to be interpreted.

### Turning auth off for one call is `no_auth()` rather than `None`

httpx2 carries a private `USE_CLIENT_DEFAULT` sentinel and defaults `auth`, `follow_redirects` and `timeout` to it on every request method, so passing `None` is distinguishable from passing nothing and means send this one unauthenticated.

Here those three arguments are `Optional`, and an empty one already means use the client's. That covers `timeout` and `follow_redirects` completely, since neither has a meaningful off, and it leaves one gap: a client with a scheme, and one request that should go out without it. That case is `auth=no_auth()`, which is a real scheme that signs nothing.

A second sentinel type would have matched httpx2's spelling, at the cost of an `Optional`-shaped thing that is not an `Optional` on twenty method signatures, and a reader who has to learn which of the two absences they are looking at. A scheme that adds no header is the same behaviour described in terms the library already has.

### `raise_for_status()` returns nothing

httpx2 hands the response back so the call can be chained, as in `r.raise_for_status().json()`. Here it returns nothing and `r.raise_for_status()` goes on its own line.

A `Response` is not copyable, so a method that gave one back would have to consume the receiver, and `r` would be gone afterwards. Two lines instead of one is cheaper than losing the response you were about to read. The error itself matches: `HTTPStatusError` for anything outside 2xx, naming the class of status, the code, the phrase the server sent and the URL, with the redirect location added when a 3xx got through because following was turned off.

The one line httpx2 adds and this does not is the MDN link. It doubles the length of every status error in a log for a URL the reader either already knows or can search for.

### `elapsed` is a `Duration`, and it covers the body

httpx2 gives back a `datetime.timedelta`, which Python already had. Mojo does not have one, so `httpx.Duration` is it: a nanosecond count with `seconds()`, `milliseconds()`, `microseconds()` and comparison. Deliberately small, because measuring an interval is all it is for.

The semantics match httpx2 otherwise. It is available once the body has been read or the response closed, and raises before that, because a number covering only the status line would quietly answer a different question than the one asked. It is per hop, so every response in a redirect chain's history reports its own exchange rather than the total.

### `links` is a list, and `link_url` resolves

httpx2's `Response.links` is a dictionary keyed on the `rel` value, falling back to the URL when there is no `rel`. Here `links()` gives back the parsed links in the order the header wrote them, and `link_url("next")` gives back the first link carrying that relation, resolved against the response URL and ready to fetch.

The dictionary loses two things. Two links in one header may carry the same relation, which is legal and which a dictionary silently drops one of, and a single link may carry several relations, as in `rel="next preload"`, which the dictionary files under a key nobody would think to look up. The list keeps both, and `has_rel` matches one relation out of the several, case insensitively, which is what RFC 8288 asks for.

Resolving is the other difference. A relative target is legal and common in a paginated API, and httpx2 hands it back unjoined for the caller to remember to join. `link_url` joins it, which means it raises for a response built by hand, since there is no URL to resolve against.

The parser is stricter about the syntax and looser about the input than httpx2's, which uses a regular expression. A quoted parameter value holding a comma, a semicolon or an equals sign is read whole here; in httpx2 the first drops everything after it and the last two stop the parameter scan. A `title` is prose written by a person, so a comma in one is ordinary rather than exotic.

### `num_bytes_downloaded` lives on the iterator too

httpx2 keeps the counter on the response and increments it as `iter_raw` yields. Here a response hands its stream to the iterator and cannot see another byte afterwards, so the counter is on `ByteChunks`, `TextChunks` and `LineChunks` as well as on `Response`.

`Response.num_bytes_downloaded()` answers for a response that was read or built by hand. For a streamed body being consumed through an iterator, which is the case a progress bar exists for, the iterator is what has the number.

### The one shot helpers take the TLS arguments and nothing else off `Client`

`httpx.get(url)` and the eight helpers beside it take the arguments that describe one request, plus `verify`, `cert` and `trust_env`, which describe the connection it goes out on. httpx2's helpers take those three as well, so this is parity rather than a departure, but it is worth writing down why the line falls there.

The client a helper builds is closed before the call returns and is never reachable from outside, so an argument left off is an argument a caller cannot supply at all. For the TLS three that would mean anybody talking to a private CA has to abandon the one line form on their first request, which is the form's whole reason to exist. Everything else that lives on a `Client`, the pool limits, the event hooks, the redirect ceiling, the base URL, describes behaviour across requests, and there is only ever one request here.

### A malformed digest challenge raises a protocol error

httpx2 raises `KeyError` from `DigestAuth._parse_challenge` when the challenge names an algorithm it does not implement, because the algorithm is looked up in a dictionary with no default. It raises its own `ProtocolError` for a missing `realm` or `nonce`.

Both cases raise `ProtocolError` here. The two failures are the same failure, which is a server sending a challenge this client cannot answer, and a `KeyError` escaping an HTTP library is a bug rather than an interface.

### `auth-int` is refused rather than raising `NotImplementedError`

A challenge offering only `qop="auth-int"` raises `ProtocolError` here and `NotImplementedError` in httpx2. Neither library implements it. The reason it is not implemented in either is that `auth-int` covers the request body in the hash, so the entire body has to be in memory and hashed before the headers can be written, and no server in the wild asks for it.

### A cross origin redirect drops `Host` rather than rewriting it

httpx2 sets `headers["Host"] = url.netloc` when a redirect crosses an origin. This library removes the stale `Host` instead and lets the head serializer put the right one back.

The bytes on the wire are the same. A request head is serialized with a `Host` taken from the URL whenever the request does not carry one of its own, so a request with no `Host` and a request whose `Host` was just set from the same URL produce identical output. What differs is that there is one rule about where `Host` comes from rather than two, and the one rule is already exercised by every request that was never redirected.

The visible difference is in `response.request().headers`, where a followed redirect shows no `Host` here and shows the new one in httpx2. A caller who wants to know where a request went should ask `response.url()`, which is the same answer in both libraries and is right whether or not a redirect was involved.

### UTF-16 with no byte order mark decodes little endian

A response labelled `charset=utf-16` whose body does not start with a byte order mark is decoded little endian here. httpx2 raises `UnicodeDecodeError` from `Response.text`, because Python's `utf-16` codec refuses a stream with no mark and the `errors="replace"` setting httpx2 passes does not cover that particular check.

Refusing to read a body over a byte order that is guessable from the content is worse than guessing. Little endian is what every browser assumes, it is what RFC 2781 permits as the fallback in practice even though it names big endian, and it is what essentially all unmarked UTF-16 on the web actually is. A caller who needs to know for certain still has `response.content()` and can decode it however they like.

`charset=utf-16le` and `charset=utf-16be` are unaffected, and so is a body that does carry a mark. This only covers the ambiguous case.

### Fewer known charsets

`decode_charset` handles UTF-8, UTF-16 and UTF-32 in both byte orders and with or without a mark, Latin-1, Windows-1252 and ASCII. httpx2 gets whatever codec Python ships, which is roughly a hundred encodings including the CJK multibyte ones.

A label naming an encoding outside that set is treated as unknown, and an unknown label falls back to `default_encoding` exactly the way a missing label does. So a response saying `charset=Shift_JIS` is read as UTF-8 here, and read as Shift-JIS by httpx2.

The set implemented is the one that appears on HTTP responses in practice, and everything in it is a table lookup or arithmetic. The ones left out need code page tables measured in tens of kilobytes each, and shipping them would mean carrying a character database in an HTTP client. A caller who needs one has `response.content()` and can hand the bytes to something that does the job properly, which is the same thing they would end up doing for an encoding neither library knows.

`response.encoding` still reports the label the server sent when it names something we can decode, and `is_known_charset` is public so a caller can ask before deciding.

### An unknown charset falls back rather than failing

This one matches httpx2 and is listed here because it looks like a deviation and is not. A `Content-Type` naming an encoding nobody implements does not raise. The body is read as `default_encoding`, which is UTF-8 unless the caller changed it. httpx2 does the same thing with a label Python has no codec for, and the reasoning is the same in both places: a server that names an encoding nobody implements has still sent a body, and that body is almost always UTF-8 anyway.

## Things that are not deviations

`response.text` never raises on the bytes. Every undecodable sequence becomes U+FFFD, one per maximal subpart, which is what Python's `errors="replace"` produces and therefore what httpx2 gives back. A body that lies about its encoding still fails in `response.json()`, because the JSON parser is strict, so the strict reading is available where it matters.

A byte order mark on a UTF-8 body is kept as U+FEFF rather than stripped. That is also what httpx2 does.

`response.encoding` returns the label the server wrote, lowercased, rather than a canonical name. `charset=UTF8` gives back `utf8` and not `utf-8`. httpx2 behaves the same way, because it lowercases the parameter and hands it to Python's codec lookup without normalising it first.
