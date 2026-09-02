"""Verify the vendored corpora are exactly what the lock file says.

Three things are checked, and the third is the one that catches the mistake
people actually make. Every declared source has a file. Every file hashes to what
was recorded. And every file under tests/data is declared, so a corpus that got
copied in by hand, with no record of where it came from or what licence it
carries, fails rather than sitting there looking official.
"""

from __future__ import annotations

import hashlib
import sys
import tomllib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from sources import all_units, load_sources

ROOT = Path(__file__).resolve().parents[2]
LOCK = ROOT / "tests" / "data" / "LOCK.toml"
DATA = ROOT / "tests" / "data"


def main() -> int:
    if not LOCK.exists():
        print(
            "tests/data/LOCK.toml is missing. Run"
            " `python tools/vendor/fetch.py --update`.",
            file=sys.stderr,
        )
        return 1

    sources = {unit.name: unit for unit in all_units(load_sources())}
    with LOCK.open("rb") as handle:
        locked = tomllib.load(handle).get("file", {})

    problems: list[str] = []
    accounted: set[Path] = {LOCK}

    for name, source in sources.items():
        if name not in locked:
            problems.append(
                f"{name} is declared in sources.toml but not locked."
                " Run `python tools/vendor/fetch.py --update`."
            )
            continue
        entry = locked[name]
        if entry["path"] != source.path:
            problems.append(
                f"{name} is locked at {entry['path']} but declared at"
                f" {source.path}"
            )
        path = ROOT / entry["path"]
        accounted.add(path)
        if not path.exists():
            problems.append(f"{name}: {entry['path']} is missing")
            continue
        data = path.read_bytes()
        found = hashlib.sha256(data).hexdigest()
        if found != entry["sha256"]:
            problems.append(
                f"{name}: {entry['path']} does not match the lock."
                f" Expected {entry['sha256'][:16]}, found {found[:16]}."
            )
        elif len(data) != entry["size"]:
            problems.append(f"{name}: {entry['path']} has an unexpected size")

    for name in locked:
        if name not in sources:
            problems.append(
                f"{name} is locked but no longer declared in sources.toml"
            )

    if DATA.exists():
        for path in sorted(DATA.rglob("*")):
            if path.is_dir() or path in accounted:
                continue
            problems.append(
                f"{path.relative_to(ROOT)} is not declared in sources.toml."
                " Every corpus records where it came from and what licence it"
                " carries."
            )

    if problems:
        print(f"vendor: {len(problems)} problem(s)")
        for problem in problems:
            print(f"  {problem}")
        return 1
    print(f"vendor: ok, {len(locked)} corpora match the lock")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
