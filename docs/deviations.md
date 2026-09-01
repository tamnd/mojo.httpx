# Deviations from httpx2

The goal is that code written against httpx2 reads the same here, and that a request going out over the wire has the same bytes in it. Where that is not possible, the difference is deliberate and it is written down on this page rather than left for somebody to find at three in the morning.

Two kinds of difference show up. The first kind is forced by the language: Mojo has no dynamic `Any`, no exception subclassing, no generators and no keyword argument packing, so anything built on those has to be spelled differently. The second kind is a judgement call, where copying httpx2 exactly was possible and we chose not to. The second kind is much shorter and each entry says what the alternative was.

## Forced by the language

| httpx2 | mojo.httpx | Reason |
| --- | --- | --- |
| `r.json()` returns `Any` | returns a typed `Json` value with accessors | Mojo has no dynamic `Any`, so the type check has to happen at the point of access |
| `except httpx.TimeoutException` | `if httpx.is_timeout(e)` | Mojo has one error type and no exception subclassing |
| duck typed transports | a generic transport plus an erased vtable | Mojo has no trait objects |
| `async with AsyncClient()` | explicit `await client.aclose()` | Mojo has no async context managers |
| `for chunk in r.iter_bytes()` | `while chunks.has_next(): chunks.next()` | Mojo has no generators, and a `for` loop swallows an error raised out of `__next__` |
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

### `Accept-Encoding` asks for `identity`

httpx2 sends `Accept-Encoding: gzip, deflate, zstd`. This client sends `identity`, because it has no decoders yet.

Asking for a coding you cannot undo is worse than not asking. The server compresses, the client cannot decompress, and `response.text()` hands back a string built out of the compressed bytes and calls it the body. Advertising only what the client can actually do means a body that arrives is a body that can be read. When the decoders land the header becomes the list of what is compiled in, and this entry goes away.

This is one of the two differences the parity suite is allowed to see. See [testing](testing.md).

### Headers go out in a different order

Both clients send the same headers with the same values; they order them differently. We put the ones the caller set immediately after `Host`, so a trace shows what the request was about before it shows the boilerplate, and the framing headers last, because the writer is what adds them. httpx2 puts its own defaults first and the caller's after, and writes `Content-Length` before `Content-Type`.

Field order carries no meaning in HTTP for any header either client sends, so there is nothing to be right about here. It is written down because the parity suite compares order and would otherwise be reporting a difference with no explanation attached.

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
