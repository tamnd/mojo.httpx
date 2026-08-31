# Contributing

Thanks for taking a look. The project is early, so the highest value contributions right now are working on an open milestone issue, filing bugs against what already exists, and reporting anything that breaks on a Mojo version we do not test.

## Getting set up

```bash
git clone https://github.com/tamnd/mojo.httpx
cd mojo.httpx
pixi install
pixi run test
pixi run lint
```

`pixi.toml` pins the exact Mojo version. Do not build against a different toolchain and expect the results to mean anything, because the language still changes between releases in ways that move the ground under this project.

## Rules that are easy to break

These come out of the design and are enforced in CI. They look arbitrary until you hit the failure they prevent.

1. **Parse over `Span[UInt8]`, never `String`.** `len()` on a `String` is a compile error in Mojo 1.0 because the byte and grapheme answers differ. Every parser in this codebase works on bytes and only produces a `String` at the boundary where a user sees it.
2. **No I/O call without a deadline.** Every `recv`, `send` and `connect` takes a `Deadline`. This is what makes the timeout guarantee mechanical instead of aspirational, and a lint rejects any call site that skips it.
3. **No `unsafe_` outside `_ffi/` and `_io/`.** Where it is used, the call site carries a comment stating the invariant that makes it safe.
4. **New public API needs a docstring with a runnable example and a parity test.** The docstring lint fails the build without one.
5. **Any behaviour that differs from httpx2 goes in the deviation table.** If it is not in the table it is a bug, not a design decision.

## Pull requests

Keep the change focused on one thing. A pull request that fixes a bug and also reformats three files is much harder to review than two pull requests.

Include a test that fails before your change and passes after. For a parser or protocol change, add the case to the relevant conformance corpus rather than writing a one off test, so it stays covered as the code moves.

Run `pixi run lint` and `pixi run test` locally first. CI runs a large matrix and it is slow, so catching the obvious failures before pushing saves everyone time.

Commit messages should say what changed and why. The why is the part that is hard to recover six months later.

## Design changes

If you want to change something structural, open an issue first with the `design` label and describe the problem before the solution. The architecture is written down in `docs/architecture.md` and in the full spec, and there are usually reasons behind decisions that look odd, so a short conversation up front is cheaper than a rejected pull request.

## Reporting bugs

Include the Mojo version, the operating system and architecture, a minimal reproduction, and what you expected instead. For a protocol bug, the raw bytes on the wire are the most useful thing you can attach.

For anything with a security impact, do not open a public issue. Read [SECURITY.md](SECURITY.md).

## Code of conduct

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
