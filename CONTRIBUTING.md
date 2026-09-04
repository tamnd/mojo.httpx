# Contributing

Thanks for taking a look. The project is early, so the highest value contributions right now are working on an open milestone issue, filing bugs against what already exists, and reporting anything that breaks on a Mojo version we do not test.

If you have not written Mojo before, [docs/mojo.md](docs/mojo.md) is the short version of what is different, and it explains most of what will look odd in this codebase.

## Getting set up

```bash
git clone https://github.com/tamnd/mojo.httpx
cd mojo.httpx
pixi install
pixi run check
```

`pixi.toml` pins the exact Mojo version. Do not build against a different toolchain and expect the results to mean anything, because the language still changes between releases in ways that move the ground under this project.

`pixi run check` is everything, in the order a failure is cheapest to read: formatting, the lints, the vendored data, the generated data, the API reference, the platform baselines, the test suite and the CLI golden files. It takes a few minutes. The individual pieces are all separate tasks if you want to run one of them on its own.

## The layout

`httpx/` is the library and `httpx/__init__.mojo` is the whole of its public surface. A name that is not in that file is not public, whatever it is spelled like.

Under it the modules are in layers, and a module may only import from a layer below its own. The table is in `tools/lint/run.py` and the lint enforces it. Roughly: errors and utilities at the bottom, then the FFI bindings, the I/O primitives, the models, the codecs, the content encoders, the streams, the protocol machines, the pool, the transports, the client, and the CLI on top.

The point of the split is that everything above the I/O layer is sans-io. The framing rules, the header validation, HPACK, the URL and cookie code and the models never touch a descriptor, which is why they can be tested exhaustively and why the async client did not need a second copy of any of them. [docs/architecture.md](docs/architecture.md) has the reasoning.

`tools/` is the build and check machinery, all of it Python. `tests/` is the suite. `docs/` is the prose.

## Rules that are easy to break

These come out of the design and most of them are enforced by a lint. They look arbitrary until you hit the failure they prevent.

1. **Parse over `Span[UInt8]`, never `String`.** `len()` on a `String` is a compile error in Mojo 1.0 because the byte and grapheme answers differ. Every parser in this codebase works on bytes and only produces a `String` at the boundary where a user sees it.
2. **No I/O call without a deadline.** Every `recv`, `send` and `connect` takes a `Deadline`. This is what makes the timeout guarantee mechanical instead of aspirational, and a lint rejects any call site that skips it.
3. **No `unsafe_` outside `_ffi/` and `_io/`.** Where it is used, the call site carries a comment stating the invariant that makes it safe.
4. **Respect the layer table.** If a change needs an import that goes the wrong way, the layering is wrong or the code is in the wrong module. Moving the entry in the lint table to make a build pass is not the fix.
5. **New public API needs a docstring with a runnable example.** The example is a whole program, so that `pixi run docex` can hand it to the compiler.
6. **Any behaviour that differs from httpx2 goes in [docs/deviations.md](docs/deviations.md).** If it is not in the table it is a bug, not a design decision.

## Tests

The suite is `tests/unit/`, driven by `python tools/mojotest/run.py`, which is what `pixi run test` calls. It generates a main per shard and runs the shards in parallel, so a single file is `pixi run test --filter test_headers`.

Four kinds of test live here and they are not interchangeable.

Behaviour tests are the bulk of it and they are ordinary assertions. Conformance tests run a vendored corpus, the WHATWG URL cases, the IDNA test suite, the cookie cases, and they are generated into Mojo by `tools/gen_*.py` from the vendored source. Add a case to the corpus rather than writing a one off test, so it stays covered as the code moves. Language tests, in `tests/unit/test_language.mojo`, pin compiler behaviour we have worked around, so a later Mojo that fixes one shows up as a failing test rather than as a workaround nobody removes. Platform tests check the constants we could get wrong per platform, and everything that cannot be asked from Mojo is in `tools/baseline/` instead.

Three suites are not part of `check` and are not in CI, because they need Docker or the network or a second HTTP client: `pixi run interop-h2`, `pixi run interop-proxy`, `pixi run badssl`, plus `pixi run -e parity parity` and the two fuzzers. [docs/testing.md](docs/testing.md) says what each one covers and where it runs.

## Documentation

Every ```mojo block in `docs/` and in this file is a whole program, and `pixi run docex` compiles all of them. A block with no `main` is treated as a fragment and skipped, which is the right thing for a signature or a trait declaration and the wrong thing for an example that meant to be complete.

That is not ceremony. It has already caught two real defects that reading would not have: the error predicates and `Deadlines` were both missing from `httpx/__init__.mojo`, which made error handling and custom transports impossible to write from outside the package, and both were found by handing an example to the compiler.

`docs/api.md` is generated by `pixi run docs` and committed. If you add or rename a public name, run it, and put the name in a group in `tools/docgen/run.py`, because a public name in no group stops the render.

## Pull requests

Keep the change focused on one thing. A pull request that fixes a bug and also reformats three files is much harder to review than two pull requests.

Include a test that fails before your change and passes after.

Run `pixi run check` locally first. CI runs a large matrix and it is slow, so catching the obvious failures before pushing saves everyone time.

Commit messages should say what changed and why. The why is the part that is hard to recover six months later.

## Design changes

If you want to change something structural, open an issue first with the `design` label and describe the problem before the solution. The architecture is written down in [docs/architecture.md](docs/architecture.md), and there are usually reasons behind decisions that look odd, so a short conversation up front is cheaper than a rejected pull request.

## Reporting bugs

Include the Mojo version, the operating system and architecture, a minimal reproduction, and what you expected instead. For a protocol bug, the raw bytes on the wire are the most useful thing you can attach.

For anything with a security impact, do not open a public issue. Read [SECURITY.md](SECURITY.md).

## Code of conduct

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
