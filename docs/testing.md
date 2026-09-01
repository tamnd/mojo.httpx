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
