# Architecture

This is the short version. It covers the layer model, the two decisions that shape everything else, and the constraints in Mojo 1.0 that forced them.

## What we are actually building

In Python, httpx sits on httpcore, which sits on h11, h2, anyio and the socket and ssl modules from the standard library. Mojo has none of that. There is no socket module, no TLS module, no threading, no async runtime, and no HTTP anything.

So the scope here is the equivalent of httpx2, httpcore2, h11, h2, anyio and truststore combined. That is worth stating plainly because it explains why the milestone list is long and why the first three milestones produce no user visible API at all.

## Layers

```
L6  CLI                       httpx/cli/
L5  Client, AsyncClient       config merging, redirects, auth flow, event hooks
L4  Transport                 pooling, retries, the pluggable boundary
L3  Protocol                  HTTP/1.1 state machine, HTTP/2 framing and HPACK
L2  Stream                    a byte stream with deadlines, TLS wraps this
L1  I/O                       sockets, DNS, poll, timers, all over libc FFI
L0  Primitives                URL, Headers, Cookies, Duration, JSON, errors
```

Dependencies only point downward. A lint enforces that, because the one thing that reliably destroys a layered design is a convenience import going the wrong way.

The transport boundary at L4 is where it is for a specific reason. It is the seam that makes `MockTransport` possible, and testability is a large part of why people pick httpx in the first place.

## Decision one: function pointer vtables, not trait objects

httpx2's developer experience depends on runtime pluggability. You pass `transport=`, `auth=`, `mounts=`, `event_hooks=` and the library calls back into whatever you gave it.

Mojo 1.0 has no trait objects. You cannot write `List[Transport]` and put two different implementations in it. `AnyTrait` exists in the compiler but is not something a user can write, and struct fields reject trait types outright. There are also no closures that can be stored in a field.

What does work is a thin function pointer:

```mojo
@fieldwise_init
struct Handler(ImplicitlyCopyable, Movable):
    var call: def(String) raises thin -> String
```

That is a concrete type, it can live in a struct field or a `List`, and any top level `def` with a matching signature can go in it. So every runtime polymorphic boundary in the project is a small vtable struct holding thin function pointers plus an `ArcPointer` to the implementation's state, with a generated shim that casts the pointer back and calls the real method.

Above L4 that is what we use. Below L4, where the set of implementations is closed and known at compile time, everything is static generics instead, so there is no indirection on the hot path.

## Decision two: one protocol implementation, two instantiations

The sync and async versions of an HTTP client are the same state machine driven by different I/O. Writing both by hand means maintaining two copies of the smuggling defences, which is how you end up with a bug in one of them.

Instead every layer from L3 up is generic over a `ByteStream` trait. `TcpStream` and `AsyncTcpStream` both satisfy it, the protocol code compiles once, and it instantiates twice. Roughly ninety percent of the code is shared.

## Plain and TLS streams are one type, not two

`H1Connection` holds a `Stream`, which is either a plain socket or a TLS session over one, and nothing in the protocol code branches on which. `http://` and `https://` differ in how the bytes are carried and in nothing the state machine cares about, so that is the only place the difference should live.

`Stream` is a tagged union of the two concrete stream types rather than a vtable, which is the opposite of the choice at L4. The reason is that the two sets are different shapes. The set of transports is open, because users pass their own, so it needs runtime dispatch. The set of streams is closed and always will be, because a stream is either a socket or TLS over a socket, and adding a third would be our change to make and not a user's. A closed set gets a union, an open one gets a vtable, and paying for indirection on every read of every byte to support an implementation nobody can write is not a trade worth making.

## JSON is an arena, and the parser has its own stack

A JSON value is normally a struct that holds a list of itself. Mojo 1.0 will not compile that: a struct cannot be `Deinitable` while one of its fields needs the struct to already be `Deinitable`, and the only way out is a raw pointer, which is not allowed above L2.

So a document is two flat lists instead. One node per value, holding offsets and the indices of its first child and next sibling, and one byte buffer holding every decoded string and every number as the server wrote it. `Json` owns those two lists and `JsonValue` is a borrowed view of one node in them, which is two spans and an integer. Because the two spans come from two different fields, and Mojo tracks each field's origin separately, the view carries two origin parameters rather than one.

