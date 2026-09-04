# Async support

`AsyncClient` is used exactly like `Client`. There is no `async with`, no `await` on a client method and no `asyncio.gather`, because Mojo's async is not asyncio and a coroutine here cannot be handed to a caller. What you write is ordinary code, and the concurrency is a call.

The first half of this page is how to use it. The second half is the design and the measurements behind it, which is worth reading before deciding how much to lean on it.

## One request

```mojo
from httpx import AsyncClient, URL


def main() raises:
    with AsyncClient(base_url=URL("http://api.example.com")) as client:
        var r = client.get("/users")
        print(r.status_code)
```

Every option `Client` takes, `AsyncClient` takes, and every method is spelled the same. `close()` and `aclose()` are the same call, since nothing about closing a client suspends.

Sending one request at a time through the async client buys you nothing over the synchronous one. It is a little slower, because each wait goes through the scheduler. The reason to be here is the next section.

## Several at once

```mojo
import httpx
from httpx import AsyncClient, URL


def main() raises:
    with AsyncClient(base_url=URL("http://api.example.com")) as client:
        var pending = List[httpx.Request]()
        pending.append(client.build_request("GET", "/users/1"))
        pending.append(client.build_request("GET", "/users/2"))
        pending.append(client.build_request("GET", "/users/3"))

        var answers = httpx.gather(client, pending^)
        for i in range(len(answers)):
            print(answers[i].status_code)
```

The answers come back in the order the requests went out. Everything the client does for one request it does for each of these: the hooks run per send, the cookie jar is read and written, redirects are followed for anyone who asked, and an auth scheme gets its retry, with each request carrying its own copy of the scheme so a digest challenge answered for one is not an answer the others give too.

`gather` takes a list rather than letting you assemble the requests yourself. That is not a simplification, it is the only shape available: a `Coroutine` in Mojo 1.0 is a linear type, so it cannot be stored in a variable, put in a list or returned, and there is no way to hand you a request in progress to combine with someone else's.

The first failure is raised and the other responses are dropped, which is what `asyncio.gather` does unless told otherwise. Every request still runs to the end first, so no connection is left leased. There is no `return_exceptions` equivalent yet.

## Streaming

Same shape as the synchronous client, with the body coming out through `aiter_bytes`, `aiter_text`, `aiter_lines` and `aiter_raw`.

```mojo
from httpx import AsyncClient


def main() raises:
    with AsyncClient() as client:
        with client.stream("GET", "http://example.com/big.log") as r:
            var lines = r.aiter_lines()
            while lines.has_next():
                print(lines.next())
```

Each of those is the same call as the name without the `a`. That is the honest answer rather than a shortcut: what differs between a synchronous stream and an async one is the source underneath, and neither the response nor the iterator can tell which it has. The names exist so that code ported from httpx2 keeps its shape, and so do `aread` and `aclose`.

A caller sitting on a half read body is holding a connection and no worker at all, which is the property that makes this worth doing. What it does not buy is reading several bodies at once: each `read_chunk` blocks the thread that called it, and there is no `gather` for streams.

## What it will not do

`https://` works, over HTTP/1.1. What is out is HTTP/2, because the async pool does not offer `h2` in ALPN, and a `CONNECT` tunnel or a SOCKS proxy, because both need a handshake finished before the connection is usable and there is nowhere in the connect loop to put one. Forwarding a plain `http://` request through an HTTP proxy does work.

There is no `task.cancel()`, because there is nothing that stands for a request in flight to give you. What stops a request is its deadline, which is checked several times a second rather than at the end of whatever the server is doing, or closing its response. Either way the connection is closed rather than pooled and the pool slot comes back.

Every entry point blocks the calling thread. The point is that a request waiting on a socket does not hold a worker, not that your own thread is free.

[limitations.md](limitations.md) has that list in full, and the rest of this page is why.

## The decision this came out of

M6 was written as a maybe. The plan said Mojo has `async def` and `await` but no executor, no event loop and no async I/O, that `Coroutine` is a linear type with nowhere to store it, and that the milestone should open with a go or no go rather than with code. What follows is that decision and the evidence behind it.

Run the evidence yourself:

```bash
pixi run probe-async
```

## What is actually there

