#!/usr/bin/env python3
"""Check the errno table in httpx/_ffi/errno.mojo against this platform.

The table is written by hand because Mojo cannot read a C header, and a wrong
value there produces a bug that only appears on one platform under load. So we
check it. Python's `errno` module is populated by CPython from the platform
headers at build time, which makes it a fair source of truth and needs no C
compiler.

Run it on every platform we support. On macOS that is `pixi run baseline`. On
Linux it goes through `tools/fleet/run.sh`.

    python tools/baseline/check_errno.py
"""

from __future__ import annotations

import errno as py_errno
import platform
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "httpx" / "_ffi" / "errno.mojo"

# Matches both forms the file uses:
#   comptime EBADF = c_int(9)
#   comptime EAGAIN = c_int(35) if _MACOS else c_int(11)
SHARED = re.compile(r"^comptime (E[A-Z0-9]+) = c_int\((\d+)\)\s*$", re.MULTILINE)
SPLIT = re.compile(
    r"^comptime (E[A-Z0-9]+) = c_int\((\d+)\) if _MACOS else c_int\((\d+)\)\s*$",
    re.MULTILINE,
)

# Names we define that Python does not always expose. Checked only when present.
OPTIONAL = {"ETOOMANYREFS", "EPFNOSUPPORT", "ESOCKTNOSUPPORT", "EHOSTDOWN"}


def declared() -> dict[str, int]:
    """The value the Mojo table would compile to on this platform."""
    text = SOURCE.read_text()
    is_macos = platform.system() == "Darwin"
    out: dict[str, int] = {}
    for name, value in SHARED.findall(text):
        out[name] = int(value)
    for name, mac, linux in SPLIT.findall(text):
        out[name] = int(mac if is_macos else linux)
    return out


def main() -> int:
    table = declared()
    if not table:
        print(f"no errno constants found in {SOURCE}", file=sys.stderr)
        return 2

    wrong: list[str] = []
    missing: list[str] = []
    for name, value in sorted(table.items()):
        actual = getattr(py_errno, name, None)
        if actual is None:
            if name not in OPTIONAL:
                missing.append(name)
            continue
        if actual != value:
            wrong.append(f"  {name}: table says {value}, platform says {actual}")

    print(f"{platform.system()} {platform.machine()}: checked {len(table)} constants")
    if missing:
        print("not available from Python on this platform, unchecked:")
        print("  " + ", ".join(missing))
    if wrong:
        print("\nwrong values:", file=sys.stderr)
        print("\n".join(wrong), file=sys.stderr)
        print(f"\nFix {SOURCE.relative_to(ROOT)}.", file=sys.stderr)
        return 1
    print("errno table matches the platform")
    return 0


if __name__ == "__main__":
    sys.exit(main())
