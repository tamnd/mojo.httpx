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

A coroutine that cannot make progress registers its interest with the reactor and yields. It does not block, so it does not hold a worker, and the number of requests in flight stops being bounded by `parallelism_level()`.

The reactor owns one kqueue or epoll descriptor and answers the question every waiter asks: is this one ready yet. When at least one waiter is runnable the reactor is polled with a zero timeout, which is a cheap syscall and no waiting at all.

When nothing anywhere is ready, exactly one coroutine performs the blocking wait on everybody's behalf, with a timeout taken from the nearest deadline. An idle client then costs one parked thread and no CPU, which is the thing a naive spin loop gets wrong. Waiters are woken by that coroutine returning, which the scheduler already handles because it is an ordinary task completing.

Deadlines are the ones from the sync path. `Deadline` already exists, already knows how to be a timeout on a syscall, and the reactor's blocking wait takes its timeout from the nearest one, so a hung peer is broken out of by the same rule in both clients.

The insertion point is smaller than it sounds. `TcpStream.read` and `TcpStream.write` are already non-blocking calls in a loop, and the only thing they do when the kernel says it would block is call `self._wait(POLLIN, deadline)`. An async stream is the same two loops with a different `_wait`.

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

Two copies of that by hand is how one of them quietly grows a bug the other does not have. So the sync copy is generated from the async one, the same way `tools/gen_*.py` already generates the Huffman tables and the public suffix list, and `pixi run generated-check` fails when the two drift. Async is the source, because dropping `async` and `await` from a coroutine is mechanical and adding them is not. This is the trick httpcore uses under Python httpx for the same reason, so it is not an experiment.

The alternative, making everything async and running the sync client as `_run` over it, was rejected on two counts: it puts a private stdlib entry point on the hot path of the sync client, and it makes every synchronous request pay a scheduler round trip for I/O that never suspends.

## What we are taking on knowingly

`_run` is underscore prefixed, which is the stdlib saying it is not public API. We depend on it anyway, because it is the only way into the scheduler from ordinary code and an `async def main` is not allowed. It is called in exactly one place inside `httpx/_io/`, so a rename costs one line.

The poll is a poll and not a wake-up. If a later Mojo gives us a way to complete a task from a callback, the reactor loses its polling and gains a wake-up, and nothing above `httpx/_io/` notices. That is why the loop was marked internal in the first place.

The pool is sized for compute. Anything that genuinely blocks inside a request, a DNS lookup through the system resolver being the obvious one, still holds a worker and still caps out at four. Where that is unavoidable it is documented per call rather than hidden.

## If this changes

The probe is checked in so that the answers can be re-measured rather than remembered. If a future toolchain removes `asyncrt`, changes `parallelism_level`, or makes awaiting hold its worker, `pixi run probe-async` stops printing what this page says it prints, and this page is wrong rather than the code being quietly broken.
