# Testing

## Running the suite

```bash
pixi run test
pixi run format-check
```

Mojo 1.0 has no `mojo test` subcommand, only the assertions in `std.testing`, so the project owns its runner. `tools/mojotest/run.py` finds every top level `def test_*` under `tests/`, writes a Mojo main that calls each one, builds it and runs it. When Mojo ships a native runner we delete ours and the test functions stay exactly as they are, because they are plain `def test_*` functions using `std.testing` and nothing else.

The suite is built as several binaries rather than one, a few test modules to each. That is not a preference, it is the shape of the compiler: the time a Mojo build takes grows well above linearly in how much is in it, so doubling the modules in one binary costs a good deal more than double. The measurements the split was chosen from are at the top of `tools/mojotest/run.py`, and the short version is that the whole suite in one binary was around eleven minutes here and in thirteen shards it is around four.

Useful flags:

```bash
pixi run test --filter cookie      # only tests whose name or module matches
pixi run test --fail-fast          # stop at the first failing shard
pixi run test --repeat 20          # for shaking out flakes
pixi run test --shards 1           # one binary, the way it used to be
pixi run test --jobs 4             # build and run four shards at once
pixi run test --keep               # leave the generated mains to read
```

`--jobs` is one by default and worth leaving there most of the time. Plenty of tests here stand up sockets or fill every runtime worker on purpose, and they measure how long things took, so several shards sharing a machine make those measurements worse rather than the suite faster. `--shards 1` is the one to reach for when a failure looks like it might depend on what else was compiled alongside it.

## CI

CI runs on GitHub hosted runners and covers the three platforms Mojo supports: macOS arm64, Linux x86_64 and Linux arm64. It runs on every push and pull request, and there is a single `ci ok` check so branch protection does not need updating every time the matrix changes.

A separate nightly workflow builds against the Mojo nightly toolchain. It is allowed to fail and it opens an issue when it does. Mojo still changes between releases in ways that break real code, so that job is the early warning rather than a gate.

The rest of the matrix joins as the code that needs it lands: h1 and h2 from M5, debug and release builds from M2.

Anything that needs the network stays out of CI. That covers the badssl suite below, because a job that goes red when somebody else's certificate expires trains people to ignore red jobs.

## The golden suite

Every byte the command line client writes, pinned.

```bash
pixi run golden
python tools/golden/run.py --update
```

The unit tests drive the CLI through `run(argv)`, which covers the exit codes and the request it builds, and cannot see the two things this suite is for. What actually lands on stdout and on stderr, and whether that changes when the descriptor is a terminal. Both of those are properties of a process, so this one builds `build/httpx` and runs it against a server that answers with fixed bytes, once through pipes and once through a pty, and compares everything to a file under `tests/golden/`.

The server is a socket that writes canned responses rather than `http.server`, which would put its own `Date`, its own `Server` and its own reason phrases into every golden file. The pty has its newline translation turned off, so a file records what the program wrote and not what the kernel did on the way out. The one thing normalized before comparing is the port, since it is different every run.

The files are escaped rather than raw: a carriage return is `\r` and an escape is `\e`, so a stray one of either is something a reviewer can see in a diff instead of something they have to take on trust.

Two rules are checked rather than only recorded. Nothing but the body reaches stdout unless it was asked for, which is what makes `httpx URL | jq` work and is the rule CLI HTTP clients most often break. And a terminal differs from a pipe in decoration and never in content: the escape sequences are stripped from the terminal run and what is left has to be what went down the pipe. A JSON body is the one place the bytes themselves differ, because a terminal gets it laid out, so there the two are compared as parsed values, which is a stronger check than comparing whitespace. The binary guard is the one deliberate difference in content, and it is checked as an all or nothing: a pipe gets the whole body and a terminal gets none of it.

It runs in `pixi run check` and in CI on all three platforms, because it needs nothing but a loopback socket and the binary.

## The API reference