The constraint produced a better design than the one it ruled out. Parsing a body is two allocations that grow rather than one per value, indexing walks integers and copies nothing, and a value provably cannot outlive the document it came from.

The parser is iterative with an explicit stack on the heap, and refuses anything nested deeper than two hundred. A response body is attacker controlled, and a recursive descent parser handed a few hundred thousand open brackets exhausts the machine stack, which is not an exception the caller can catch. That is a one line denial of service against anything that calls `r.json()`, so the recursion had to go. The serializer is still a plain recursion, which is sound because the depth limit is enforced on built documents too, not only on parsed ones.

## Multipart follows the browsers, not the RFC

`multipart/form-data` is specified by RFC 7578, and what servers actually implement is the WHATWG HTML form submission algorithm. Where the two disagree this library follows the browsers, because the receiving framework was written against browser output and a body that is correct by the RFC and different from a browser's is a body some fraction of servers parse differently.

The concrete case is escaping a filename. RFC 2231 has a proper mechanism, `filename*=UTF-8''...`, and enough server side parsers do not implement it that using it means correct bodies which some frameworks read as having no filename at all. So a filename goes out as raw UTF-8 with exactly three characters escaped, the quote and the two line ending bytes, spelled `%22`, `%0D` and `%0A`. That is what a browser sends and it is the whole of what stops a filename from closing the quoted string and writing headers the caller did not write.

The boundary is sixteen bytes read from the operating system through `getentropy`, not from `std.random`, which is seeded from the clock. Nothing inside a part is escaped, so the boundary is the only thing separating one part from the next, and a boundary an attacker can predict is a boundary they can embed in a value to forge a part. Every part is also scanned for the boundary before the body is built. The random draw makes a collision impossible to arrange and the scan makes it impossible to ship, and having both is why a collision ends as a second draw rather than as a server reading parts nobody sent.

## The content type is decided here and written by the client

Each encoder returns bytes plus the content type that describes them, and touches no header block. Whether the type is actually written, and whether the framing ends up as `Content-Length` or `Transfer-Encoding`, is the client's call, because only the client knows what the caller passed in `headers=` and whether an explicit type should win.

`content=` produces no content type at all. Bytes with no further description are `application/octet-stream` as far as HTTP is concerned, but guessing that on the caller's behalf means silently labelling every hand built body, including ones that are already JSON or already form encoded. httpx2 sets nothing here and neither does this.

## Decoding a body never fails

`response.text()` cannot raise on the bytes. Every undecodable sequence becomes U+FFFD, one per maximal subpart, which is what Python's `errors="replace"` produces and therefore what httpx2 gives back. The reasoning is that a body which does not decode still deserves to be shown: a client that threw here would turn a mislabelled response into one the caller cannot inspect at all, at exactly the moment they most want to look at it.

The strict reading has not gone anywhere. `response.json()` refuses invalid UTF-8, `Bytes.to_string` refuses it, and `response.content()` is always there for a caller who wants to decode it themselves. So a body that lies about its encoding fails where failing is useful and gets shown where showing is useful.

Which encoding gets used is three checks in order. The `charset` parameter of the content type, if it names something we can decode. Then `default_encoding`, which is either a fixed name or a detector function the caller supplied. Then UTF-8. An unknown label falls back rather than failing, the same way a missing one does, because a server that names an encoding nobody implements has still sent a body and that body is almost always UTF-8 anyway.

The set of encodings is smaller than Python's, and `utf-16` with no byte order mark is read little endian where httpx2 raises. Both are written up in [deviations](deviations.md).

## A body can only be read once, and the response says so

A response body is either sitting in memory or still arriving on a socket, and everything that walks one goes through a single interface, `ByteStream`: pull a chunk, get bytes, get an empty chunk when there is no more. A body that came back with the response is a buffered source, a body still on the wire is a connection, and neither `read` nor any of the four iterators can tell the difference.

Three flags describe where a response is. `_read` is whether the whole body is in memory, which is what decides whether `content()` answers or raises. `is_stream_consumed` is whether the stream has been handed to somebody, and `is_closed` is whether anything more can come out. The first is private because a caller who wanted it should be calling `content()` and getting a real answer or a real error. The other two are public because httpx2 exposes them and because they are what a caller wants to know after catching a `StreamConsumed`.

