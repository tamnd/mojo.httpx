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

Three things follow from those.

Tasks really do run at the same time. Four naps in the time of one is a thread pool doing its job, not an interleaving.

Awaiting hands the worker back. Four coroutines that each do nothing but wait for another coroutine finish in one nap rather than two, which means a waiter is parked rather than parked on top of a thread. Without that property a client built on tasks deadlocks the first time a request waits for a connection, so it is the single most important line in the probe.

Blocking work is capped at `parallelism_level()`. Eight naps take twice as long as four because a `sleep` holds its worker, and a blocking socket read is a `sleep` that happens to be waiting on a peer. The pool is sized to the performance cores, four here on a ten core machine, and no environment variable we tried changes it. It is a pool for compute, and compute is not what an HTTP client spends its time on.

## What is missing

There is no async I/O and no way to complete a task from outside. Nothing in `asyncrt` lets our own code resume a parked coroutine when a file descriptor becomes readable, which is exactly what a reactor needs. A `Task` is completed by its coroutine returning and by nothing else.

Two smaller gaps shape the API rather than the design. `Task` is not `Movable`, so there is no list of tasks to hold and no awaiting a set of them one at a time, which is why `gather` has to be built on `TaskGroup`. And `TaskGroup.create_task` only takes a coroutine returning nothing, so results have to be written somewhere both sides can reach rather than returned.

`Coroutine` is still linear, still not `Deinitable`, and still cannot be dropped or stored. That was the original worry and it turns out not to matter, because `create_task` is somewhere to put one and it is the only place we need.

## The decision

Go, and build the real loop rather than the thread pool fallback.

The fallback in the plan was `AsyncClient` over a pool of threads running the blocking client, with concurrency bounded by the pool. We can do better than that, and the reason is the last row of the table. A scheduler round trip costs under a microsecond, so a coroutine that has nothing to do can give way and be picked up again thousands of times in the time a network round trip takes. That turns the missing wake-up into a polling problem rather than a blocking problem, and a polling problem is one we can solve.

The shape is:

Sockets go non-blocking. A read that would block returns immediately instead of holding a worker.

A coroutine that cannot make progress looks at its descriptor with a zero timeout `poll`, and if there is nothing there it gives way and asks for a worker again. It never blocks while it has nothing to do, so the number of requests in flight stops being bounded by `parallelism_level()`.

Looking stops being free eventually, so the wait has two phases. For the first sixty four rounds, about a tenth of a millisecond, the poll timeout is zero and the worker goes straight back to the scheduler. After that the poll timeout is one millisecond, which is the kernel doing the waiting instead of us. A reply from a fast server arrives during the first phase. A wait on a slow one falls through to the second and stays there, costing a few thousand wakeups a second across the whole pool and no measurable CPU.

There is no shared reactor and no registration table, which is a change from the design sketched here before any of it was built. One shared kqueue would learn about every ready descriptor in a single syscall, but learning is not the slow part. A waiter still has to be handed a worker before it can act on the news, and being handed a worker is exactly what the per waiter poll is already waiting for. The table would buy nothing and would cost a lock, a wake up path, and an origin parameter threaded through every async type in the library.

What the missing wake up does cost is a rotation. Only `parallelism_level()` waiters sit inside a one millisecond poll at a time, so with more waiters than workers each one gets its turn periodically rather than continuously. The delay before a ready socket is noticed is the number of waiters divided by the number of workers, times one millisecond. Sixteen waiters on four workers is four milliseconds. That is the price of the missing wake up, and it is written down here so that nobody has to rediscover it in a profile.

Deadlines are the ones from the sync path. `Deadline` already exists, already knows how to be a timeout on a syscall, and every poll slice is clamped to what is left of one, so a hung peer is broken out of by the same rule in both clients.

The insertion point is smaller than it sounds. `TcpStream.read` and `TcpStream.write` are already non-blocking calls in a loop, and the only thing they do when the kernel says it would block is call `self._wait(POLLIN, deadline)`. An async stream is the same two loops with a different `_wait`.

## What the compiler allows

The design above is what the machine can do. What the toolchain will compile is narrower, and four of its limits shaped every line of `httpx/_io/aio.mojo` and `httpx/_io/aio_socket.mojo`. Each one has a reproducer at the bottom of `tools/probe/async.mojo`, so a later toolchain can be checked against them rather than guessed at. None of them is a style choice and all of them should be deleted the day they stop being true.

A coroutine cannot raise. `create_task`, `TaskGroup.create_task` and `_run` all refuse a `RaisingCoroutine`, and the one shape that would let a non raising wrapper catch on their behalf, an `await` of a raising coroutine inside a `try`, fails to lower. So every async function reports failure as a value, an `Outcome`, and the conversion back into an exception happens on the synchronous side of the boundary. Where that boundary falls is visible in the connect path. Starting an attempt and reading its verdict out of `SO_ERROR` both raise, and only the middle waits, so only the middle is a coroutine and the two ends stay ordinary functions.