`docs/api.md` is generated from the source and committed, and a check fails when the two have come apart.

```bash
pixi run docs         # rewrite the page
pixi run docs-check   # fail when it is not what the code would produce now
```

`tools/docgen/run.py` runs `mojo doc` over the library, which gives it every declaration with its docstring and the signature the compiler saw, and renders the public ones into one page. What counts as public is read out of the import list in `httpx/__init__.mojo`, because that file is already where the library says what its surface is, and because a re-export leaves no trace in the doc JSON.

The order of the page is a table in the tool, grouped by what a reader is trying to do. A name that is exported and in no group stops the render rather than being appended somewhere, so adding an export makes somebody decide where it belongs. That is the part which keeps the page from turning into an alphabetical list of ninety names.

The page is committed so that reading the docs needs no toolchain, and `docs-check` runs in `pixi run check` and in the CI lint job. It is what catches a renamed argument that nobody re-rendered the page for.

What the generator cannot do is notice that a docstring was never written. A name with none still renders, as a signature with nothing under it, and the page still looks complete. So `pixi run lint` has a fourth check that reads the same import list and fails when an exported name has no docstring. It also fails on a re-export that no longer resolves, which otherwise compiles right up until somebody writes `httpx.TheName` in their own code.

## The documentation examples

Every ```mojo block in `docs/`, in the README and in CONTRIBUTING is a whole program, and all of them are compiled.

```bash
pixi run docex                       # all of them
pixi run docex docs/quickstart.md    # one page
pixi run docex --batch 1             # one build per example
```

A block with no `main` is a fragment, a signature or a trait declaration or a couple of lines showing a call, and is skipped. Those are deliberate: spelling out a whole program to show one line would bury the line. The count of skipped blocks is printed rather than passed over, so a block that meant to be a program and forgot is visible.

Compiling is the whole check. Running would need a network, a server and a tolerance for flakes, and the mistakes people actually make in a code sample are the ones a type checker already knows about.

Sixteen examples share a build. Nearly all of the time in one of these builds goes on the package rather than on the dozen lines of example in front of it, so paying for it once per sixteen instead of once each took the run here from 97 seconds to 13. Each `main` is renamed on the way in, and an example that declares anything else at the top level, a struct or a trait or a function of its own, is built on its own. That is what stops the second example in a file from quietly using a struct the first one declared, which is the failure this whole tool exists to catch. When a build fails its examples are compiled again one at a time, so what gets printed is still a line number in a document.

It is a CI job of its own rather than a step on lint, and not in `pixi run check`, because it is still minutes of compiling and it runs beside the test suite for free.

The value is not theoretical. It found two real defects the day it was written. `is_timeout` and the rest of the error predicates were not exported from `httpx/__init__.mojo`, so the whole error taxonomy was unaskable from outside the package, and `Deadlines` was not exported either, so `Transport` could not be implemented by anyone who did not already live in the package. Both are documented extension points. Neither was visible by reading the code, and both were obvious the moment an example was handed to the compiler.

## The badssl suite

Every way of getting TLS wrong, one host per way.

```bash
pixi run badssl
```

Seventeen cases against badssl.com. Five have to be accepted and the rest have to be refused, and the refusals assert on the wording as well as on the refusal. That second part is the point. A client that rejects everything for the same vague reason is barely better than one that accepts everything, because the person reading the message still does not know which of a dozen problems they have. So an expired certificate has to say expired, a certificate issued to somebody else has to say hostname mismatch, and a server that skipped its intermediates has to say issuer.

The accepted cases exist so the suite cannot pass on a client that refuses every certificate on earth, which is the failure mode a refusal only suite is blind to.

Two things to know before believing a failure. badssl.com's own certificates expire and several of its hosts are broken in ways its operators did not intend, so check the host in a browser before changing any code. And `revoked.badssl.com` is expected to be accepted, because revocation is not checked here or in most non browser clients. [The TLS page](tls.md) says why.

The offline half of the TLS testing is ordinary unit tests in `tests/unit/test_tls.mojo` and runs in `pixi run check` like everything else. It covers the ALPN wire encoding, the trust store search order and the key pair failure messages, against the throwaway certificates in `tests/fixtures/tls/`.

## The HTTP/2 interop suite

Fourteen cases against nginx, Caddy, Envoy and nghttpx, all four in Docker on the loopback address.

```bash
pixi run interop-h2                 # all four, then take them down
pixi run interop-h2 --keep          # leave them running to poke at
pixi run interop-h2 --only nginx    # one server, repeat the flag for more
```

The four are not four ways of asking the same question. nginx and Caddy are web servers that grew an HTTP/2 front end, Envoy is an HTTP/2 stack that grew a proxy, and nghttpx is the reference implementation's own server, written by the people who wrote the RFC. They disagree about window sizes, about how many frames a body arrives in, about whether a header block is Huffman coded, and about how strict to be with what we send. A client tested against one of them has been tested against one set of choices.

All four sit in front of the same HTTP/1.1 origin, `tools/interop/origin.py`, so all four have the same answers to give and a difference in a result is a difference in the HTTP/2 rather than in what each server thinks a directory listing looks like. It is also how almost every HTTP/2 deployment in the world is actually put together, which is what makes the translation each front end performs worth testing rather than an artefact of the setup.

The cases are mostly about the parts of HTTP/2 that have no HTTP/1.1 equivalent, since the rest is already covered by unit tests and by the parity suite. Flow control is the main one: a 200 KiB upload and a 1 MiB download both exceed the 65535 octet initial window and cannot complete unless both sides exchange `WINDOW_UPDATE` correctly, and nothing smaller than a real server on the other end will tell you whether that works. The last case asks a server that speaks HTTP/2 for HTTP/1.1 and checks it gets it, because a suite where every case is an HTTP/2 case passes on a client that has forgotten how to negotiate and simply assumes.

The suite has already earned its keep. It found that we sent no `content-length` on a request body we had in hand. That is legal in HTTP/2, where `END_STREAM` is what frames a body, and it is fine right up to the point where a front end has to proxy the request to an HTTP/1.1 origin, because with no length the only framing left for that hop is chunked. nginx buffers the body and adds a length of its own, so it passed. The other three streamed it through as chunked and the POST arrived empty. Three implementations disagreeing with us is not three bugs.

It needs Docker and it pulls four images, so it is not part of `pixi run check` and not in CI. It runs on the fleet. The certificates are generated on first use into `tools/interop/.h2certs/`, last thirty days, and are not checked in.

## The proxy interop suite

Forty seven cases against Squid, tinyproxy, mitmproxy and Dante, all four in Docker on the loopback address.

```bash
pixi run interop-proxy                 # all four, then take them down
pixi run interop-proxy --keep          # leave them running to poke at
pixi run interop-proxy --only squid    # one proxy, repeat the flag for more
```

The four are picked for how different they are. Squid is what a corporate network actually runs, thirty years old and tolerant of almost anything. tinyproxy is a few thousand lines that forward and tunnel and nothing else, so a request that is not quite right fails against it first. mitmproxy exists to break the tunnel open, which is what makes it the only one here that can prove the tunnelling cases check what they claim to. Dante speaks SOCKS5, which is not HTTP and shares no code with the other three on either side of the connection.

They all reach the same origin the HTTP/2 suite uses, `tools/interop/origin.py`, and the tunnelling cases go to `tlsorigin`, which is nginx holding the suite's own certificate in front of that same origin.

Two things about the addresses are load bearing. The proxies are reached on `127.0.0.1`, where their ports are published, and the targets are named `origin` and `tlsorigin`, which are Docker network names that do not resolve on the machine running the suite. A client that resolved the target itself instead of handing the name to the proxy would fail every case with a resolver error, which is the failure worth catching, and no case here can pass by accident on a direct connection.

Nine cases are the same for all three HTTP proxies: the absolute form request line, a `Host` naming the server rather than the proxy, a POST body, a megabyte, a streamed body, a 500, HEAD, several requests on one connection, and a relative redirect resolved and then proxied again. Squid and tinyproxy also get the tunnelling group, where the certificate that comes back through the CONNECT has to be the origin's own and not anything the proxy has, which is the whole claim a tunnel makes.

The rest are the cases where the proxies differ on purpose. Squid is configured to refuse a CONNECT to anything but port 443, so there is a real refused tunnel to check, and a refusal has to arrive as an error carrying the status because a tunnel that was never opened has no channel for a response to come back through. The second tinyproxy wants credentials, which gives the contrast that matters: a refused forwarded request is an ordinary 407 `Response` with the challenge on it, and the identical refusal on a CONNECT is an error. Dante has the same pair over SOCKS5, where the credentials go into the handshake as RFC 1929 length prefixed fields rather than into a header, and offering none to a proxy that wants them has to say so rather than reporting a closed connection.

The mitmproxy pair is the one to read if you read only one. The first case asks for a tunnel while trusting the suite's own CA and requires it to fail, because a proxy answering the handshake with its own certificate is a party in the middle. The second trusts mitmproxy's CA on purpose and requires the same request to succeed, which is what somebody debugging their own traffic does, and it is also what stops the first case from passing on a client that cannot handshake through a tunnel at all.

Squid, tinyproxy and Dante are built from `debian:bookworm-slim` rather than pulled, because every published image for them is somebody's own arrangement with its own entry point. Each product is one image and two containers, with the configuration file as the argument, so the plain listener and the one that wants credentials are the same build. It needs Docker, so like the HTTP/2 suite it is not part of `pixi run check` and not in CI, and it runs on the fleet. Certificates go into `tools/interop/.proxycerts/`, along with the CA mitmproxy generates for itself on first start, and none of it is checked in.

## The differential fuzzers

There are two, one per protocol, and they are built the same way: generate input, put it through this library and through the implementation httpx itself uses, and compare the two answers.

### The response parser against h11

The response parser is compared against h11, one case at a time, on generated and randomly damaged input.

```bash
pixi run -e fuzz fuzz                                # a short default run
pixi run -e fuzz fuzz --cases 40000 --seed 777       # a long one
pixi run -e fuzz fuzz --cases 3000 --show 6          # print the first six disagreements
```

h11 is the reference because it is the parser httpx itself uses, so a disagreement is a real difference in what the two clients would do with the same bytes rather than a difference of opinion between two libraries nobody runs. The driver generates status lines, header sets, bodies and terminators, mutates a share of them, and hands the whole batch to one Mojo process that reports what it made of each case.

The comparison is deliberately asymmetric. Being stricter than h11 is recorded and allowed, because most of the rules in the parser are stricter on purpose and a run typically ends up stricter on a few percent of cases. Being looser is a failure with no allowlist, since accepting a message h11 rejects is precisely the position where this client and the hop in front of it disagree about where a response ends. Producing a different status or a different body from the same bytes is a failure too.

It is not part of `pixi run check`. A fuzzer with a fixed seed and a fixed case count is a slow unit test, and one without them is not something a commit can wait for, so it runs nightly with a fresh seed and on the fleet.

### The HPACK decoder against hpack

```bash
pixi run -e fuzz fuzz-hpack                              # a short default run
pixi run -e fuzz fuzz-hpack --cases 40000 --seed 777     # a long one
pixi run -e fuzz fuzz-hpack --cases 3000 --show 6        # print the first six disagreements
```

hpack is the reference for the same reason h11 is: it is the HPACK half of the h2 project, which is what httpx speaks HTTP/2 through. The driver builds header blocks with hpack's own encoder, mixes in a catalogue of blocks written by hand to reach the branches an encoder never produces, adds some blocks of nothing in particular, damages a share of them, and hands the batch to one Mojo process.

A case is a run of one to three blocks against a single decoder, not one block. The dynamic table outlives the block that filled it, so a decoder can be right about every block taken on its own and still leave behind a table the encoder would not recognise, and every index in the next block is read against that table. Cases are independent of each other, blocks within a case are not.

The summary has four numbers rather than two. Read alike and refused alike are both agreement, but they say different things: a run that refused almost everything spent its time on blocks no decoder would read, so the first number is the one that says how much was actually compared. Stricter than hpack is allowed, the same as with h11.

The fourth number is a known difference and it has its own line so that it does not get mixed in with the bounds. This decoder produces `String`, so a name or a value that is not valid UTF-8 is refused, and hpack hands back the bytes. HTTP field values are octets and are not required to be text, and the HTTP/1.1 side of this library keeps them as octets and only converts when a caller asks, so the two halves of the same client do not currently agree about a latin-1 byte in a header value. Mutation produces those constantly, around three percent of cases in a long run, which is why they are counted apart.

## The parity suite

The same scenarios through this client and through httpx2, against one recording server, comparing the bytes that went out.

```bash
pixi run -e parity parity              # pass or fail
pixi run -e parity parity --show-all   # and every difference, accepted ones included
```

The point of the project is the same developer experience as httpx2, and the honest test of that is not that both libraries accept the same arguments. It is that the same arguments produce the same request. A client that takes `files=` and writes a different multipart body has matched the signature and nothing else, so the comparison is over the raw bytes the server received: the request line, every header with its value, the order they arrived in, and the body.

There are two halves. The request half covers the verbs, query strings, paths needing escapes, caller headers, cookies, all six body arguments, basic auth, digest auth with and without `qop`, four kinds of redirect, and a cookie set by one response and sent back on the next request. Where a case sends more than one request, each hop is compared separately, which is what makes the redirect and auth cases worth having. The response half feeds each client an answer written by hand and compares what it made of it: status, reason phrase, encoding, and the decoded text as hex, so a one byte difference in a body is visible rather than hidden inside a rendering.

Two things are normalized before comparing, and they are the only two. The product token in `User-Agent`, which is the library's own name and cannot match. And the random tokens: a multipart boundary, and the client nonce in a `qop` digest. The boundary's length is still compared through `Content-Length`, and the digest case without `qop` has no client nonce at all, so the credential it computes is compared byte for byte.

Everything else that differs has to be signed off. `ACCEPTED` in `tools/parity/run.py` holds one entry per difference we have decided to live with, each with the reason, and every entry has to match something on every run. An entry that stops matching fails the suite, because a stale allowance is how a suite like this quietly stops noticing regressions. There is one entry today: we order headers differently, which no part of HTTP gives meaning to.

Nothing tells the driver which cases the Mojo side ran. It does not need telling, because every request carries its case name in the path, so a case implemented on one side and forgotten on the other arrives as a case with records from only one client. That is a failure, and it is a stronger check than comparing two lists of names.

Like the fuzzer, it is not part of `pixi run check` and not in CI. It needs a second HTTP client installed and it opens real sockets.

## The benchmarks

Ten cases, each measured in its own process, each compared against a baseline recorded on the machine it ran on.

```bash
pixi run bench                 # every case, against this machine's baseline
pixi run bench --case parse    # only the cases whose name contains this
pixi run bench --update        # record what was measured as this machine's baseline
```

A metric more than five percent worse than the baseline fails the run. Five percent is tight enough to catch a real regression in a parser and loose enough to survive an ordinary machine, which is also why there is a baseline per machine rather than one number for everybody: a laptop and server3 disagree by more than any regression would.

It is not part of `pixi run check` and not in CI. A five percent gate needs a machine nobody else is sharing, and a hosted runner is the opposite of that, so this is the suite server3 has a role for. [Benchmarks](benchmarks.md) has the cases, the units, how a number is taken, and the list of things these numbers deliberately do not measure.

## The local fleet

Some testing does not belong in CI. Interop against real servers needs Docker and several minutes of wall clock, fuzzing needs hours, and benchmarks need a machine that nobody else is sharing. A hosted runner is bad at all three.

So those run locally, on real hardware, through `tools/fleet/run.sh`.

```bash
tools/fleet/run.sh                  # the test suite on every host
tools/fleet/run.sh --host server3   # one host
tools/fleet/run.sh --role fuzz      # every host with that role
tools/fleet/run.sh -- pixi run bench
tools/fleet/run.sh --role interop -- pixi run badssl
tools/fleet/run.sh --role interop -- pixi run interop-h2
tools/fleet/run.sh --role interop -- pixi run interop-proxy
```

The script copies the working tree over SSH, installs the pinned toolchain on the other end, and runs the task. It holds no credentials and needs no runner registered with GitHub. The only requirement is that `ssh <name>` already works.

One thing about it is worth knowing before you read a result. The remote script arrives on the far end's stdin, because the Windows host answers with cmd.exe and cannot be handed a quoted bash command any other way. A command that reads stdin therefore reads the rest of the script, and the lines after it are never run. The symptom is a run that stops partway through and reports nothing, no output, no error and no exit status, which is easy to mistake for the task itself dying. The body of the remote script is a brace group with its input taken from `/dev/null` so this cannot happen, and anything added there has to stay inside that group.

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

Two things about that guest cost an afternoon each, so they are written down here.

The first is that `/tmp` inside the guest is a tmpfs, and WSL stops the distro once the last process in it exits. Each remote command is its own SSH session, so a tree copied in by one session can be gone before the next session runs anything, and the failure looks like the tests dying with no output at all. The script stages under the guest's home directory, which is on the guest's own disk, for that reason.

The second is that the localhost relay between Windows and the guest answers on `127.0.0.1` for a port that was recently bound, so the usual way of getting an address that refuses a connection, bind a port and close it, hands back an address that connects instead. The relay only stands in the way of `127.0.0.1`, so `dead_address` in `tests/support/loopback.mojo` checks the address it is about to return and falls back to `127.0.0.2` with the same port number. Its docstring has the detail.

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

A test that only wants to stub out part of the world mounts the router instead of passing it as the transport. `mounts=` routes by URL pattern, so `routes.mount("all://payments.example.com", erase_transport(router^))` fakes one dependency and lets everything else go out for real. Mounting `blocked()` on `all://` under that is the way to make a test fail loudly when the code under test reaches somewhere nobody stubbed, rather than quietly opening a socket from a test run. [proxies.md](proxies.md) has the pattern language.

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

