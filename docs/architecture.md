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

Choosing between the six body arguments happens in one function above the encoders, which counts how many the caller filled in and raises when there is more than one. A precedence rule would be the other option, and it is what httpx2 has: pass `data=` and `json=` together and one of them is dropped without a word, so the caller finds out from the server, several layers away from the line that caused it. There is no reading of that call where the caller knew which body they wanted, so refusing and naming both is the more useful answer. The one pair that is not a conflict is `data=` with `files=`, which is a single multipart body carrying the fields and the files, fields written first, as a browser sends a form with a file input on it.

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

## A request body can stream too

The same `ByteStream` that carries a response body carries a request body, pulled a piece at a time and written as each piece arrives. `Request.streaming` is the constructor and `content_stream=` is the client argument.

The framing follows what the caller said rather than what this code guessed. With no `Content-Length` the body goes out as `Transfer-Encoding: chunked`, because there is nothing else available when the length is not known at the time the head is written. A caller who does know the length can set `Content-Length` and get a length framed body instead, which is worth having because chunked request bodies are still handled badly by some servers and more proxies.

A source that fails halfway leaves the connection closed rather than in `SEND_BODY`. Part of the body is already on the wire and the server has been told how much to expect, so there is nothing to recover and no way to take back what went out.

Such a body can only be sent once, which makes redirects and retries a problem, and the answer is to fail rather than to improvise. `Request.copy()` gives a copy with no body that remembers it is missing one, and sending that copy raises. The alternative is a redirect that quietly delivers an empty upload to the new location.

## A response carries the request that produced it

The transport takes the request and gives back the response, and the request goes back with it. `response.request()` is the request that was sent, `response.url()` is where it went, and `response.history()` is every response that redirected to this one, oldest first.

This is part of the httpx API we owe anyway, and it is also how the redirect loop gets the previous request without keeping its own copy of one. The alternative was to make the transport borrow the request instead of taking it, which the language will not express: a `Transport` is a thin function pointer and a thin function pointer cannot have a `mut` parameter, because that parameter would need an origin and a function pointer has no place to put one.

History is stored as a list of type erased boxes rather than a list of responses, because a struct in Mojo 1.0 cannot contain itself, not even through a `List`. The erasure is confined to the field and its accessor, so nothing outside `Response` knows the boxes are there.

## Following a redirect

The rules live in `_redirects.mojo` and none of them touch a response or send anything. They take the request that went out, the status code and the `Location`, and produce the next request. That keeps every rule testable without a server, which matters most for the ones that exist for security reasons, because those are the ones you want to be able to test exhaustively and cheaply.

They are httpx's rules rather than RFC 9110's, which is to say browsers' rules. The RFC says a 301 or a 302 preserves the method and only a 303 rewrites it to GET. Nobody implements that, two decades of servers were written against clients that rewrite, and 307 and 308 were registered precisely because the older codes cannot be trusted to preserve a method.

Three things are stripped on the way. `Authorization` is dropped when the origin changes, unless the hop is the same host upgrading itself from `http` on port 80 to `https` on port 443, which gives the credentials back to the host that already had them over a better connection than they arrived on. `Content-Length` and `Transfer-Encoding` are dropped when the method was rewritten, since they describe a body that is no longer being sent. `Cookie` is dropped on every hop, even a same origin one, because the jar computes it from the URL being requested and a header computed for the old URL is stale either way.

The loop is in the client. It sends, and if the response is not a redirect it returns it. If it is a redirect and the caller did not ask to follow, it attaches the next request to the response and returns, so a caller can step through a chain by hand with `client.send(response.next_request())`. If the caller did ask, it reads the body before going on, which is what lets the whole chain run over one connection: a connection with an unread body on it cannot go back to the pool. Streaming a chain streams only the last hop, for the same reason.

The budget is a hop count and not a cycle detector, because a server can redirect in a loop that never repeats a URL, so counting is the only check that always terminates.

## Auth is a state machine, and it wraps redirects