Handing the stream out is a one way door. `iter_raw`, `iter_text` and `iter_lines` set both public flags before returning anything, so the second caller is turned away rather than getting a half body that starts wherever the first caller stopped. `iter_bytes` is the exception, and deliberately so: on a response whose body is already in memory it re-reads what is there, which costs nothing and asks nothing of the connection. That is httpx2's behaviour too.

An empty chunk always means the end and never means "nothing yet". A source with no bytes available blocks until it has some or until its deadline runs out. This matters more than it looks: a client that read a pause as an ending would report a truncated body as a complete one, and the caller would have no way to find out.

The three iterators stack. `LineChunks` pulls from `TextChunks` pulls from `ByteChunks` pulls from the stream, so the buffering that makes each step safe is written once. Each step has one thing it holds back. `ByteChunks` holds bytes until it has a full chunk of the size that was asked for. `TextChunks` holds the tail of a character whose remaining bytes have not arrived, which is the whole reason it is not `decode(chunk)` in a loop: without it every multibyte character that straddled a network boundary would come out as replacement characters, and which ones broke would depend on how the server sized its writes. `LineChunks` holds a trailing carriage return, because its newline may be the first byte of the next read.

## Who owns the connection while a body is streaming

The pool normally runs the whole exchange itself and never lends a connection out. A borrowed connection dropped on an error path is a leaked descriptor at best, and at worst it goes back into the pool in an unknown state and hands somebody else's response to the wrong caller.

Streaming cannot work that way, because the point of it is that the call returns while the body is still arriving. So `stream_request` does lend a connection out, and everything about the design is aimed at making the give back automatic. The connection is owned by a `PooledSource`, which is the `ByteStream` behind the response. When the body ends the source puts the connection back in the pool. When the response is closed early it closes the connection instead, because the rest of the body is still on the wire and a connection whose next byte is the middle of an old response is worse than no connection at all. When the response is simply dropped, the source's destructor does the same thing. There is no path where the caller has to remember anything, which matters because the path a caller forgets is the error path.

The lease count is decremented on all three of those paths. Getting that wrong is not a leaked socket, it is worse: the socket would be closed by its own destructor and the pool would go on counting it as in use, so a program that abandoned a few streamed responses would eventually be told its pool was full when it was empty.

The pool is held through a shared handle rather than borrowed, because a streamed response outlives the call that produced it and may outlive the transport too. `httpx.stream()` is the extreme case: the one shot helper closes its client before returning, and the response still works, because the connection carrying the body was never in the pool to be closed and the pool itself stays alive as long as the source holds a handle on it.

## Parsing rule

`len()` on a `String` is a hard compile error in Mojo 1.0, on the grounds that the byte count and the character count are different answers and the caller should say which one they want. That is a good decision by the language, and for this project it points somewhere useful: every parser works on `Span[UInt8]` and never touches `String` at all. Strings only appear at the boundary where a user sees a value.

This also removes a whole class of protocol bug, because header parsing over anything Unicode aware is how you get header smuggling.

## Async is the open risk

Mojo has `async def` and `await`, and they compile. What it does not have is an executor, an event loop, or any async I/O. `Coroutine` is a linear type with no way to store or schedule it.

So M6 builds an event loop from scratch on kqueue and epoll. That is the single riskiest part of the plan, and the milestone opens with an explicit go or no go decision. If the language cannot support it yet, the fallback is a thread pool backed `AsyncClient` with the same API surface, so user code does not change when the real runtime lands. Everything under `httpx/_io/` is marked internal precisely so it can be replaced without a breaking release.

## Distribution

`.mojopkg` is tied to the compiler version that produced it, and the Mojo docs say directly that it is not meant as a distributable format. A package built with 1.0.0 will not import under 1.0.1. So we ship source, and use `.mojopkg` only as a local build cache. This is not negotiable and it shapes the packaging work in M8.

## The full spec

This page is a summary. The complete design, twenty documents covering every module down to the wire format and the attack surface, is the reference the milestone issues point at. Ask in an issue if you need a section of it published here.