## The local server and the local proxies

Integration tests run against three Python processes, `tests/server/server.py`, `tests/server/proxy.py` and `tests/server/socks5.py`. All three are Python on purpose. The point of an integration test is that this client talks to somebody else's implementation, and a server built out of our own parser and our own writer would agree with our client about every mistake both of them made.

Each is started per test on a port the kernel picks, and prints `PORT <n>` on stdout once it is listening. Waiting for that line rather than sleeping is what keeps this from being the flaky part of the suite, and taking the port from it is what lets tests run in parallel and in any order. `tests/support/testserver.mojo`, `tests/support/testproxy.mojo` and `tests/support/testsocks.mojo` are the Mojo side.

The proxy is a real forward proxy and is strict about the part that matters. A request that arrives in origin form gets a 400 rather than a guess, so a passing proxy test is proof the absolute form went out rather than proof that something lenient let it through. It answers with three headers no real proxy sends, `X-Proxy-Target`, `X-Proxy-Auth` and `X-Proxy-Conn`, which is the whole channel back to the test: the URL that arrived in the request line, the credential that came with it, and an id for the client connection so the reuse test can see that two requests shared one. `--auth user:pass` makes it demand credentials and answer 407 without them, and `--forbid host:port` makes it answer 403 to a `CONNECT` for that destination.