Mojo 1.0.0 ships a task scheduler in `std.runtime.asyncrt`. That is more than the plan assumed. `create_task` takes a coroutine and returns a `Task`, awaiting a `Task` suspends the awaiting coroutine, `TaskGroup` takes a number of coroutines not known until it runs, and `_run` drives a coroutine to completion from ordinary code. All of it works today on the toolchain we pin.

The numbers from one run on the development laptop, an M-series with four performance cores:

| What | Result |
| --- | --- |
| `parallelism_level()` | 4 |
| four quarter second naps as tasks | 260 ms |
| eight of the same | 520 ms |
| four coroutines each awaiting one nap | 259 ms |
| eight through a `TaskGroup` | 512 ms |
| a scheduler round trip | about 740 ns |

The last row is the only one that moves between runs. Repeating it on this laptop gives anywhere from 740 ns to 1187 ns depending on what else is running, and the quietest machine in the fleet, a thirty two core box under WSL2, gives 1795 ns. Everything the decision below rests on is true across that whole range, so read the row as a couple of microseconds rather than as a measurement.

Three things follow from those.

Tasks really do run at the same time. Four naps in the time of one is a thread pool doing its job, not an interleaving.

Awaiting hands the worker back. Four coroutines that each do nothing but wait for another coroutine finish in one nap rather than two, which means a waiter is parked rather than parked on top of a thread. Without that property a client built on tasks deadlocks the first time a request waits for a connection, so it is the single most important line in the probe.

Blocking work is capped at `parallelism_level()`. Eight naps take twice as long as four because a `sleep` holds its worker, and a blocking socket read is a `sleep` that happens to be waiting on a peer. The pool is sized to the performance cores, four here on a ten core machine, and no environment variable we tried changes it. It is a pool for compute, and compute is not what an HTTP client spends its time on. The cap moves with the machine and the rule does not: on the thirty two worker host the same eight naps finish in one nap's time, and it would take thirty three of them to start queueing.

## What is missing

There is no async I/O and no way to complete a task from outside. Nothing in `asyncrt` lets our own code resume a parked coroutine when a file descriptor becomes readable, which is exactly what a reactor needs. A `Task` is completed by its coroutine returning and by nothing else.

Two smaller gaps shape the API rather than the design. `Task` is not `Movable`, so there is no list of tasks to hold and no awaiting a set of them one at a time, which is why `gather` has to be built on `TaskGroup`. And `TaskGroup.create_task` only takes a coroutine returning nothing, so results have to be written somewhere both sides can reach rather than returned.

`Coroutine` is still linear, still not `Deinitable`, and still cannot be dropped or stored. That was the original worry and it turns out not to matter, because `create_task` is somewhere to put one and it is the only place we need.

## The decision

Go, and build the real loop rather than the thread pool fallback.

The fallback in the plan was `AsyncClient` over a pool of threads running the blocking client, with concurrency bounded by the pool. We can do better than that, and the reason is the last row of the table. A scheduler round trip costs a couple of microseconds, so a coroutine that has nothing to do can give way and be picked up again thousands of times in the time a network round trip takes. That turns the missing wake-up into a polling problem rather than a blocking problem, and a polling problem is one we can solve.

The shape is:

Sockets go non-blocking. A read that would block returns immediately instead of holding a worker.

A coroutine that cannot make progress looks at its descriptor with a zero timeout `poll`, and if there is nothing there it gives way and asks for a worker again. It never blocks while it has nothing to do, so the number of requests in flight stops being bounded by `parallelism_level()`.

Looking stops being free eventually, so the wait has two phases. For the first sixty four rounds, about a tenth of a millisecond, the poll timeout is zero and the worker goes straight back to the scheduler. After that the poll timeout is one millisecond, which is the kernel doing the waiting instead of us. A reply from a fast server arrives during the first phase. A wait on a slow one falls through to the second and stays there, costing a few thousand wakeups a second across the whole pool and no measurable CPU.

There is no shared reactor and no registration table, which is a change from the design sketched here before any of it was built. One shared kqueue would learn about every ready descriptor in a single syscall, but learning is not the slow part. A waiter still has to be handed a worker before it can act on the news, and being handed a worker is exactly what the per waiter poll is already waiting for. The table would buy nothing and would cost a lock, a wake up path, and an origin parameter threaded through every async type in the library.

