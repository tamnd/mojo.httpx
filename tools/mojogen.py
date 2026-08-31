"""Shared pieces for the scripts that compile vendored corpora into Mojo.

Two of them so far, cookies and URLs, and the awkward parts are the same in
both: getting a string literal right, and agreeing with `mojo format` about
layout so the format check and the generator check do not contradict each other.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path


def mojo_string(text: str) -> str:
    """One Mojo string literal holding exactly `text`.

    Non ASCII goes through as itself, because these fixtures are UTF-8 and a
    case carrying Chinese in a cookie value is easier to review as Chinese than
    as a row of escapes. Control characters cannot go through as themselves and
    are written as hex.

    Always double quoted. The formatter has opinions about which quote to use
    and gets the last word, so there is no reason to have them here too.
    """
    out = ['"']
    for char in text:
        if char == "\\":
            out.append("\\\\")
        elif char == '"':
            out.append('\\"')
        elif char == "\n":
            out.append("\\n")
        elif char == "\r":
            out.append("\\r")
        elif char == "\t":
            out.append("\\t")
        elif ord(char) < 0x20 or ord(char) == 0x7F:
            out.append(f"\\x{ord(char):02x}")
        else:
            out.append(char)
    out.append('"')
    return "".join(out)


def formatted(source: str, name: str) -> str:
    """`source` as `mojo format` would leave it.

    The fixtures live under tests/ so the repository wide format check runs the
    formatter over them like any other file. If a generator emitted a shape the
    formatter disagrees with, the two would fight: format rewrites the file,
    then the generator's `--check` reports it as out of date, and neither is
    wrong. Handing the layout to the formatter here settles it, and means the
    rules for splitting a long line live in one place rather than being guessed
    at in every generator.
    """
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder) / name
        path.write_text(source, encoding="utf-8")
        result = subprocess.run(
            ["mojo", "format", "-q", str(path)],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            sys.stderr.write(result.stdout)
            sys.stderr.write(result.stderr)
            raise SystemExit(
                "mojo format failed. Run this through `pixi run`, since that is"
                " what puts the toolchain on PATH."
            )
        return path.read_text(encoding="utf-8")