It handles `CONNECT` as well, and that path is deliberately blind: it opens a socket to the named host and port, answers `200`, and copies bytes both ways until one side stops. None of the three headers goes on that reply, because a tunnel has none of its own once it is open. Their absence is what a tunnel test asserts on. Everything else it wants to know it asks the server on the far end, which is the only party in a position to answer honestly.

`tests/server/server.py --tls` serves the same routes over https, behind the self signed certificate in `tests/fixtures/tls`, and `TestServer(tls=True)` starts it. That is what a tunnel test tunnels to, and it is also the only real TLS handshake in the offline suite. No test turns verification off. `TestServer.tls_verify()` hands the client the certificate as its trust anchor, which works because a self signed certificate is its own issuer, and a test that used `verify=False` instead would pass just as happily against a client that never checked anything.

`tests/server/socks5.py` is the SOCKS5 proxy, and it is the one piece of the rig written from the RFC rather than borrowed, because Python has no SOCKS server anywhere in its standard library. Two of its switches carry the tests that matter. `--resolve NAME=ADDRESS` answers a name out of a table, so a test can ask for a name that resolves nowhere and take a response as proof that the name went over the wire rather than through the local resolver, which is the property the milestone asks for and the only one visible from outside. `--bound ipv4|ipv6|domain` chooses the form of the bound address on a successful reply, which is the only variable length field in the exchange and so the only place a client can miscount and leave bytes on the socket. There is one of those tests over https, where the leftover bytes would be the first thing the TLS handshake read.