What the missing wake up does cost is a rotation. Only `parallelism_level()` waiters sit inside a one millisecond poll at a time, so with more waiters than workers each one gets its turn periodically rather than continuously. The delay before a ready socket is noticed is the number of waiters divided by the number of workers, times one millisecond. Sixteen waiters on four workers is four milliseconds. That is the price of the missing wake up, and it is written down here so that nobody has to rediscover it in a profile.

Deadlines are the ones from the sync path. `Deadline` already exists, already knows how to be a timeout on a syscall, and every poll slice is clamped to what is left of one, so a hung peer is broken out of by the same rule in both clients.

The insertion point is smaller than it sounds. `TcpStream.read` and `TcpStream.write` are already non-blocking calls in a loop, and the only thing they do when the kernel says it would block is call `self._wait(POLLIN, deadline)`. An async stream is the same two loops with a different `_wait`.

## What the compiler allows

The design above is what the machine can do. What the toolchain will compile is narrower, and eleven of its limits shaped every line of `httpx/_io/aio.mojo`, `httpx/_io/aio_socket.mojo`, `httpx/_io/aio_connect.mojo`, `httpx/_proto/h1/aio.mojo` and `httpx/_pool/aio_pool.mojo`. Each one has a reproducer at the bottom of `tools/probe/async.mojo`, so a later toolchain can be checked against them rather than guessed at. None of them is a style choice and all of them should be deleted the day they stop being true.

They get harder to hit as the coroutine gets longer, and the last four were all found in the pool, which is the longest one in the library. Reading them as a list understates that: what they add up to is that a coroutine with more than one suspending loop in it has almost no room left for anything that is not a loop.

A coroutine cannot raise. `create_task`, `TaskGroup.create_task` and `_run` all refuse a `RaisingCoroutine`, and the one shape that would let a non raising wrapper catch on their behalf, an `await` of a raising coroutine inside a `try`, fails to lower. So every async function reports failure as a value, an `Outcome`, and the conversion back into an exception happens on the synchronous side of the boundary. Where that boundary falls is visible in the connect path. Starting an attempt and reading its verdict out of `SO_ERROR` both raise, and only the middle waits, so only the middle is a coroutine and the two ends stay ordinary functions.

Coroutines barely compose. A coroutine that is `await`ed may suspend exactly once, and not inside a loop. Suspending twice compiles and then hangs forever at run time, with nothing to attach a debugger to. Suspending inside a loop at least fails loudly, with `cannot guarantee tail call due to mismatched return types`. A coroutine handed to `_run` or to `TaskGroup.create_task` has no such limit and may suspend as often as it likes, which is why concurrency works at all. So every waiting function in `httpx/_io/` is a leaf: it carries its own poll loop rather than awaiting a shared one, and the repeated lines are the price of the loop existing.

Anything a coroutine writes from inside a suspending loop has to be flat. A value whose type has a field that is itself a struct, or that owns memory, fails to lower with `operand #0 does not dominate this use` pointing into the nested constructor. One write site survives it and two do not, which is what made this look like several unrelated bugs before it was reduced. That is why there is one result type, `Outcome`, rather than one per operation, and why it stores an unwrapped `UInt32` instead of an `ErrorKind` and a `UInt8` instead of an `Op`.

A `Span` cannot be resliced in a suspending loop. `data[sent:]` crashes the compiler with no message, only its own stack dump. `TcpStream.try_write` takes an offset rather than a caller sliced span because of it, and the synchronous writer passes an offset too rather than there being a second entry point only the async one uses.

A coroutine's own frame cannot hold owned memory across a suspension, and the loud half of that is the paragraph above. The quiet half is worse. A `List` a coroutine appends to inside a suspending loop sometimes fails to lower with `'pop.store' op failed to verify that pointer element type`, and sometimes compiles and comes back empty at run time with nothing said at all. Four appends, zero bytes, no diagnostic. In a response body reader that is a download that silently truncates, and it is the reason `tools/probe/async.mojo` exists as a thing that is run rather than a thing that was once read. A `String` returned into the frame and an `Error` bound by `except` fail the same way with `operand #0 does not dominate this use`, and so does a field read through two levels of struct, `conn[].fd()` where `fd` forwards to an inner stream. The way out is that memory the coroutine does not own is fine: a pointer to a caller's struct, mutated in place by ordinary synchronous methods, works and is tested.

