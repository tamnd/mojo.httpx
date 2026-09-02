# Testing

## Running the suite

```bash
pixi run test
pixi run format-check
```

Mojo 1.0 has no `mojo test` subcommand, only the assertions in `std.testing`, so the project owns its runner. Right now that is `tests/run.mojo` calling each test directly. M0 replaces the hand written list with discovery. When Mojo ships a native runner we delete ours and the test functions stay exactly as they are, because they are plain `def test_*` functions using `std.testing` and nothing else.

## CI

CI runs on GitHub hosted runners and covers the three platforms Mojo supports: macOS arm64, Linux x86_64 and Linux arm64. It runs on every push and pull request, and there is a single `ci ok` check so branch protection does not need updating every time the matrix changes.

A separate nightly workflow builds against the Mojo nightly toolchain. It is allowed to fail and it opens an issue when it does. Mojo still changes between releases in ways that break real code, so that job is the early warning rather than a gate.

The rest of the matrix joins as the code that needs it lands: h1 and h2 from M5, debug and release builds from M2.

Anything that needs the network stays out of CI. That covers the badssl suite below, because a job that goes red when somebody else's certificate expires trains people to ignore red jobs.

## The badssl suite

Every way of getting TLS wrong, one host per way.

```bash
pixi run badssl
```

Seventeen cases against badssl.com. Five have to be accepted and the rest have to be refused, and the refusals assert on the wording as well as on the refusal. That second part is the point. A client that rejects everything for the same vague reason is barely better than one that accepts everything, because the person reading the message still does not know which of a dozen problems they have. So an expired certificate has to say expired, a certificate issued to somebody else has to say hostname mismatch, and a server that skipped its intermediates has to say issuer.

The accepted cases exist so the suite cannot pass on a client that refuses every certificate on earth, which is the failure mode a refusal only suite is blind to.

Two things to know before believing a failure. badssl.com's own certificates expire and several of its hosts are broken in ways its operators did not intend, so check the host in a browser before changing any code. And `revoked.badssl.com` is expected to be accepted, because revocation is not checked here or in most non browser clients. [The TLS page](tls.md) says why.

The offline half of the TLS testing is ordinary unit tests in `tests/unit/test_tls.mojo` and runs in `pixi run check` like everything else. It covers the ALPN wire encoding, the trust store search order and the key pair failure messages, against the throwaway certificates in `tests/fixtures/tls/`.

## The differential fuzzer

The response parser is compared against h11, one case at a time, on generated and randomly damaged input.

```bash
pixi run -e fuzz fuzz                                # a short default run
pixi run -e fuzz fuzz --cases 40000 --seed 777       # a long one
pixi run -e fuzz fuzz --cases 3000 --show 6          # print the first six disagreements
```

h11 is the reference because it is the parser httpx itself uses, so a disagreement is a real difference in what the two clients would do with the same bytes rather than a difference of opinion between two libraries nobody runs. The driver generates status lines, header sets, bodies and terminators, mutates a share of them, and hands the whole batch to one Mojo process that reports what it made of each case.

The comparison is deliberately asymmetric. Being stricter than h11 is recorded and allowed, because most of the rules in the parser are stricter on purpose and a run typically ends up stricter on a few percent of cases. Being looser is a failure with no allowlist, since accepting a message h11 rejects is precisely the position where this client and the hop in front of it disagree about where a response ends. Producing a different status or a different body from the same bytes is a failure too.

It is not part of `pixi run check`. A fuzzer with a fixed seed and a fixed case count is a slow unit test, and one without them is not something a commit can wait for, so it runs nightly with a fresh seed and on the fleet.

## The parity suite

The same scenarios through this client and through httpx2, against one recording server, comparing the bytes that went out.

```bash
pixi run -e parity parity              # pass or fail
pixi run -e parity parity --show-all   # and every difference, accepted ones included
```

The point of the project is the same developer experience as httpx2, and the honest test of that is not that both libraries accept the same arguments. It is that the same arguments produce the same request. A client that takes `files=` and writes a different multipart body has matched the signature and nothing else, so the comparison is over the raw bytes the server received: the request line, every header with its value, the order they arrived in, and the body.

There are two halves. The request half covers the verbs, query strings, paths needing escapes, caller headers, cookies, all six body arguments, basic auth, digest auth with and without `qop`, four kinds of redirect, and a cookie set by one response and sent back on the next request. Where a case sends more than one request, each hop is compared separately, which is what makes the redirect and auth cases worth having. The response half feeds each client an answer written by hand and compares what it made of it: status, reason phrase, encoding, and the decoded text as hex, so a one byte difference in a body is visible rather than hidden inside a rendering.

