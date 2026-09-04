"""Compile every Mojo example in the documentation.

A documentation example nobody can run is one nobody can check, and an HTTP
client's docs are almost entirely examples. So every ```mojo block in the
markdown here is a whole program rather than a fragment, and this compiles all
of them against the working tree.

It catches the ordinary rot, a renamed argument or a method that became a
field, and it caught two real defects the day it was written: the error
predicates and `Deadlines` were both missing from `httpx/__init__.mojo`, which
made two documented extension points impossible to use from outside the
package. Neither was visible by reading. Both were obvious the moment an
example was handed to the compiler.

Compiling is the whole check. Running would need a network, a server and a
tolerance for flakes, and the mistakes people actually make in a code sample
are the ones a type checker already knows about.

Examples are compiled several to a file rather than one each, because almost
all of the time in a build here goes on the package rather than on the twelve
lines of example in front of it. See `batches` for what keeps that from letting
one example lean on another.

Run it with `pixi run docex`. Give it paths to check only those, and `--batch`
to change how many examples share a build.
"""

import argparse
import re
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# How many examples go into one build by default. The gain flattens out quickly,
# since past the first few the package is already paid for and each extra
# example is only its own dozen lines, and a smaller number keeps a failure
# closer to the example that caused it.
DEFAULT_BATCH = 16

# Where the prose lives. README and CONTRIBUTING are in here too, because a
# broken example on the front page is the worst place to have one.
SOURCES = sorted((ROOT / "docs").glob("*.md")) + [
    ROOT / "README.md",
    ROOT / "CONTRIBUTING.md",
]

BLOCK = re.compile(r"^```mojo\n(.*?)^```$", re.M | re.S)

# A block with no `main` is a signature, a trait declaration or a couple of
# lines showing a call, and there is nothing to build. Those are deliberate:
# spelling out a whole program to show one line would bury the line. What is
# not allowed is a block that meant to be a program and forgot, which is why
# the count of skipped blocks is printed rather than passed over.
ENTRY = "def main("

# The entry point of one example, which has to be renamed before it can share a
# file with another one.
MAIN_RE = re.compile(r"^(async[ \t]+)?def[ \t]+main[ \t]*\(", re.M)

# Anything an example puts at the top level besides its own `main`. An example
# that has one of these is built on its own, for the reason in `batches`.
DEFINES_RE = re.compile(
    r"^(?:struct|trait|comptime|alias)[ \t]+\w+"
    r"|^(?:async[ \t]+)?def[ \t]+(?!main\b)\w+",
    re.M,
)


def blocks(path):
    """Every Mojo block in one file, with the line each one starts on."""
    text = path.read_text()
    found = []
    for match in BLOCK.finditer(text):
        line = text[: match.start()].count("\n") + 1
        found.append((line, match.group(1)))
    return found


def batches(jobs, size):
    """Group the examples into the files they will be compiled in.

    An example that declares anything at the top level, a struct, a trait, an
    alias or a function of its own, is put in a file by itself. Everything else
    goes in with up to `size` others.

    That split is what keeps batching honest. The whole point of this tool is
    that each example stands alone, and two examples in one file could break
    that: the second could use a struct the first declared and compile anyway,
    which is exactly the mistake this is supposed to catch. An example whose
    only top level name is its own `main`, renamed to something nothing else
    refers to, has nothing to lend.
    """
    alone = [job for job in jobs if DEFINES_RE.search(job[2])]
    shared = [job for job in jobs if not DEFINES_RE.search(job[2])]
    out = [[job] for job in alone]
    for start in range(0, len(shared), size):
        out.append(shared[start : start + size])
    return out


def compile_batch(batch):
    """Build one file of examples and give back what the compiler said.

    Object code to /dev/null rather than an executable, because linking an
    example is time spent on an artifact nobody looks at.

    A failure is reported against the whole file, so when there is more than one
    example in it they are built again separately to find out which one it was.
    That costs an extra build on the way to a failure, which is a run that was
    going to end in somebody reading a diagnostic anyway, and it keeps the
    output pointing at a line in a document rather than at a line in a temporary
    file nobody has.
    """
    source = "\n\n\n".join(
        MAIN_RE.sub(rf"\1def _example_{index}(", body)
        for index, (_, _, body) in enumerate(batch)
    )
    if _build(source) is None:
        return []
    if len(batch) == 1:
        name, line, body = batch[0]
        return [f"{name}:{line}\n{_build(body)}"]
    return [failure for job in batch for failure in compile_batch([job])]


def _build(source):
    """Compile one file, and give back the diagnostics or None if it built.

    Its own directory so that the file is always called the same thing and a
    diagnostic reads the same from run to run.
    """
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "example.mojo"
        path.write_text(source)
        result = subprocess.run(
            [
                "mojo",
                "build",
                "-I",
                str(ROOT),
                "--emit=object",
                "-o",
                "/dev/null",
                str(path),
            ],
            capture_output=True,
            text=True,
            cwd=ROOT,
        )
    if result.returncode == 0:
        return None
    return f"{result.stdout}{result.stderr}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "paths",
        nargs="*",
        help="markdown files to check, defaulting to all of the docs",
    )
    parser.add_argument(
        "--batch",
        type=int,
        default=DEFAULT_BATCH,
        help=f"examples per build (default {DEFAULT_BATCH}, 1 for one each)",
    )
    args = parser.parse_args()
    if args.batch < 1:
        parser.error("--batch has to be at least 1")

    sources = [Path(p).resolve() for p in args.paths] if args.paths else SOURCES

    jobs = []
    skipped = 0
    for path in sources:
        name = path.relative_to(ROOT).as_posix()
        for line, body in blocks(path):
            if ENTRY not in body:
                skipped += 1
                continue
            jobs.append((name, line, body))

    if not jobs:
        print("no examples to compile")
        return 0

    groups = batches(jobs, args.batch)

    # One compiler per core. Each build takes seconds and there are dozens of
    # them, so serial is minutes of waiting for no reason.
    with ThreadPoolExecutor() as pool:
        failures = [f for group in pool.map(compile_batch, groups) for f in group]

    for failure in failures:
        print(failure, file=sys.stderr)

    print(
        f"{len(jobs)} example(s) compiled in {len(groups)} build(s),"
        f" {skipped} fragment(s) skipped, {len(failures)} failed"
    )
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
