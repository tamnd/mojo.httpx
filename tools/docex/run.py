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

Run it with `pixi run docex`. Give it paths to check only those.
"""

import argparse
import re
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

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


def blocks(path):
    """Every Mojo block in one file, with the line each one starts on."""
    text = path.read_text()
    found = []
    for match in BLOCK.finditer(text):
        line = text[: match.start()].count("\n") + 1
        found.append((line, match.group(1)))
    return found


def compile_one(job):
    """Build one block and give back what the compiler said about it.

    Object code to /dev/null rather than an executable, because linking an
    example is time spent on an artifact nobody looks at. Each block gets its
    own directory so that the file is always called the same thing and a
    diagnostic reads the same from run to run.
    """
    name, line, body = job
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp) / "example.mojo"
        source.write_text(body)
        result = subprocess.run(
            [
                "mojo",
                "build",
                "-I",
                str(ROOT),
                "--emit=object",
                "-o",
                "/dev/null",
                str(source),
            ],
            capture_output=True,
            text=True,
            cwd=ROOT,
        )
    if result.returncode == 0:
        return None
    return f"{name}:{line}\n{result.stdout}{result.stderr}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "paths",
        nargs="*",
        help="markdown files to check, defaulting to all of the docs",
    )
    args = parser.parse_args()

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

    # One compiler per core. Each build is a second or two and there are dozens
    # of them, so serial is a minute of waiting for no reason.
    with ThreadPoolExecutor() as pool:
        failures = [f for f in pool.map(compile_one, jobs) if f]

    for failure in failures:
        print(failure, file=sys.stderr)

    print(
        f"{len(jobs)} example(s) compiled, {skipped} fragment(s) skipped,"
        f" {len(failures)} failed"
    )
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