Two things are normalized before comparing, and they are the only two. The product token in `User-Agent`, which is the library's own name and cannot match. And the random tokens: a multipart boundary, and the client nonce in a `qop` digest. The boundary's length is still compared through `Content-Length`, and the digest case without `qop` has no client nonce at all, so the credential it computes is compared byte for byte.

Everything else that differs has to be signed off. `ACCEPTED` in `tools/parity/run.py` holds one entry per difference we have decided to live with, each with the reason, and every entry has to match something on every run. An entry that stops matching fails the suite, because a stale allowance is how a suite like this quietly stops noticing regressions. There are two entries today: we send `Accept-Encoding: identity` because there are no decoders yet, and we order headers differently, which no part of HTTP gives meaning to.

Nothing tells the driver which cases the Mojo side ran. It does not need telling, because every request carries its case name in the path, so a case implemented on one side and forgotten on the other arrives as a case with records from only one client. That is a failure, and it is a stronger check than comparing two lists of names.

Like the fuzzer, it is not part of `pixi run check` and not in CI. It needs a second HTTP client installed and it opens real sockets.

## The local fleet

Some testing does not belong in CI. Interop against real servers needs Docker and several minutes of wall clock, fuzzing needs hours, and benchmarks need a machine that nobody else is sharing. A hosted runner is bad at all three.

So those run locally, on real hardware, through `tools/fleet/run.sh`.

```bash
tools/fleet/run.sh                  # the test suite on every host
tools/fleet/run.sh --host server3   # one host
tools/fleet/run.sh --role fuzz      # every host with that role
tools/fleet/run.sh -- pixi run bench
tools/fleet/run.sh --role interop -- pixi run badssl
```

The script copies the working tree over SSH, installs the pinned toolchain on the other end, and runs the task. It holds no credentials and needs no runner registered with GitHub. The only requirement is that `ssh <name>` already works.

### The machines

| Host | Platform | Roles |
| --- | --- | --- |
| server1 | Ubuntu 24.04, x86_64, 4 cores | interop, fuzz |
| server2 | Ubuntu 24.04, x86_64, 6 cores | interop, fuzz |
| server3 | Ubuntu 24.04, x86_64, 8 cores | interop, fuzz, bench |
| gamingpc | Windows 11 with WSL2 Ubuntu, x86_64 | smoke |
| local | macOS arm64 | everything, via `pixi run test` |

They are listed in `tools/fleet/hosts.toml`. Add a machine by adding an entry with its SSH alias and a role.

### Windows

Mojo has no native Windows build. The conda package only publishes osx-arm64, linux-64 and linux-aarch64, so there is nothing to install on Windows directly. What does work is WSL2, and the fleet script runs everything on gamingpc inside the WSL2 Ubuntu guest for exactly that reason.

That is the honest support statement for Windows: it works under WSL2, it is tested under WSL2 on real hardware before every release, and native Windows is blocked on Modular rather than on us.

### Why not self-hosted runners

Registering these machines as GitHub self-hosted runners was the first thing considered and rejected. A self-hosted runner on a public repository will execute code from any pull request, which means handing an arbitrary contributor a shell on a machine on a home network. The isolation needed to make that safe is more work than the problem is worth here. Running the same suites locally from a script gets the same coverage with none of that exposure.

## Mocking, for tests of your own code

Everything above is about testing this library. Testing an application that uses it is a different problem, and the answer is to swap the transport rather than to stub out the client.

`MockRouter` is a table of routes matched in order. `MockTransport` is a single handler function that answers everything. Either one goes under a real `Client`, so redirects are still followed, cookies are still stored and sent back, auth still answers a challenge, and the headers on the wire are the ones your program would really send. What the test loses is the socket and nothing else.

```mojo
var router = MockRouter()
router.add(Route.get("/users/1").respond_json(200, '{"name": "alice"}'))
router.add(Route.any().respond(404))

var transport = erase_transport(router^)
var handle = transport.copy()
var client = Client(transport^)
```

`handle.state[MockRouter]()` reads the router back after the client has taken it, because a copy of an erased transport is the same transport. `router.calls` is every request that arrived, `route.calls` is what each route answered, and `assert_all_called()` fails a test whose route pattern was wrong and never matched. The README has a fuller example.

## Vendored corpora

