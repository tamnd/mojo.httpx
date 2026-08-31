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