All three have the same lifetime trap and it is worth knowing before it costs an afternoon. Mojo ends a value's life at its last use, so a test that reads the address and then makes the request has already torn the process down, and the failure is a connection refused on a port that existed a moment ago. Every test here passes the server and the proxy into a helper that makes the call, which is what keeps them borrowed until it returns.

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

Mojo has no coverage tooling. Two things substitute for it. The API census says the whole public surface is mentioned somewhere in the tests, and mutation testing says the mentions mean something. Together they are a stronger claim than a coverage percentage, because one guarantees the surface is covered and the other guarantees the assertions bite. The first of them exists and the second is not written yet.

```bash
pixi run census         # the public names no test mentions
pixi run census --all   # the whole surface rather than only the gaps
```

The public API is everything `httpx/__init__.mojo` re-exports, plus the fields, methods and constants of the types it re-exports. The census walks that surface, taken from the same code that renders the API reference, and fails when a name appears nowhere under `tests/`. It runs as part of `pixi run check`. A public name nobody mentions in a test is a name whose behaviour is whatever the implementation happens to do, and the semver promise this is here to defend is a promise about all of it rather than about the parts somebody remembered to check.

What it proves is a floor, and it is worth saying where the floor is. The match is textual, so a method called `close` gets credit from any type with a method of that name, and a name appearing in a test is not the same as that name being tested well. What it does catch is the case that actually happens, which is a method added to a public type and exercised only from inside the library, or a name exported and then forgotten. Neither of those is visible to the compiler or to a passing suite.

Members with no name at a call site are counted apart rather than probed with something weaker. `__eq__` is spelled `==`, `__len__` is `len(x)` and `write_to` is what `String(x)` calls, so a probe for those is a probe for punctuation that matches any file long enough. Counting them would raise the number the census reports without raising what it knows, which is the wrong direction for a gate. They are listed under `--all` so the surface can still be read whole.

`SKIPPED` in `tools/census/run.py` holds the names allowed to be missing, each with the reason, and an entry that stops being missing fails the run the same way a missing name does. That is the rule the parity suite uses for its accepted differences, for the same reason: an allowance nobody ever has to justify again is how a gate quietly stops gating.

Mutation testing is the other half and is not built. It would perturb operators, boundaries and constants and assert the suite notices. A mutant that survives marks behaviour that is executed but not actually tested, which is the thing line coverage cannot tell you, and it is what would turn the census from a claim about names into a claim about assertions.
