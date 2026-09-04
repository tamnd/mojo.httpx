# Benchmarks

The numbers the library is held to, and the gate that fails a change which makes one of them worse. Ten cases, one command, and a baseline recorded per machine.

```bash
pixi run bench                      # every case, compared to this machine's baseline
pixi run bench --case parse         # only the cases whose name contains this
pixi run bench --rounds 5 --reps 5  # more samples, for a number you do not believe
pixi run bench --update             # record what was measured as this machine's baseline
pixi run bench --json               # print this machine's entry, for copying back
pixi run bench --tolerance 10       # a looser gate, for a machine you cannot quiet
```

A run takes about a minute. It builds `build/bench`, starts two test servers, one plain and one over TLS, and runs each case in its own process.

## What is measured

| Case | What it does | Metric |
| --- | --- | --- |
| `h1-keepalive` | 500 requests one after another down one pooled connection | `req_per_s` |
| `h1-concurrent-100` | 50 batches of 100 requests in flight together, through `AsyncClient` | `batch_p50_ms`, `batch_p99_ms`, `req_per_s` |
| `upload-10mb` | 10 MiB sent to a route that reads it and answers with nothing | `mib_per_s` |
| `download-10mb` | 10 MiB read into memory from a route that declares a length | `mib_per_s` |
| `h2-streams-1000` | 1000 streams on one HTTP/2 connection, one at a time | `streams_per_s` |
| `cold-start` | a process that makes one `http://` request, less a process that makes none | `wall_ms` |
| `cold-start-tls` | the same over `https://`, so a trust store, OpenSSL and a handshake are in it | `wall_ms` |
| `parse-headers` | an eleven field response head taken out of a buffer | `ns_per_head` |
| `parse-hpack` | an eight field request block through one decoder | `ns_per_block` |
| `parse-url` | a URL with userinfo, a port, two escapes, a query and a fragment | `ns_per_url` |

That is the list M9 names, in the same order, with the one addition of a second cold start. The plain one is the floor, where nothing optional is involved. The TLS one is what a first request usually costs, and the difference between the two is the part people wait for.

## The gate

A number more than five percent worse than the baseline fails the run, and the exit status says so. `--tolerance` moves the line.

Which way is worse depends on the unit, and the driver knows: `req/s`, `MiB/s` and `stream/s` want to go up, `ns` and `ms` want to go down. The change column is signed so that positive is always better, because a table where minus means faster in one row and slower in the next is one people misread. A unit the table does not know stops the run rather than being guessed at.

Two things are reported rather than failed. A metric with no baseline entry is new, which is what a case added today looks like. A machine with no baseline entry at all is a machine nobody has recorded, so nothing is gated and the run says how to record one.

## How a number is taken

Every case is run more than once and the best run is reported. Best rather than mean, because everything that makes a run slower than the machine is capable of is something else on the box, and averaging that in makes the number depend on what else was running. The gate compares against a number taken the same way on the same machine, so the measure that varies least is the one worth having.

There are two layers of repetition and they catch different things. `--reps` is how many times a case runs inside one process, which covers the case warming up: a connection opened, buffers touched, a pool filled. `--rounds` is how many processes the case gets, which covers the process warming up. Nine samples by default.

The percentiles are nearest rank on the sorted samples, so every number reported is one that actually happened. With fifty samples the ninety ninth percentile is the slowest of them. That is the tail measured coarsely rather than a smooth estimate of one, and it is worth knowing when reading the number.

Cold start is the only case timed from outside. A program cannot time its own startup, so the driver times a process that makes one request and subtracts a process that ran the same binary and did nothing. Everything the two share cancels, including the loader and the runtime coming up, and what is left is the client.

## What these numbers are not

Written down here because a benchmark suite that does not say what it excludes is a suite that gets quoted for things it never measured.

Loopback is not a network. There is no propagation delay, no loss and no congestion control worth the name, so the request and response cases are about how fast this library can produce and consume bytes and not about how fast a request completes to a server somewhere else. That is the right thing to gate on, because it is the part the library controls, but it is not a latency you can promise anyone.

The peer for the HTTP cases is Python's `http.server`. It is the test suite's server, chosen because an independent implementation disagrees with our mistakes, and it is not fast. For the two transfer cases especially, a share of what is measured is the server reading or writing ten mebibytes. The numbers are still comparable run to run, which is all the gate needs, and they are a floor rather than a ceiling on what the client can do.

The HTTP/2 peer is a script rather than a server. Its answers are encoded before the clock starts and it does no thinking, so that case measures our framing, our HPACK and the syscalls under them. Some peer side reading is inside the timed region and cannot be lifted out, because an exchange is two sides taking turns.

The thousand HTTP/2 streams are sequential. HTTP/2 here carries one request at a time per connection, which [limitations](limitations.md) says and the roadmap will fix, so a thousand streams is a thousand round trips rather than a thousand in flight. Calling it concurrent would be reporting a number nobody can get today. When multiplexing lands, that case is the one to rewrite.

The percentiles are over batches, not over requests. The sample is one batch of a hundred concurrent requests, and there is no per request percentile to report because the async pool reports a batch as a single outcome: nothing anywhere records the moment the seventeenth response of a hundred finished. A batch is still the sample that answers the question, since a caller who asks for a hundred at once waits for all hundred, and a pool that stalls one of them shows up in the tail.

The trust store in `cold-start-tls` is one certificate. The test server's own, because that is what the handshake has to check against. A real machine's bundle is a few hundred kilobytes of PEM, so read that number as a lower bound on the store and an honest measure of everything else.

## The baseline

`tools/bench/baseline.json`, keyed by machine. A number measured on one machine means nothing on another, so there is no single baseline and no attempt to make one. The file is committed, and a machine with no entry in it is not gated at all, which is what every machine is until somebody records one on it.

The key is the hostname, or `HTTPX_BENCH_MACHINE` when that is set. Set it on a laptop: hostnames there are personal and this file is public.

Recording one needs a machine that is actually idle, not merely yours. Check first, close what you can, then:

```bash
pixi run bench --update
```

Read the diff before committing it. A baseline recorded on a busy machine is low, and a low baseline is a gate that has stopped working: every later run clears it, including the ones that should not. The only place to catch that is in review, so a change to this file wants the load average that went with it.

For a fleet host the tree is a copy that gets thrown away, so `--update` there writes a file nobody sees. Print the entry instead and paste it in:

```bash
tools/fleet/run.sh --host server3 -- 'HTTPX_BENCH_MACHINE=server3 pixi run bench --json'
```

## Why this is not in CI

A hosted runner shares a machine with whoever else is on it, and a five percent gate on a shared machine is a coin toss. It would fail on changes that are fine and pass on changes that are not, and the second one is worse.

So benchmarks run locally, or on the fleet, where server3 carries the `bench` role. [Testing](testing.md) has the machines and how the fleet script works. The role says which host to use and not that the host is free at the moment, so read the load before you record anything from it. The same fleet machines run other people's work, and a run taken while they do is worth reading and not worth committing.
