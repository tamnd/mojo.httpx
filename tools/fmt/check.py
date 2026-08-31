"""Check that every Mojo source file is already formatted.

`mojo format` has no `--check` flag and rewrites files in place, so the check has
to be built out of it. Hashing each file, running the formatter and comparing is
the way to do that without a working tree that is clean of everything else. The
obvious alternative, `mojo format && git diff --exit-code`, cannot tell a file
the formatter changed from a file the author changed, so it fails during any
normal editing session and stops being run.

The formatter has already fixed the files by the time this reports them, which is
what you want locally. In CI nothing is committed afterwards, so a non-zero exit
is still what fails the job.
"""

from __future__ import annotations

import hashlib
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TARGETS = ["httpx", "tests"]


def mojo_files() -> list[Path]:
    files: list[Path] = []
    for target in TARGETS:
        files.extend(sorted((ROOT / target).rglob("*.mojo")))
    return files


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    files = mojo_files()
    if not files:
        print("no mojo files found, which is not something to pass quietly")
        return 2

    before = {path: digest(path) for path in files}

    result = subprocess.run(
        ["mojo", "format", "-q", *TARGETS],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stdout)
        sys.stderr.write(result.stderr)
        print("mojo format failed to run")
        return result.returncode

    changed = [path for path in files if digest(path) != before[path]]
    if changed:
        print("these files were not formatted, and now are:")
        for path in changed:
            print(f"    {path.relative_to(ROOT)}")
        print("\ncommit the result, or run `pixi run format` before committing")
        return 1

    print(f"format: ok ({len(files)} file(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