A coroutine that makes a `TaskGroup` may not have an `Optional` anywhere in its own frame. The whole reproducer is `var v = Optional[Int](5)` next to a group that is never told about it, and the compiler goes down with a stack dump and no message. The `Optional` can be dead before the group is made and it still happens. Drop the group and the same `Optional` is fine. This one is easy to hit without ever typing the word, because the conversion for an `Optional` parameter happens in the caller's frame, and `write_deadline` takes `Optional[Float64]`, so putting `write_deadline(5.0)` in a `create_task` call is enough. Build such a value in synchronous code and pass it in as an argument. Every test that drives more than one exchange takes its deadlines that way for this reason and no other.

A guard between two suspending loops may only read a scalar. Three suspending loops in a row are fine, and so is a loop an `if` may skip entirely, both of which the connection pool needs since a request served from an idle connection does no connecting. What is not fine is deciding between them by looking at anything derived from owned memory. A helper returning `len(work[].bytes) < 100` fails to lower with `operand #0 does not dominate this use`, and moving the same test inline into the coroutine, which reads like the obvious simplification, crashes the compiler with a stack dump and no message even when the field is a scalar. So the dereference belongs in a synchronous helper and what the helper reads has to be a count kept beside the list rather than the list's own length. The suspension form matters here too: `_ = await create_task(nothing())` works everywhere else and fails in this shape with `Instruction does not dominate all uses`, because the discarded task handle is one more value in the frame, which is why `yield_now` exists as a function rather than as a line repeated at each call site.

A coroutine may call a given function once after a suspension, and not twice. Two `_abandon(conn)` calls on two early return paths, both of them after a suspending loop, get as far as bytecode and are then rejected with `invalid value index: 75` and a note saying which MLIR produced it. Two different functions in those same two places are fine. So is the same function twice when the first call is before any suspension, which is why the driver in `httpx/_proto/h1/aio.mojo` leaves early twice and the pool's copy of it cannot. What the pool does instead is have one exit: a failure does not leave, it makes every later step do nothing, and the single `_settle` at the bottom closes the connection because the exchange failed rather than because a branch said so.

Nothing may stand between a second suspending loop and a third. Three suspending loops in a row are fine, which is the paragraph above about guards, but only while the gap after the second one is empty. A single call that takes pointers already in the frame and returns nothing, placed there, takes the compiler down with a stack dump and no message. The gap between the first loop and the second may hold as much synchronous work as it likes, which is the part that makes this so easy to walk into: the shape has already been proved once by the time it stops working. A pooled request wants three loops, connect and write and read, with a turn around between the last two, and it cannot have them. It has two, and sending and receiving are one step that knows which of the two it is doing.

A value a coroutine throws away is still a value in its frame. `_ = _start_reading(conn, result)` after the second suspending loop crashes the compiler, and `_settle(conn, result)`, which returns nothing, in exactly the same place does not. The discard has to happen inside a helper's frame instead. This is the same rule as the discarded task handle at the end of the paragraph above, and it is worth its own line because `_ =` reads like nothing at all and is not.

Two `create_task` calls in a row have to be inside loop bodies. One of them written straight line in a coroutine is fine. Two, one after the other, crash the compiler with a stack dump and no message, and hoisting the arguments into locals first does not help. Putting each one inside a `for`, even a `for` of one iteration, does. `tests/unit/test_aio_pool.mojo` starts one request and its one server that way and says so at the call site. The same file's many request test writes real loops and never had the problem, which is what pointed at the loop rather than at anything in the arguments.

One more thing is a rule of the runtime rather than a bug. `TaskGroup.create_task` only accepts a coroutine that returns nothing, and a wait that cannot go into a task group is a wait that cannot run alongside another one. So every coroutine in `httpx/_io/` returns nothing and reports through a `result` pointer. That also puts each answer in memory the coroutine's own frame does not own, which is where a flat value is safest.

