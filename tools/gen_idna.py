"""Turn the vendored Unicode files into the tables UTS-46 needs.

    pixi run python tools/gen_idna.py          rewrite httpx/_util/_unicode_data.mojo
    pixi run python tools/gen_idna.py --check  fail if the file is out of date

Run it through `pixi run`, because the output goes through `mojo format` and the
toolchain is only on PATH there.

Six tables come out of four files, and they all have to be from one Unicode
release. A mapping table that knows about a character the combining class table
does not is a name that maps to something and then fails to normalize, so the
version line of every input is read and compared before anything is generated.

Two policy decisions are baked in here rather than left as runtime flags, because
they are not choices a caller should be making per request.

Transitional processing is off. It exists so that names registered under IDNA2003
kept resolving during the changeover, and it maps four characters, including the
German sharp s, to something else. Every browser turned it off years ago, and a
client that had it on would send requests for `faß.de` to `fass.de`.

STD3 ASCII rules are on. That means a hostname may only contain letters, digits
and hyphens, which is what DNS and the `Host` header actually accept. Turning it
off would let characters like `<` and a space through into a `Host` header, and
what happens next depends on the server.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
import tomllib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from mojogen import formatted, mojo_string

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "tests" / "data" / "LOCK.toml"
OUTPUT = ROOT / "httpx" / "_util" / "_unicode_data.mojo"

SOURCES = (
    "unicode-idna-mapping",
    "unicode-data",
    "unicode-normalization-props",
    "unicode-joining-type",
)

# Unicode says which release a file belongs to in three different ways depending
# on which file it is, so all three are tried. A `# Version:` line, the version
# in the filename on the first line, and failing both, the version in the URL the
# lock recorded. UnicodeData.txt carries no header at all, which is why the last
# one is not just a convenience.
VERSION_LINE = re.compile(r"^#\s*Version:\s*([0-9.]+)\s*$")
VERSION_NAME = re.compile(r"^#\s*\S+-([0-9]+\.[0-9]+\.[0-9]+)\.txt\s*$")
VERSION_URL = re.compile(r"/([0-9]+\.[0-9]+\.[0-9]+)/")

MAX_CODEPOINT = 0x10FFFF

# Hangul composes and decomposes by arithmetic rather than by table, so the
# syllables are left out of both. Putting them in would add eleven thousand
# entries that say what a dozen lines of code already say.
HANGUL_S_BASE = 0xAC00
HANGUL_S_COUNT = 11172


def locked() -> dict[str, dict[str, object]]:
    with LOCK.open("rb") as handle:
        return tomllib.load(handle)["file"]


def read_source(name: str) -> tuple[str, str]:
    """The text of one vendored file and its Unicode version.

    The digest is checked here as well as in `vendor-check`, because this is the
    step that turns those bytes into code that ships.
    """
    entry = locked()[name]
    path = ROOT / str(entry["path"])
    if not path.exists():
        raise SystemExit(
            f"{path.relative_to(ROOT)} is missing."
            " Run `python tools/vendor/fetch.py --update`."
        )
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != entry["sha256"]:
        raise SystemExit(
            f"{path.relative_to(ROOT)} does not match the lock."
            " Run `pixi run vendor-check` first."
        )
    text = data.decode("utf-8")
    for line in text.splitlines():
        if not line.startswith("#"):
            break
        for pattern in (VERSION_LINE, VERSION_NAME):
            found = pattern.match(line)
            if found:
                return text, found.group(1)
    found = VERSION_URL.search(str(entry["url"]))
    if found:
        return text, found.group(1)
    raise SystemExit(
        f"{path.relative_to(ROOT)} says nothing about which Unicode release it"
        " is from, and neither does the url it came from"
    )


def unicode_version() -> dict[str, str]:
    versions = {}
    for name in SOURCES:
        versions[name] = read_source(name)[1]
    distinct = set(versions.values())
    if len(distinct) != 1:
        for name, version in sorted(versions.items()):
            print(f"  {name}: {version}", file=sys.stderr)
        raise SystemExit(
            "the vendored Unicode files are from different releases. Refresh"
            " them together with `python tools/vendor/fetch.py --update`."
        )
    return versions


def fields_of(text: str) -> list[list[str]]:
    """Every data line of a semicolon separated Unicode file, split and trimmed."""
    rows = []
    for line in text.splitlines():
        line = line.split("#")[0].strip()
        if line:
            rows.append([part.strip() for part in line.split(";")])
    return rows


def code_range(text: str) -> tuple[int, int]:
    if ".." in text:
        first, last = text.split("..")
        return int(first, 16), int(last, 16)
    value = int(text, 16)
    return value, value


def idna_mapping() -> list[tuple[int, int, str, str]]:
    """The UTS-46 status of every code point, and the pool the targets live in.

    Statuses collapse to four. `deviation` becomes `valid` because transitional
    processing is off, which means the four deviation characters keep the meaning
    they were given rather than the one IDNA 2003 folded them to. Doing that here
    rather than at runtime means the lookup is one comparison and there is no
    flag to get wrong.

    STD3 ASCII rules do not appear here, because as of Unicode 17 the file does
    not carry them: the two `disallowed_STD3` statuses were folded into `valid`
    and `mapped`, and an implementation that wants the rules applies them itself.
    `_is_std3_byte` in httpx/_util/idna.mojo is where that happens.
    """
    text, _ = read_source("unicode-idna-mapping")
    collapsed: list[list[object]] = []
    for row in fields_of(text):
        first, last = code_range(row[0])
        status = row[1]
        if status == "deviation":
            status = "valid"
        kind = {"valid": "v", "ignored": "i", "mapped": "m", "disallowed": "d"}[
            status
        ]
        target = ""
        if kind == "m":
            target = "".join(
                chr(int(point, 16)) for point in row[2].split() if point
            )
        # Runs of the same status merge, which takes a third off the table. A
        # mapped run cannot merge with its neighbour even when the target is the
        # same, because a range maps every code point in it to one string and two
        # adjacent ranges mapping to one string is a different statement.
        if (
            collapsed
            and kind != "m"
            and collapsed[-1][2] == kind
            and collapsed[-1][1] + 1 == first
        ):
            collapsed[-1][1] = last
            continue
        collapsed.append([first, last, kind, target])
    return [(int(a), int(b), str(k), str(t)) for a, b, k, t in collapsed]


def unicode_data() -> tuple[
    dict[int, str], dict[int, int], dict[int, str], dict[int, list[int]]
]:
    """General category, combining class, bidi class and canonical decomposition.

    The database writes large blocks as a First and Last pair rather than a line
    per character, so those are expanded. Nothing in such a block has a
    decomposition, which is why only the three property maps are filled from it.
    """
    text, _ = read_source("unicode-data")
    categories: dict[int, str] = {}
    combining: dict[int, int] = {}
    bidi: dict[int, str] = {}
    decomposition: dict[int, list[int]] = {}

    pending_first = -1
    for row in fields_of(text):
        point = int(row[0], 16)
        name = row[1]
        if name.endswith(", First>"):
            pending_first = point
            continue
        span = range(point, point + 1)
        if name.endswith(", Last>"):
            span = range(pending_first, point + 1)
            pending_first = -1
        for each in span:
            categories[each] = row[2]
            if row[3] != "0":
                combining[each] = int(row[3])
            bidi[each] = row[4]
        if row[5] and not row[5].startswith("<"):
            decomposition[point] = [
                int(part, 16) for part in row[5].split() if part
            ]
    return categories, combining, bidi, decomposition


def composition_exclusions() -> set[int]:
    text, _ = read_source("unicode-normalization-props")
    excluded: set[int] = set()
    for row in fields_of(text):
        if len(row) > 1 and row[1] == "Full_Composition_Exclusion":
            first, last = code_range(row[0])
            excluded.update(range(first, last + 1))
    return excluded


def joining_types() -> list[tuple[int, int, str]]:
    """Every code point that joins, as merged ranges.

    Non joining is the default and by far the most common, so it is left out and
    a miss in the table means it.
    """
    text, _ = read_source("unicode-joining-type")
    rows = []
    for row in fields_of(text):
        first, last = code_range(row[0])
        kind = row[1]
        if kind in ("U", "Non_Joining"):
            continue
        rows.append((first, last, kind[0]))
    rows.sort()
    return merge_ranges(rows)


def merge_ranges(
    rows: list[tuple[int, int, str]]
) -> list[tuple[int, int, str]]:
    merged: list[list[object]] = []
    for first, last, value in rows:
        if merged and merged[-1][2] == value and merged[-1][1] + 1 == first:
            merged[-1][1] = last
            continue
        merged.append([first, last, value])
    return [(int(a), int(b), str(c)) for a, b, c in merged]


def ranges_of(values: dict[int, str]) -> list[tuple[int, int, str]]:
    return merge_ranges(
        [(point, point, values[point]) for point in sorted(values)]
    )


BIDI_CODES = {
    "L": "L",
    "R": "R",
    "AL": "A",
    "AN": "N",
    "EN": "E",
    "ES": "S",
    "CS": "C",
    "ET": "T",
    "ON": "O",
    "BN": "B",
    "NSM": "M",
}


def full_decomposition(
    point: int, table: dict[int, list[int]]
) -> list[int]:
    """`point` decomposed all the way down.

    Doing the recursion here means the runtime does one lookup per character
    instead of looping until nothing changes, and the depth is a property of the
    data rather than something the decomposer has to be trusted to bound.
    """
    out: list[int] = []
    for each in table[point]:
        if each in table:
            out.extend(full_decomposition(each, table))
        else:
            out.append(each)
    return out


def hex_field(value: int, width: int) -> str:
    return f"{value:0{width}X}"


CHUNK = 60
"""Wide enough that the generated file reads in a diff, narrow enough to stay
inside the line length the formatter uses everywhere else."""


def literal(name: str, text: str) -> list[str]:
    lines = [f"comptime {name} = StaticString("]
    if not text:
        lines.append('    ""')
    for start in range(0, len(text), CHUNK):
        lines.append(f"    {mojo_string(text[start : start + CHUNK])}")
    lines.append(")")
    lines.append("")
    return lines


def table(name: str, records: list[str], width: int) -> list[str]:
    """One fixed width table, with the two numbers a lookup needs beside it."""
    for record in records:
        assert len(record) == width, (name, record)
    lines = [
        f"comptime {name}_COUNT = {len(records)}",
        "",
        f"comptime {name}_WIDTH = {width}",
        "",
    ]
    return lines + literal(name, "".join(records))


def pool(name: str, text: str) -> list[str]:
    """One blob that records index into, measured in bytes rather than
    characters because that is what an offset out of a record means."""
    lines = [
        f"comptime {name}_BYTES = {len(text.encode('utf-8'))}",
        "",
    ]
    return lines + literal(name, text)


def render(version: str) -> str:
    categories, combining, bidi, decomposition = unicode_data()
    excluded = composition_exclusions()

    map_offsets: dict[str, int] = {}
    map_pool = ""
    map_records = []
    for first, last, kind, target in idna_mapping():
        offset = 0
        length = 0
        if kind == "m":
            if target not in map_offsets:
                map_offsets[target] = len(map_pool.encode("utf-8"))
                map_pool += target
            offset = map_offsets[target]
            length = len(target.encode("utf-8"))
        map_records.append(
            hex_field(first, 6)
            + hex_field(last, 6)
            + kind
            + hex_field(offset, 5)
            + hex_field(length, 2)
        )

    decomposition_pool = ""
    decomposition_offsets: dict[str, int] = {}
    decomposition_records = []
    for point in sorted(decomposition):
        if is_hangul(point):
            continue
        text = "".join(
            chr(each) for each in full_decomposition(point, decomposition)
        )
        if text not in decomposition_offsets:
            decomposition_offsets[text] = len(
                decomposition_pool.encode("utf-8")
            )
            decomposition_pool += text
        decomposition_records.append(
            hex_field(point, 6)
            + hex_field(decomposition_offsets[text], 5)
            + hex_field(len(text.encode("utf-8")), 2)
        )

    compositions = []
    for point, parts in sorted(decomposition.items()):
        if len(parts) != 2 or point in excluded or is_hangul(point):
            continue
        if combining.get(parts[0], 0) != 0:
            # A pair whose first character is not a starter never composes, and
            # leaving it in would let the composer join something in the middle
            # of a combining sequence.
            continue
        compositions.append((parts[0], parts[1], point))
    compositions.sort()
    composition_records = [
        hex_field(a, 6) + hex_field(b, 6) + hex_field(c, 6)
        for a, b, c in compositions
    ]

    combining_records = [
        hex_field(a, 6) + hex_field(b, 6) + hex_field(int(value), 2)
        for a, b, value in merge_ranges(
            [(p, p, str(combining[p])) for p in sorted(combining)]
        )
    ]

    marks = {
        point: "M" for point in sorted(categories) if categories[point][0] == "M"
    }
    mark_records = [
        hex_field(a, 6) + hex_field(b, 6) for a, b, _ in ranges_of(marks)
    ]

    bidi_classes = {
        point: BIDI_CODES[bidi[point]]
        for point in sorted(bidi)
        if bidi[point] in BIDI_CODES
    }
    bidi_records = [
        hex_field(a, 6) + hex_field(b, 6) + value
        for a, b, value in ranges_of(bidi_classes)
    ]

    joining_records = [
        hex_field(a, 6) + hex_field(b, 6) + value for a, b, value in joining_types()
    ]

    lines = [
        '"""The Unicode tables UTS-46 is built out of.',
        "",
        "Generated by tools/gen_idna.py from the files vendored under tests/data.",
        "Do not edit. Run `pixi run python tools/gen_idna.py` after refreshing them.",
        "",
        "Every table is a run of fixed width hexadecimal records sorted by code point,",
        "so a lookup is a binary search over a single string with no index beside it.",
        "Fixed width is what makes that possible: the record at position n starts at n",
        "times the width, so there is nothing to keep in step with the data.",
        '"""',
        "",
        "comptime UNICODE_VERSION = StaticString(" + mojo_string(version) + ")",
        "",
    ]
    lines += table("IDNA_MAP", map_records, 20)
    lines += pool("IDNA_MAP_POOL", map_pool)
    lines += table("DECOMPOSITION", decomposition_records, 13)
    lines += pool("DECOMPOSITION_POOL", decomposition_pool)
    lines += table("COMPOSITION", composition_records, 18)
    lines += table("COMBINING", combining_records, 14)
    lines += table("MARKS", mark_records, 12)
    lines += table("BIDI", bidi_records, 13)
    lines += table("JOINING", joining_records, 13)
    return formatted("\n".join(lines) + "\n", "_unicode_data.mojo")


def is_hangul(point: int) -> bool:
    return HANGUL_S_BASE <= point < HANGUL_S_BASE + HANGUL_S_COUNT


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="report whether the table matches the vendored files",
    )
    args = parser.parse_args()

    version = next(iter(unicode_version().values()))
    rendered = render(version)

    if args.check:
        current = OUTPUT.read_text() if OUTPUT.exists() else ""
        if current != rendered:
            print(
                f"idna: {OUTPUT.relative_to(ROOT)} is out of date."
                " Run `pixi run python tools/gen_idna.py`.",
                file=sys.stderr,
            )
            return 1
        print(f"idna: ok, tables match Unicode {version}")
        return 0

    OUTPUT.write_text(rendered)
    print(f"idna: wrote Unicode {version} tables to {OUTPUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
