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

The rest of the matrix joins as the code that needs it lands: OpenSSL 3.0 and 3.6 from M3, h1 and h2 from M5, debug and release builds from M2.

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

The parity layer is the direct defence of the project's goal. Each scenario runs twice against the same server, once through this library and once through httpx2, and the raw bytes on the wire are compared. That catches header ordering, casing and framing differences that a status and body comparison would miss.

## Coverage

Mojo has no coverage tooling. Two things substitute for it.

Mutation testing perturbs operators, boundaries and constants and asserts the suite notices. A mutant that survives marks behaviour that is executed but not actually tested, which is the thing line coverage cannot tell you.

The public API census diffs the symbol list from `mojo doc` against the symbols the tests touch. A public symbol with no test fails the build.

Together those are a stronger claim than a coverage percentage, because one guarantees the surface is covered and the other guarantees the assertions mean something.
