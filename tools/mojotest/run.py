#!/usr/bin/env python3
"""The test runner.

Mojo 1.0 has no `mojo test` subcommand, only the assertions in `std.testing`,
so the project owns its runner. This script finds every `def test_*` under
tests/, generates a Mojo main that calls each one, compiles it and runs it.

The test files themselves are plain Mojo with no runner specific machinery in
them. When Mojo ships a native test runner this script is deleted and the tests
stay exactly as they are.

    pixi run test
    python tools/mojotest/run.py --filter cookie
    python tools/mojotest/run.py --fail-fast
    python tools/mojotest/run.py --repeat 20 --filter parser
    python tools/mojotest/run.py --shards 1        one binary, the old way
    python tools/mojotest/run.py --jobs 4          shards at the same time

## Why the suite is built in pieces

It used to be one generated main over every test module, and the time that took
grew far faster than the suite did. Measured on this project at one point, on
one machine, in modules of tests compiled together:

    4 modules      8s
    8 modules     33s
    20 modules    50s
    40 modules   126s
    77 modules   660s

Doubling the input from 40 to 77 cost five times the time, so the cost is
somewhere above quadratic in the number of modules in one binary. It is also
roughly fixed per binary at the bottom of that table, a few seconds of starting
up and compiling the parts of the library every test module pulls in, which is
what stops the answer from being one binary per module.

So the suite is split into shards of a handful of modules each and every shard
is its own binary. Same tests, same order within a shard, and the wall clock
goes from most of an hour to a few minutes. `--shards 1` puts it back, which is
worth having when a failure only shows up in a full build.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TESTS = ROOT / "tests"

# Modules per shard, which is what the shard count is worked out from. Six is
# from the table in the module docstring: the per binary overhead is still a
# fair share of a shard this size, and going smaller buys little while making
# the output longer and noisier.
MODULES_PER_SHARD = 6

# A test is a top level `def test_*` that takes no arguments. Anything indented
# is a method or a nested helper and is not a test.
TEST_RE = re.compile(r"^def (test_[A-Za-z0-9_]*)\s*\(\s*\)", re.MULTILINE)

Test = tuple[str, str, Path]


def mojo_binary() -> str:
    """Find a `mojo` that can also find its own standard library.

    Under `pixi run` the environment is already activated and plain `mojo`
    works. Run straight from a shell it usually is not, and the bare binary
    inside a pixi environment compiles nothing because it cannot locate `std`.
    The launcher pixi puts in `~/.pixi/bin` activates first, so fall back to
    that before giving up. Set MOJO to override.
    """
    override = os.environ.get("MOJO")
    if override:
        return override
    if os.environ.get("PIXI_PROJECT_ROOT") or os.environ.get("CONDA_PREFIX"):
        found = shutil.which("mojo")
        if found:
            return found
    launcher = Path.home() / ".pixi" / "bin" / "mojo"
    if launcher.exists():
        return str(launcher)
    found = shutil.which("mojo")
    if found:
        return found
    print(
        "mojo not found. Run `pixi run test`, or set MOJO to the binary.",
        file=sys.stderr,
    )
    sys.exit(2)


def discover(filter_: str | None) -> list[Test]:
    """Return (module, function, path) for every test, sorted by module."""
    found: list[Test] = []
    for path in sorted(TESTS.rglob("test_*.mojo")):
        module = ".".join(path.relative_to(ROOT).with_suffix("").parts)
        for name in TEST_RE.findall(path.read_text()):
            if filter_ and filter_ not in name and filter_ not in module:
                continue
            found.append((module, name, path))
    return found


def check_unique(tests: list[Test]) -> None:
    """Test names have to be unique across the whole suite.

    A generated main imports its tests into one namespace, so a duplicate name
    would silently shadow rather than run twice. Checked across the whole suite
    rather than within a shard, because which shard a module lands in is an
    implementation detail and a rule that depended on it would be a rule that
    changed under people.
    """
    seen: dict[str, Path] = {}
    clashes = []
    for _, name, path in tests:
        if name in seen and seen[name] != path:
            clashes.append(f"  {name}\n    {seen[name]}\n    {path}")
        seen[name] = path
    if clashes:
        print("duplicate test names:", file=sys.stderr)
        print("\n".join(clashes), file=sys.stderr)
        print("\nTest names must be unique across the suite.", file=sys.stderr)
        sys.exit(2)


def plan_shards(tests: list[Test], count: int) -> list[list[Test]]:
    """Split the tests into `count` groups, whole modules at a time.

    A module cannot be split because the point of a shard is that it is one
    compile, and the cost is in the module rather than in the test.

    Balanced by source bytes, biggest module first into whichever shard is
    smallest so far. Bytes are a rough proxy for what a module costs to compile
    and a much better one than counting tests, since a file of a hundred one
    line assertions is cheaper than a file of ten tests that each stand up a
    server. Sorting first is what keeps the result the same on every machine.
    """
    by_module: dict[str, list[Test]] = {}
    weight: dict[str, int] = {}
    for test in tests:
        module, _, path = test
        by_module.setdefault(module, []).append(test)
        weight[module] = path.stat().st_size

    count = max(1, min(count, len(by_module)))
    shards: list[list[Test]] = [[] for _ in range(count)]
    loads = [0] * count
    for module in sorted(by_module, key=lambda m: (-weight[m], m)):
        at = loads.index(min(loads))
        shards[at].extend(by_module[module])
        loads[at] += weight[module]
    return [s for s in shards if s]


def generate(tests: list[Test], repeat: int, fail_fast: bool) -> str:
    by_module: dict[str, list[str]] = {}
    for module, name, _ in tests:
        by_module.setdefault(module, []).append(name)

    lines = [
        "# Generated by tools/mojotest/run.py. Do not edit and do not commit.",
        "from std.time import perf_counter_ns",
        "",
    ]
    for module in sorted(by_module):
        names = ", ".join(sorted(by_module[module]))
        lines.append(f"from {module} import {names}")

    lines += [
        "",
        "",
        "def _run[name: StaticString](t: def () raises thin) -> Int:",
        "    var start = perf_counter_ns()",
        "    try:",
        "        t()",
        "    except e:",
        "        print('FAIL', name)",
        "        print('     ', String(e))",
        "        return 1",
        "    var micros = (perf_counter_ns() - start) // 1000",
        "    print('PASS', name, '(', micros, 'us )')",
        "    return 0",
        "",
        "",
        "def main() raises:",
        "    var failed = 0",
        "    var total = 0",
        f"    for _ in range({repeat}):",
    ]
    for _, name, _ in tests:
        lines.append("        total += 1")
        lines.append(f'        failed += _run["{name}"]({name})')
        if fail_fast:
            lines += [
                "        if failed != 0:",
                "            print('stopping after first failure')",
                "            raise Error('test run failed')",
            ]
    lines += [
        "    print('')",
        "    if failed != 0:",
        "        print(failed, 'of', total, 'failed')",
        "        raise Error('test run failed')",
        "    print(total, 'passed')",
    ]
    return "\n".join(lines) + "\n"


def run_shard(index: int, tests: list[Test], args, capture: bool) -> tuple[int, str]:
    """Build and run one shard, and hand back what it printed if it was caught.

    Only captured when shards are running at the same time, because interleaved
    output from several of them is unreadable and the caller wants to print each
    block whole. One shard at a time writes straight through instead.

    That difference is worth the branch. A shard writing to a pipe has its
    output buffered by the C library in the child, so a shard that dies rather
    than finishing loses whatever had not been flushed, which is most of what it
    had to say and usually the part naming the test it died on. A shard on the
    inherited terminal or log loses nothing. So the default run tells the truth
    about a crash and the parallel one trades some of that for readability.
    """
    path = TESTS / f"_generated_main_{index}.mojo"
    path.write_text(generate(tests, args.repeat, args.fail_fast))
    try:
        cmd = [mojo_binary(), "run", "-I", str(ROOT), str(path)]
        if args.seed is not None:
            cmd += ["--", str(args.seed)]
        if not capture:
            return subprocess.call(cmd, cwd=ROOT), ""
        done = subprocess.run(
            cmd, cwd=ROOT, capture_output=True, text=True, check=False
        )
        return done.returncode, done.stdout + done.stderr
    finally:
        if not args.keep:
            path.unlink(missing_ok=True)


def main() -> int:
    ap = argparse.ArgumentParser(description="Run the mojo.httpx test suite.")
    ap.add_argument("--filter", help="only tests whose name or module contains this")
    ap.add_argument("--fail-fast", action="store_true", help="stop at the first failure")
    ap.add_argument(
        "--repeat",
        type=int,
        default=1,
        metavar="N",
        help="run the suite N times, for shaking out flakes",
    )
    ap.add_argument(
        "--seed", type=int, help="seed for property tests, recorded in the output"
    )
    ap.add_argument(
        "--keep", action="store_true", help="leave the generated mains behind"
    )
    ap.add_argument(
        "--shards",
        type=int,
        metavar="N",
        help=(
            "binaries to split the suite over"
            f" (default: one per {MODULES_PER_SHARD} modules)"
        ),
    )
    ap.add_argument(
        "--jobs",
        type=int,
        default=1,
        metavar="N",
        help=(
            "shards to build and run at the same time. One by default: the tests"
            " that stand up sockets and the ones that fill every runtime worker"
            " both measure time, and two shards on one machine make those"
            " measurements worse"
        ),
    )
    args = ap.parse_args()

    tests = discover(args.filter)
    if not tests:
        where = f" matching {args.filter!r}" if args.filter else ""
        print(f"no tests found{where}", file=sys.stderr)
        return 1
    check_unique(tests)

    modules = len({module for module, _, _ in tests})
    wanted = args.shards
    if wanted is None:
        wanted = max(1, round(modules / MODULES_PER_SHARD))
    shards = plan_shards(tests, wanted)

    if args.seed is not None:
        print(f"seed {args.seed}")
    at_a_time = max(1, min(args.jobs, len(shards)))
    together = f", {at_a_time} at a time" if at_a_time > 1 else ""
    print(
        f"running {len(tests)} test(s) in {len(shards)} shard(s){together}\n",
        flush=True,
    )

    def header(i: int) -> str:
        names = len({module for module, _, _ in shards[i]})
        return (
            f"--- shard {i + 1}/{len(shards)}:"
            f" {names} module(s), {len(shards[i])} test(s)"
        )

    status = 0
    skipped = 0
    if at_a_time == 1:
        for i, shard in enumerate(shards):
            if status != 0 and args.fail_fast:
                skipped += 1
                continue
            print(header(i), flush=True)
            code, _ = run_shard(i, shard, args, capture=False)
            if code != 0:
                status = code
    else:
        with concurrent.futures.ThreadPoolExecutor(max_workers=at_a_time) as pool:
            pending = [
                pool.submit(run_shard, i, shard, args, True)
                for i, shard in enumerate(shards)
            ]
            for i, future in enumerate(pending):
                # Cancelling only takes a shard that has not started, so the
                # ones already in flight finish and are reported. Which is the
                # honest thing anyway: they ran, so their result is real.
                if status != 0 and args.fail_fast and future.cancel():
                    skipped += 1
                    continue
                code, output = future.result()
                print(header(i))
                print(output.rstrip("\n"), flush=True)
                if code != 0:
                    status = code

    if skipped:
        print(f"\nskipped {skipped} shard(s) after the first failure")
    if status != 0:
        print("\nsome shards failed. Their output is above.", file=sys.stderr)
    else:
        # Each shard has already printed its own count. This is the one line
        # that says the whole suite ran, which is what a reader is looking for
        # after scrolling past a dozen of them.
        print(f"\n{len(tests) * args.repeat} test(s) passed in {len(shards)} shard(s)")
    return status


if __name__ == "__main__":
    sys.exit(main())