Coroutines barely compose. A coroutine that is `await`ed may suspend exactly once, and not inside a loop. Suspending twice compiles and then hangs forever at run time, with nothing to attach a debugger to. Suspending inside a loop at least fails loudly, with `cannot guarantee tail call due to mismatched return types`. A coroutine handed to `_run` or to `TaskGroup.create_task` has no such limit and may suspend as often as it likes, which is why concurrency works at all. So every waiting function in `httpx/_io/` is a leaf: it carries its own poll loop rather than awaiting a shared one, and the repeated lines are the price of the loop existing.

Anything a coroutine writes from inside a suspending loop has to be flat. A value whose type has a field that is itself a struct, or that owns memory, fails to lower with `operand #0 does not dominate this use` pointing into the nested constructor. One write site survives it and two do not, which is what made this look like several unrelated bugs before it was reduced. That is why there is one result type, `Outcome`, rather than one per operation, and why it stores an unwrapped `UInt32` instead of an `ErrorKind` and a `UInt8` instead of an `Op`.

A `Span` cannot be resliced in a suspending loop. `data[sent:]` crashes the compiler with no message, only its own stack dump. `TcpStream.try_write` takes an offset rather than a caller sliced span because of it, and the synchronous writer passes an offset too rather than there being a second entry point only the async one uses.

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

What has a second copy is the driving loops. `H1Connection`'s I/O half, `H2Driver`, the pool and the client: the code that reads until a head is complete, writes a body while watching a window, and gives up on a deadline.

Two copies of that by hand is how one of them quietly grows a bug the other does not have. So one is generated from the other, the same way `tools/gen_*.py` already generates the Huffman tables and the public suffix list, and `pixi run generated-check` fails when the two drift.

The sync copy is the source and the async copy is generated, which is the opposite of what httpcore does under Python httpx. The reason to be different is not that the transform is easier this way, because it is not: dropping `async` and `await` is deleting tokens, and adding them means working out which calls became coroutines and threading that through the call graph. It is that the sync client is the one that ships today, the one the whole test suite exercises, and the one a contributor arriving with a bug report is looking at. Making it a generated artifact means a generator bug is a bug in the client everybody uses, and it means every fix to a driver has to be written async first by someone who may not care about async at all.

What makes the direction affordable here is that our two copies differ in one place. `TcpStream.read` and `TcpStream.write` already loop over a non-blocking call and already funnel every wait through `self._wait`, so the async driver is the sync driver with `_wait` replaced and the calls that reach it awaited. The generator computes that set rather than guessing, and stops with an error on any call it cannot classify, so an unhandled case is a failed build rather than an async path that silently blocks.

That plan survives the compiler limits above, but it stops being a token level transform. Because an awaited coroutine may suspend only once, the generated async driver cannot be the sync driver with `await` sprinkled on: a driver that reads a head, then reads a body, then writes, would suspend three times through its callers and hang. The async side is a small number of leaf coroutines, one per wait, each driven by `_run` or `TaskGroup.create_task` from synchronous code that owns the loop. So the generator's job is not to add keywords, it is to split each driving loop at the points where it waits and to hand each piece to the scheduler. That is more work than the sync-is-the-source direction assumed, and it is why `AsyncClient` is a later row of M6 rather than this one. The direction itself does not change, for the same reasons it was chosen.

The alternative, making everything async and running the sync client as `_run` over it, was rejected on two counts: it puts a private stdlib entry point on the hot path of the sync client, and it makes every synchronous request pay a scheduler round trip for I/O that never suspends.

## What we are taking on knowingly

`_run` is underscore prefixed, which is the stdlib saying it is not public API. We depend on it anyway, because it is the only way into the scheduler from ordinary code and an `async def main` is not allowed. It is called in exactly one place inside `httpx/_io/`, so a rename costs one line.

The poll is a poll and not a wake-up. If a later Mojo gives us a way to complete a task from a callback, every waiter loses its polling and gains a wake-up, and nothing above `httpx/_io/` notices. That is why the loop was marked internal in the first place.

The compiler limits are load bearing. `Outcome` being flat, every waiting function being a leaf, and results coming back through pointers are all workarounds, and every one of them is written down beside the code it distorts. They are not a house style to be copied into the rest of the library, and when a toolchain fixes them the shapes here should go back to returning values and awaiting each other.

The pool is sized for compute. Anything that genuinely blocks inside a request, a DNS lookup through the system resolver being the obvious one, still holds a worker and still caps out at four. Where that is unavoidable it is documented per call rather than hidden.

## If this changes

The probe is checked in so that the answers can be re-measured rather than remembered. If a future toolchain removes `asyncrt`, changes `parallelism_level`, or makes awaiting hold its worker, `pixi run probe-async` stops printing what this page says it prints, and this page is wrong rather than the code being quietly broken.

The four compiler limits are in the same file, at the bottom, as commented out cases with the message each one currently produces. Trying them again on a new toolchain is uncommenting them and building. When one of them starts working, the workaround it forced is the thing to delete, and this page says which one that is.
