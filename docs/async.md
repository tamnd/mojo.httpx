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

Nothing above L2 changes. Every layer from L3 up is generic over the `ByteStream` trait, so `AsyncTcpStream` satisfies the trait and the same state machines instantiate against it. That was the reason for writing them that way and this is where it pays.

## What we are taking on knowingly

`_run` is underscore prefixed, which is the stdlib saying it is not public API. We depend on it anyway, because it is the only way into the scheduler from ordinary code and an `async def main` is not allowed. It is called in exactly one place inside `httpx/_io/`, so a rename costs one line.

The poll is a poll and not a wake-up. If a later Mojo gives us a way to complete a task from a callback, the reactor loses its polling and gains a wake-up, and nothing above `httpx/_io/` notices. That is why the loop was marked internal in the first place.

The pool is sized for compute. Anything that genuinely blocks inside a request, a DNS lookup through the system resolver being the obvious one, still holds a worker and still caps out at four. Where that is unavoidable it is documented per call rather than hidden.

## If this changes

The probe is checked in so that the answers can be re-measured rather than remembered. If a future toolchain removes `asyncrt`, changes `parallelism_level`, or makes awaiting hold its worker, `pixi run probe-async` stops printing what this page says it prints, and this page is wrong rather than the code being quietly broken.