## The part the plan got wrong about colours

The plan also said that nothing above L2 would change, because every layer from L3 up is generic over the `ByteStream` trait, so an async stream would satisfy the trait and the same state machines would instantiate against it. That is not true and it is worth being precise about why, because it is the thing that decides how much code M6 touches.

Mojo's function colours are strict in both directions. An `async def` does not satisfy a trait method declared `def`, and a `def` does not satisfy one declared `async def`. Neither of these compiles:

```
struct Async(Reader):
    async def read(mut self) -> Int: ...

    note: no 'read' candidates have type 'def(mut self: Async) thin -> Int'
    note: candidate declared here with type 'async def(mut self: Async) thin -> Int'
```

So there is no single `ByteStream` trait that both a socket and an async socket satisfy, and no arrangement of generics that lets one driver drive both. Something has to be written twice.

## What gets written twice

Not the parsing. The framing rules, the header validation, HPACK, the URL and cookie code and the models are all sans-io already, they never touch a descriptor, and they stay in one copy. That was the reason for the layer split and it holds up here, which is the important part: the smuggling defences do not get a second implementation to keep in step.

The plan used to say that the driving loops get a second copy, generated from the sync one the way `tools/gen_*.py` generates the Huffman tables, with `pixi run generated-check` failing when the two drift. That is no longer the plan, and the reason is worth writing down because it was decided by building the thing rather than by arguing about it.

HTTP/1.1 turned out to have less driving loop than the plan assumed. `H1Connection` was split into `httpx/_proto/h1/machine.mojo`, which is the whole protocol and never touches a descriptor, and a driver that is nothing but "ask the machine, and if it says it is short of bytes, read some and ask again". Every rule that could rot out of step, the framing, the informational responses, the smuggling defences, the trailers, is on the machine side and has exactly one copy. What the async driver adds is a loop that waits differently, and it is about forty lines. A generator that produced forty lines, and that had to be maintained and understood and debugged, would cost more than the forty lines do.

The compiler limits settled it. An async driver cannot be the sync driver with `await` sprinkled on, because an awaited coroutine may suspend only once and not in a loop, so the whole exchange has to be a single coroutine with every wait written out inline. And the frame rules mean that coroutine cannot hold a buffer, a string or a caught error, so its buffers live on the connection and every step is a call to a synchronous helper. The two drivers no longer have the same shape at all. There is no token level transform between them, and a generator that produced the async one from the sync one would be a program that understood both sets of limits well enough to restructure the code, which is a compiler, not a script.

The staggered connect went the same way and is the clearest case, because there is no protocol in it to hide behind. `httpx/_io/connect.mojo` and `httpx/_io/aio_connect.mojo` share how an attempt is judged, how the failures are worded, and the bounded park in the middle. What is not shared is the loop around them, twenty lines each, because the async one keeps its attempt list in caller owned memory and hands the worker back between passes. Judging an attempt is the part where the two giving different answers would be a bug nobody would think to look for, and that part has one copy.

The connection pool is the third case and the one where the split is cleanest, because none of what a pool decides is a wait. Reuse by origin, expiry by age, liveness before handing a connection out, eviction under the total limit and whether a finished connection is fit to go back are all in `httpx/_pool/aio_pool.mojo` word for word as `httpx/_pool/pool.mojo` has them, and they are the same rules because they were copied deliberately rather than rewritten. What is different is the middle: `pooled_exchange` runs a connect and an exchange in one coroutine, because an awaited coroutine may suspend once and not in a loop, so a connect that loops and an exchange that loops cannot be two coroutines with one on top. Everything the pool does around that coroutine is ordinary synchronous code, which is why `open` and `finish` raise like the sync pool does and only the part in between reports failure as a value.

The transport is the fourth case, and it is the one where almost nothing is written twice. `httpx/_transport/aio_http.mojo` is a pool handle and four short methods, the same as `httpx/_transport/http.mojo`, because everything hard is below it. What is genuinely different is the trait it satisfies. `AsyncTransport` is a second trait rather than a method added to the first, because the async one has `handle_many` and the sync one never will: a transport with nothing to wait for has nothing to overlap.