httpx writes an auth scheme as a generator. It yields the request to send, the client sends it, the response is fed back in with `send`, and the generator either yields another request or stops. The shape is right and Mojo 1.0 has no generators, so `_auth.mojo` splits it in two: `sign` returns the request that goes out first, and `next_request` is handed the response and returns either the next request or nothing. A scheme that only needs the first, like Basic, answers the second with nothing and costs no extra round trip.

Nothing in `_auth.mojo` sends anything, which is what makes a scheme testable without a server and what keeps the retry policy in the client rather than spread across three schemes.

Auth is the outer loop and redirects are the inner one, the same order httpx uses. A challenge can come back from the end of a redirect chain, and answering it means starting the chain again from the URL the caller asked for. The other order would answer the challenge at whichever hop produced it, which is a different server asking a different question. What that costs is one argument: the redirect loop takes the history an auth retry has already accumulated, so the `history` a caller finally sees spans both loops in the order things actually happened.

`AnyAuth` is the same type erasure as `AnyTransport`, and its `copy` shares state rather than duplicating it. The client takes a copy on every send, and a digest scheme that forgot the challenge it had already been given would pay the extra round trip on every single request instead of only the first.

## The cookie jar knows nothing about responses

`_models/cookies.mojo` sits at the bottom with `URL` and `Headers` and never imports `Response`, which would be a cycle since a response has to be able to hand back the cookies it set. So the jar's widest entry point is `extract(url, headers, now)`: a URL, the headers that came back for it, and the time. Everything above that is glue in two places, `Response.cookies()` for the one response and `Client` for the session.

The client is where the interesting part is, because there are three moments and each one is easy to get wrong. Cookies are written into the jar as soon as a response comes off the transport, before the redirect loop has decided whether to follow it, because a login answering 302 with the session cookie on it is the ordinary shape and a jar that only read the last response of a chain would miss it. The `Cookie` header is computed in `build_request`, from the URL the request is actually going to. And it is computed again for every redirect hop, because the redirect builder strips `Cookie` unconditionally and a header worked out for the previous URL is wrong for the next one whether or not the origin changed.

A `Cookie` header the caller wrote themselves is never touched. That is what urllib's `add_cookie_header` does underneath httpx, and the reason is that a hand written `Cookie` is nearly always somebody reproducing a captured request, where a jar folding its own values in would change the request being reproduced.

Per request cookies merge over the client's for that one call and are not carried across a redirect, which is also httpx's behaviour. They were an argument about one call to one URL, and the hop is a different URL.

## The mocks are two, because there are two kinds of test

`MockTransport` takes one handler and answers everything with it. That is what you want when the reply depends on the request, and it is the shape httpx ships. `MockRouter` is a table of routes tried in order, which is what you want when the test is about a handful of endpoints and hand written branching inside a single handler would bury the point. This is the ground `respx` covers for httpx2, in the tree rather than as a separate package, because the transport boundary is already here and a separate package would only be repackaging it.

A route is built by chaining, and each builder takes the route and gives it back. The alternative was a constructor with a dozen optional arguments that a reader has to count commas in. It also means a route is never half built: `Route.get("/users").respond(200)` is one expression, and there is no window where a route exists with no answer attached.

Matching is a subset everywhere it can be. Required headers and query parameters have to be present with the given values, and anything else on the request is ignored, because a request carrying a cache buster the test does not care about is still the request the test meant. Order decides ambiguity, first match wins, and `Route.any()` last is how a catch all is written. A request that matches nothing raises rather than answering 404, since a mock that quietly answered would turn a typo in the code under test into a plausible looking failure somewhere else entirely.

Reading the recording back needed one addition. A client takes ownership of its transport and erases the type, so after handing a router over there is nothing left to ask. `AnyTransport.state[T]()` is the way back, and it works because an `ErasedBox` copy shares rather than duplicates: take a `copy()` of the erased transport before handing the original to the client and the copy is the same router.

## A hook takes the value and gives it back

httpx hands a hook a request or a response and lets it mutate what it was given. `_hooks.mojo` cannot: a thin function pointer in Mojo 1.0 cannot take a `mut` parameter, and thin function pointers are the whole basis of the vtable that makes a pluggable hook storable at all. So the signature passes ownership in and takes it back out, and a hook that changes nothing writes `return request^`.

