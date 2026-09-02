"""Reading sources.toml, and turning a corpus into the files it is made of.

Most vendored corpora are one file, and for those a source and a lock entry are
the same thing. The HPACK vectors are not: they are a directory of story files
that only mean anything together, and declaring forty of them separately would
mean forty copies of one licence and one paragraph saying what they are for.

So a source may name a set of files under a shared prefix instead. Each one is
still pinned on its own, because the point of the lock is that a file which
changed without a fetch shows up as a failure, and a digest over the set would
say something changed without saying what.
"""

from __future__ import annotations

import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "tools" / "vendor" / "sources.toml"


class Unit:
    """One file to fetch, check and lock, whatever declared it."""

    def __init__(self, name: str, url: str, path: str) -> None:
        self.name = name
        self.url = url
        self.path = path


def load_sources() -> list[dict]:
    with SOURCES.open("rb") as handle:
        return tomllib.load(handle)["source"]


def units_of(source: dict) -> list[Unit]:
    """The files one source declares, in the order it declared them.

    A source with no `files` is itself one file, which is the shape every
    corpus had before the HPACK vectors arrived and the shape most of them
    still have.
    """
    files = source.get("files")
    if not files:
        return [Unit(source["name"], source["url"], source["path"])]
    return [
        Unit(
            f"{source['name']}/{relative}",
            f"{source['url']}{relative}",
            f"{source['path']}{relative}",
        )
        for relative in files
    ]


def all_units(sources: list[dict]) -> list[Unit]:
    out: list[Unit] = []
    for source in sources:
        out.extend(units_of(source))
    return out