The client is the fifth case, and it is not written twice at all. This is where the layering stops paying out in shared parsing and starts paying out in shared decisions. Merging headers, resolving a relative URL against the base, writing the `Cookie` header, running the event hooks, following a redirect chain and answering an auth challenge are the whole of what a client does, and not one of them is a wait. They all happen either side of the transport call rather than inside it, so they do not care which transport they got.

So `httpx/_client.mojo` holds a `BaseClient` parameterised on the transport handle, and `Client` and `AsyncClient` are two aliases for it. `httpx/_transport/handle.mojo` is the three calls a client makes on a transport, which is the part `Transport` and `AsyncTransport` have in common. There is no async redirect loop and no async cookie jar to keep in step with the synchronous ones, because there is one of each. `tests/unit/test_aio_client.mojo` runs the behaviours again anyway, over the async transport, because sharing the implementation is a claim about how the parameter was wired up rather than a proof.

So both drivers are written by hand, they share the machine, and what keeps them honest is that they are tested against the same behaviour rather than diffed against each other. Above the transport there is one implementation of everything, which is what the sans-io split was for.

## Why concurrency is a method on the transport

`gather` in httpx is something the caller does. You write the coroutines, hand them to `asyncio.gather`, and the client knows nothing about it. Here it cannot work that way, and the reason is the second compiler limit rather than a design preference.

One request is driven by a coroutine that suspends inside a loop, and such a coroutine can only be handed to `_run` or to `TaskGroup.create_task`. It cannot be awaited by another coroutine. So the group and the tasks have to be in the same function as the thing that knows how to run one request, and that function is inside the library. There is no way to hand a user a request in progress and let them combine it with someone else's, because a `Coroutine` is a linear type: it cannot be stored in a field, put in a list, or returned through a function pointer.

What that leaves is a batch. `AsyncTransport.handle_many` takes a list of requests, starts one task each under one group, and hands back the responses in the order the requests went in. Concurrency crosses the erasure boundary as a call taking a list, because it cannot cross it as a coroutine. It is a narrower thing than `gather` and it covers what `gather` is nearly always used for, which is sending several requests and waiting for all of them.

A batch fails the way `asyncio.gather` fails by default: the first failure is raised and the other responses are dropped. Every request still runs to the end first, so no connection is left leased, and a variant that hands back failures alongside successes is worth having and is not written yet.

What a user sees is `httpx.gather(client, requests)`, in `httpx/_aio_client.mojo`. A free function rather than a method, because that is what it is in httpx, and because it belongs to the async client alone while everything else on the client belongs to both. It is the transport's batch with the client's work wrapped round it, and the wrapping is the part worth reading: a request that comes back redirected is a request again, so a batch is not a list of requests and a list of responses. Each slot is a small state machine holding either something to send or an answer, along with its own history, its own auth scheme and its own hop count. A round is one call into the transport, and the slots that are not finished go out again in the next one, together. A batch where one request redirects twice and the rest are done in one hop costs three rounds rather than three sequential requests.

Redirects are resolved before the auth scheme is consulted, which is the order the synchronous client uses. Each slot carries its own copy of the scheme, so a digest challenge answered for one request does not become an answer the others give as well.

The alternative, making everything async and running the sync client as `_run` over it, was rejected on two counts: it puts a private stdlib entry point on the hot path of the sync client, and it makes every synchronous request pay a scheduler round trip for I/O that never suspends.

## Async streaming, and where the suspended coroutine went

A streamed response is handed back as soon as the head is in, holds a connection out of the pool while the caller reads the body a chunk at a time, and gives the connection back when the body ends or is closed. On the synchronous path the reading is a blocking read on a socket the response owns, and the obvious async version is a coroutine the response owns and the caller resumes. That version cannot be written. A `Coroutine` is a linear type: it cannot be stored in a field, put in a list or returned. There is nowhere to park one between two chunks.

What breaks the deadlock is noticing that nothing actually has to be parked. The state a body in progress consists of is the HTTP/1.1 machine, the read buffer and the socket, and all three of those live on the connection, which is an ordinary value. None of them was ever in a coroutine's frame, because the frame rules above meant they could not be. So `AsyncPooledSource` holds the connection and the exchange, and every call to `read_chunk` starts a fresh coroutine over them and runs it to the end with `_run`. The coroutine is created and consumed inside one function call and never has to survive one.