It turns out to be the better contract. A hook that raises has already taken the response with it, so the response is destroyed as that frame unwinds and the connection it was holding goes back to the pool, with nothing in the client having to remember to close it. httpx has an explicit `response.close()` in its `except BaseException` for exactly that, and there is nothing here for it to do.

Where the hooks run is copied from httpx and it matters. Both lists run inside the redirect loop, once per send, so a call that follows two redirects runs a request hook three times and a digest handshake runs it twice. A hook that only saw the last request of a chain would be a hook that missed the request that actually got redirected. The request hook runs after headers, cookies and auth have all been merged, so it sees what the transport is about to be handed rather than what the caller wrote. The response hook runs after cookies have been extracted, so a hook sees the jar already updated, and before the history is attached, which is where httpx runs it too.

`EventHooks` holds `List[AnyRequestHook]` and `List[AnyResponseHook]`, which are the same erasure as `AnyTransport` and `AnyAuth`, and `copy` shares state rather than duplicating it so a handle the caller kept and the one in the client are the same counter. Both lists are iterated by index rather than with `for ref`, because iterating a list in Mojo 1.0 wants a copyable element and a hook is deliberately not one.

Boxing a hook is what turned up a real bug in `ErasedBox`. A stateless hook, the kind that only prints a line, is a struct with no fields and therefore no size, and asking a `List` for room for one value of a zero sized type hands back the alignment sentinel rather than an allocation. Freeing that number corrupts the heap, somewhere else and much later. The box now wraps whatever it is given in a `_Cell` carrying a padding byte, so there is always something real to allocate and free.

## What the client merges, and where

A client is configuration plus a transport, and every option on it is one of three shapes. Some merge with the per request value, which is headers, query parameters and cookies, and the per request side wins on a collision. Some are a fallback the request can replace outright, which is the timeout, the redirect policy and the auth scheme. And some belong to the client alone, which is the base URL, the redirect limit, the hooks and the connection pool, because a single call cannot sensibly have its own.

The merging happens in `build_request`, not in `send`. That is deliberate: `client.build_request(...)` gives back the request the client would have sent, fully merged, so a caller who wants to inspect or alter it before it goes out gets the real thing rather than a sketch of it. `send` then does the parts that can only be decided at the last moment, which is the deadlines and the auth scheme.

`transport=` is an ordinary argument of the same constructor rather than a separate entry point. Passing one skips building the pool, which makes `limits`, `verify`, `cert` and `trust_env` dead letters, since all four describe a pool that no longer exists. httpx behaves the same way and for the same reason. Keeping it on the main constructor is what lets a mock go underneath a client that still has its base URL, its headers and its redirect policy, which is the only version of transport swapping that tests anything.

`default_encoding` is the odd one out. It is client configuration that has to end up on a response, so `_send_following_redirects` copies it onto each response as it arrives, before the cookie jar and before the hooks. Before the hooks matters: a response hook that calls `text()` is the ordinary case, and a hook that saw the bare default would decode a Latin-1 body differently from the caller who reads the same response a line later.

## The hash functions are written out, not linked

MD5, SHA-1, SHA-256 and SHA-512 are implemented in `_util/digest.mojo`, along with base64 in `_util/base64.mojo`. Both exist for one caller, which is digest and basic authentication.

There was a shorter path and it was the wrong one. This library already loads OpenSSL, so binding `EVP_Digest` would have been a few lines. But OpenSSL here is optional by design: it is needed for `https://` and for nothing else, and a digest authenticated request to a plain `http://` server should not begin by hunting for a TLS library. Four hash functions come to about as much code as the binding and the fallback path would have, and they have no failure mode that depends on what is installed.

None of the four is worth anything as a password hash, and MD5 and SHA-1 are not worth anything as signatures either. They are here because the server picks the algorithm in a digest challenge and most servers still pick MD5, so a client that refused would simply not be able to talk to them. Nothing else in this library uses them.

They are one shot rather than incremental, because a digest challenge hashes a few hundred bytes of header and there is no body to stream.

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
