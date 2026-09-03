# Async

M6 was written as a maybe. The plan said Mojo has `async def` and `await` but no executor, no event loop and no async I/O, that `Coroutine` is a linear type with nowhere to store it, and that the milestone should open with a go or no go rather than with code. This is that decision and the evidence behind it.

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

So both drivers are written by hand, they share the machine, and what keeps them honest is that they are tested against the same behaviour rather than diffed against each other. `AsyncClient` will follow the same split when it lands: pooling, redirects, auth and cookies are decisions rather than waits, and they belong on the sans-io side of the line.

The alternative, making everything async and running the sync client as `_run` over it, was rejected on two counts: it puts a private stdlib entry point on the hot path of the sync client, and it makes every synchronous request pay a scheduler round trip for I/O that never suspends.

## What we are taking on knowingly

`_run` is underscore prefixed, which is the stdlib saying it is not public API. We depend on it anyway, because it is the only way into the scheduler from ordinary code and an `async def main` is not allowed. It is called in exactly one place inside `httpx/_io/`, so a rename costs one line.

The poll is a poll and not a wake-up. If a later Mojo gives us a way to complete a task from a callback, every waiter loses its polling and gains a wake-up, and nothing above `httpx/_io/` notices. That is why the loop was marked internal in the first place.

The compiler limits are load bearing. `Outcome` being flat, every waiting function being a leaf, and results coming back through pointers are all workarounds, and every one of them is written down beside the code it distorts. They are not a house style to be copied into the rest of the library, and when a toolchain fixes them the shapes here should go back to returning values and awaiting each other.

The pool is sized for compute. Anything that genuinely blocks inside a request still holds a worker and still caps out at four, so where that is unavoidable it is documented per call rather than hidden. The obvious one is a DNS lookup. `getaddrinfo` has no non blocking form on either platform this library supports, so `httpx/_io/aio_connect.mojo` splits resolution out of the race entirely: `start_race` resolves in synchronous code and `race_connect` only ever waits on sockets. That does not make the lookup cheaper, it makes the caller the one who decides where the cost lands, and a caller with a warm resolver cache pays nothing at all.

## If this changes

The probe is checked in so that the answers can be re-measured rather than remembered. If a future toolchain removes `asyncrt`, changes `parallelism_level`, or makes awaiting hold its worker, `pixi run probe-async` stops printing what this page says it prints, and this page is wrong rather than the code being quietly broken.

The eleven compiler limits are in the same file, at the bottom, as commented out cases with the message each one currently produces. Trying them again on a new toolchain is uncommenting them and building. When one of them starts working, the workaround it forced is the thing to delete, and this page says which one that is.