That puts the suspension inside a chunk rather than between two of them, which is the half that matters. A chunk that has not arrived gives the worker back and waits for the socket, so a caller sitting on a half read body is holding a connection and no worker at all. What it does not buy is reading several bodies at once: each `read_chunk` blocks the thread that called it, the same way `handle_request` does, and there is no `gather` for streams. Doing that would mean driving several sources under one task group, which means the pieces they are reading into have to be caller owned memory again, and it is a design rather than a missing argument.

The four iterators are `aiter_bytes`, `aiter_text`, `aiter_lines` and `aiter_raw`, and each one is the same call as the name without the `a`. That is the honest answer rather than a shortcut. What differs between a synchronous stream and an async one is the source underneath, and neither the response nor the iterator can tell which it has, because both are written against `ByteStream` and nothing else. The names exist so that code ported from httpx keeps its shape. `aread` and `aclose` are there for the same reason.

Reading the head and reading the body are the same coroutine with an integer changed. `pooled_exchange` takes a mode, `HEAD_ONLY` stops the moment the status line and headers are in and settles nothing, and `ONE_PIECE` hands back the first piece of body it gets. A copy of that function with the mode wired in would be a copy that had to be kept in step with the original by hand, and the connect and the write in it are the same connect and the same write.

## Cancellation, and what stops a request that is already going

asyncio's answer is `task.cancel()`, which throws a `CancelledError` into the coroutine at its next suspension point. There is no counterpart here and on this toolchain there cannot be one. A user never holds anything that stands for a request in flight: a `Coroutine` is linear, so it cannot be stored in a field or returned, a `Task` is not `Movable`, so it cannot be handed back out of the function that made it, and a `TaskGroup` has no `cancel` method at all, which was established by compiling a call to it rather than by assuming. So there is nothing to cancel, and if there were there would be nothing to deliver the cancellation with, because a coroutine here cannot raise.

What stands in for it is three things, and between them they cover what cancellation is usually reached for.

The deadline is the first and it does most of the work. Every wait in the library is a loop of bounded slices rather than one open ended syscall, and the slice is `MAX_SLICE_MS` in `httpx/_io/deadline.mojo`, fifty milliseconds. Nothing in here parks in the kernel with nothing to wake it, so every waiter comes back around its own loop twenty times a second to be re-checked, and a request stops within a slice of its budget running out whatever the server is doing at the time. That is the difference between a timeout that stops a request and a timeout the caller is told about once the server has finished. `tests/unit/test_aio_cancel.mojo` pins it as a timing rather than as an error kind for exactly that reason. The read budget is per read rather than per response, so a download that keeps arriving is never stopped for being large, and a server that goes quiet mid body still is.

The second is dropping the response. A streamed response is the only handle on a request that is still going, and closing it, or letting it go out of scope, stops the reading. The connection is closed rather than put back in the pool, because the rest of the body is still on the wire and a connection whose next byte is the middle of somebody else's response is not one to hand to the next request. Stopping a stream that has already stopped is harmless, which is what a `with` block does around a body the caller already closed. Reading one afterwards raises rather than handing back the empty list that is sitting there, because an empty body and a body nobody is going to read are different answers.

The third is what a stopped request does to its connection, and it is the same thing whatever stopped it. A read timeout, a protocol error and a caller closing halfway all give the connection up and give the lease back. Only a request that ran to the end pools its connection. The lease is the part worth testing, because a leaked one is invisible until the pool refuses to open anything and then presents as a hang somewhere else entirely.

A batch cannot be stopped partway. `handle_many` runs every request to the end even after one of them has failed, and the first failure is raised once the group is done. That is `TaskGroup` having no cancel, and it is also what we would choose if it had one: a task stopped between its write and its read leaves a connection whose position in the stream nobody knows, and a task that simply never returns leaves its lease behind forever. So the way to bound a batch is a timeout, which every member of it carries separately, and the cost of a batch is its slowest member.

Closing the client does not stop anything either. It closes the connections sitting idle in the pool and says nothing about the leased ones, which are precisely the ones a request is using. A streamed response holds its own connection and a handle on the pool, so it goes on working after the client that made it has been closed. That is deliberate, and it is what the shared pool handle in `httpx/_transport/aio_http.mojo` is for.

