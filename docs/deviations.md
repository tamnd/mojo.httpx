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

## Judgement calls

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