The conformance tests run against files somebody else maintains: the public suffix list and its cases, the WHATWG URL cases, the Unicode and IDNA tables, the http-state cookie tests and the http2jp HPACK stories. Those files live in `tests/data` and are committed, so a test run never reaches the network and a checkout from six months ago asserts exactly what it asserted then.

```bash
pixi run vendor-check                                     # every file matches the lock
pixi run python tools/vendor/fetch.py --update            # refresh all of them
pixi run python tools/vendor/fetch.py --update whatwg-url # refresh one
```

`tools/vendor/sources.toml` says where each corpus came from, what licence it carries and what it is for. Fetching rewrites `tests/data/LOCK.toml` with a digest and a size per file. Review that diff the way you would review a dependency bump, because the assertions the suite makes are about to change based on a file somebody else controls.

`vendor-check` also fails on any file under `tests/data` that no source declares. That is the rule that catches the mistake people actually make, which is copying a corpus in by hand with no record of where it came from.

A source that names a `files` list is one corpus made of many files, each pinned separately. The HPACK stories are the only one of those so far: forty files from four encoders, which would otherwise be forty copies of one licence and one paragraph.

### The HPACK stories

HPACK gives an encoder real freedom. The same header list can go out as a static index, a dynamic index, a literal with indexing, a literal without it, Huffman coded or not, with the table resized in the middle, and all of those are correct. A decoder tested only against our own encoder is tested against our own choices, so `tests/unit/test_h2_hpack_corpus.mojo` runs 340 cases from four encoders that made different ones: nghttp2, nghttp2 with table size changes, a naive Haskell encoder that indexes nothing and Huffman codes nothing, and one that Huffman codes everything including names.

The stories are stateful and that is the point. One decoder runs a whole story, so case seven decodes correctly only if cases zero to six each put the right thing in the dynamic table. A failure is reported once per story and the rest of it is skipped, because every later case in a story is being decoded against a table that is already wrong.

## The h2 suite cases

`tests/unit/test_h2_conformance.mojo` is the python-hyper h2 test suite's cases put to this client. h2 is the HTTP/2 implementation everything in Python sits on, including httpx, so its suite is the closest thing there is to a shared reading of RFC 9113.

It is Python test code rather than a corpus, so unlike everything in `tests/data` there is nothing to vendor and nothing to pin. The cases are rewritten, and each one names the rule it is about rather than pointing at a file, because a case that only says which upstream test it came from is a case nobody can maintain.

Not all of them apply. Most of that suite is about the server half of the protocol, about h2's own event objects, and about the priority scheme RFC 9113 withdrew. What is left is the part a client can get wrong on its own: what makes a received message malformed under RFC 9113 section 8.2, what a client does with an informational response, and whether a bad message costs one stream or the whole connection. Roughly half the file is acceptances rather than refusals, which is what stops the suite passing on a client that refuses every response there is.

## Test layers

The full plan, from `docs/roadmap.md`:

| Layer | Scope |
| --- | --- |
| Unit | Parsers, encoders, matching rules |
| Integration | The full stack against a local test server |
| Conformance | External corpora for URL, IDNA, cookies, HPACK and JSON |
| Property | Generated inputs against stated invariants |
| Fuzz | Differential and crash finding against the attacker facing parsers |
| Interop | Real servers and proxies, on the fleet |
| Parity | The same scenario through httpx2 and through us, compared on the wire |
| Security | One explicit test per known attack class |

The security layer is one file per attack class, named after the class, so somebody worried about a particular attack can find it by name rather than by reading the parser. `tests/security/test_smuggling.mojo` is the first of them and covers request smuggling: each published way of making two HTTP implementations disagree about where a message ends, put on a real socket, with the client required to refuse it. The cases at the end of that file are ordinary responses that have to be accepted, because a suite made only of refusals would pass on a parser that refused everything.

The parity layer is the direct defence of the project's goal. Each scenario runs twice against the same server, once through this library and once through httpx2, and the raw bytes on the wire are compared. That catches header ordering, casing and framing differences that a status and body comparison would miss.

## Coverage

Mojo has no coverage tooling. Two things substitute for it.

Mutation testing perturbs operators, boundaries and constants and asserts the suite notices. A mutant that survives marks behaviour that is executed but not actually tested, which is the thing line coverage cannot tell you.

The public API census diffs the symbol list from `mojo doc` against the symbols the tests touch. A public symbol with no test fails the build.

Together those are a stronger claim than a coverage percentage, because one guarantees the surface is covered and the other guarantees the assertions mean something.