If a later Mojo grows a cancellation token, the place it goes is the poll loop in `httpx/_io/aio.mojo`. That loop already comes back around several times a second to look at a deadline, so checking one more thing there is a small change, and nothing above `httpx/_io/` would need to know.

## How https works here

There is one TLS implementation and the async path uses it. `TlsStream` in `httpx/_stream/tls.mojo` already keeps its socket non blocking and already talks to OpenSSL one step at a time, because OpenSSL asks for more data by returning `SSL_ERROR_WANT_READ` rather than by blocking. Its `try_handshake`, `try_read` and `try_write` are exactly the steps a coroutine needs, and its `read` and `write` are those same steps with a `poll` between them. So both clients run the same handshake, the same certificate checks and the same record layer, and the only thing that differs is who does the waiting.

That is why there are no memory BIOs. The socket BIO blocks when the descriptor does, and this descriptor never does.

Which way to wait has to be asked rather than assumed, and `AsyncStream.want` is what answers. A TLS read can want to write and a TLS write can want to read, because renegotiation and post handshake authentication send records in the direction opposite to the data. A driver that polls for readability because it happened to be reading works until the day a server asks for a new key.

The handshake runs inside the connect loop in `httpx/_pool/aio_pool.mojo` rather than in a loop of its own, because a coroutine here is allowed two suspending loops and not three. A connection with no descriptor yet is one the race has not won, and one that has a descriptor and has agreed nothing is one still shaking hands, so which half a pass of the loop is in comes off the connection rather than out of a phase kept beside it. The connect deadline covers both halves, which is what the synchronous path does too: a server that accepts a connection and then says nothing is a connect that never finished, whatever the kernel thinks of it.

## What the async client cannot do yet

Streaming request bodies and `Expect: 100-continue` are refused by the async driver, one layer down. Both need a second source driven between writes, which is another suspending loop.

HTTP/2 is out. It is negotiated by ALPN in the handshake, and the async pool asks for HTTP/1.1 only whatever the client was configured with, because offering a protocol it cannot speak would get a settings frame back where it expected a status line. [limitations.md](limitations.md) collects these together with everything else the library does not do yet, so a reader deciding whether this fits does not have to assemble the list from the design pages.

## What we are taking on knowingly

`_run` is underscore prefixed, which is the stdlib saying it is not public API. We depend on it anyway, because it is the only way into the scheduler from ordinary code and an `async def main` is not allowed. It is called in exactly one place inside `httpx/_io/`, so a rename costs one line.

The poll is a poll and not a wake-up. If a later Mojo gives us a way to complete a task from a callback, every waiter loses its polling and gains a wake-up, and nothing above `httpx/_io/` notices. That is why the loop was marked internal in the first place.

The compiler limits are load bearing. `Outcome` being flat, every waiting function being a leaf, and results coming back through pointers are all workarounds, and every one of them is written down beside the code it distorts. They are not a house style to be copied into the rest of the library, and when a toolchain fixes them the shapes here should go back to returning values and awaiting each other.

The pool is sized for compute. Anything that genuinely blocks inside a request still holds a worker and still caps out at four, so where that is unavoidable it is documented per call rather than hidden. The obvious one is a DNS lookup. `getaddrinfo` has no non blocking form on either platform this library supports, so `httpx/_io/aio_connect.mojo` splits resolution out of the race entirely: `start_race` resolves in synchronous code and `race_connect` only ever waits on sockets. That does not make the lookup cheaper, it makes the caller the one who decides where the cost lands, and a caller with a warm resolver cache pays nothing at all.

## If this changes

The probe is checked in so that the answers can be re-measured rather than remembered. If a future toolchain removes `asyncrt`, changes `parallelism_level`, or makes awaiting hold its worker, `pixi run probe-async` stops printing what this page says it prints, and this page is wrong rather than the code being quietly broken.

The eleven compiler limits are in the same file, at the bottom, as commented out cases with the message each one currently produces. Trying them again on a new toolchain is uncommenting them and building. When one of them starts working, the workaround it forced is the thing to delete, and this page says which one that is.
