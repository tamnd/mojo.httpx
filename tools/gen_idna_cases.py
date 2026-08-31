"""Turn the Unicode IdnaTestV2 corpus into a Mojo fixture.

    pixi run python tools/gen_idna_cases.py          rewrite the fixture
    pixi run python tools/gen_idna_cases.py --check  fail if it is out of date

Run it through `pixi run`, because the output goes through `mojo format` and the
toolchain is only on PATH there.

Only the toASCII side with transitional processing off is compiled in. The
toUnicode column describes an operation this library does not offer, because a
client needs the name that goes on the wire and only needs the display form to
show back to a person, which `decode_host` does without the validation pass. The
transitional columns describe IDNA 2003 folding, which UTS-46 has deprecated and
which no current implementation does.

The corpus lists the flags it expects and states which status codes an
implementation may ignore when it has a flag set differently. CheckHyphens is
off here, matching the URL Standard, so V2 and V3 are ignored. X4_2 is a
toUnicode only code and never applies. Everything else is honoured, including
U1, which is the one most implementations turn off: STD3 ASCII rules are on
here, so a name with an underscore or a space in it is rejected rather than
passed through to a resolver that will not find it.

Lines whose source or expected value cannot be written as UTF-8 are skipped, as
the corpus says such lines may be. They test surrogate handling in a string type
Mojo does not have.
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
OUTPUT = ROOT / "tests" / "fixtures" / "idna_cases.mojo"

IGNORED_STATUS = {"V2", "V3", "X4_2"}

ESCAPE = re.compile(r"\\u([0-9A-Fa-f]{4})|\\x\{([0-9A-Fa-f]+)\}")


def source_path_and_digest() -> tuple[Path, str]:
    with LOCK.open("rb") as handle:
        locked = tomllib.load(handle)["file"]["unicode-idna"]
    return ROOT / locked["path"], locked["sha256"]


def unescaped(field: str) -> str:
    """The field with the corpus escapes turned back into characters.

    Both spellings appear, `\\uXXXX` for anything in the basic plane and
    `\\x{XXXXX}` for the rest, and a field can hold either.
    """
    return ESCAPE.sub(
        lambda found: chr(int(found.group(1) or found.group(2), 16)), field
    )


def writable(text: str) -> bool:
    """Whether `text` can be a Mojo string literal.

    A lone surrogate is a valid Python string and is not valid UTF-8, so it
    cannot be one. The corpus uses them to test what an implementation does with
    ill formed input, which is a question that does not arise here.
    """
    try:
        text.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return True


def statuses(field: str) -> set[str]:
    field = field.strip()
    if not field.startswith("["):
        return set()
    inside = field[1:-1].strip()
    if not inside:
        return set()
    return {code.strip() for code in inside.split(",") if code.strip()}


def only_a_root_dot(expected: str) -> bool:
    """Whether the empty label A4_2 objects to is the root at the end.

    VerifyDnsLength counts the empty root label as an error and this library does
    not, because a name written with a trailing dot is one a resolver accepts and
    is how a caller says not to try the search domains. Every other empty label
    is an error here too, so A4_2 is only ignored for this one shape.
    """
    if not expected.endswith("."):
        return False
    name = expected[:-1]
    labels = name.split(".")
    return len(name) <= 253 and all(1 <= len(label) <= 63 for label in labels)


def cases_from(path: Path) -> list[dict[str, object]]:
    out: list[dict[str, object]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0]
        if not line.strip():
            continue
        columns = [column.strip() for column in line.split(";")]
        if len(columns) < 5:
            continue

        source = unescaped(columns[0])
        # A blank toAscii column means the toUnicode value, and a blank
        # toUnicode column means the source. The corpus writes an unchanged
        # value as a blank rather than repeating it.
        unicode_form = unescaped(columns[1]) or source
        expected = unescaped(columns[3]) or unicode_form
        found = statuses(columns[4]) if columns[4] else statuses(columns[2])

        if source == '""':
            source = ""
        if expected == '""':
            expected = ""
        if not writable(source) or not writable(expected):
            continue

        found = found - IGNORED_STATUS
        if found == {"A4_2"} and only_a_root_dot(expected):
            found = set()
        if source == "" and found <= {"A4_1", "A4_2"}:
            # The empty name. `encode_host` hands it straight back and leaves the
            # question alone, because whether a url may have no host in it
            # depends on the scheme and the url parser is the layer that knows.
            found = set()
        fails = bool(found)
        out.append(
            {
                "source": source,
                "expected": "" if fails else expected,
                "fails": fails,
            }
        )
    return out


def render(cases: list[dict[str, object]], digest: str) -> str:
    lines = [
        '"""IDNA conformance cases, compiled from the vendored corpus.',
        "",
        "Generated by tools/gen_idna_cases.py from tests/data/idna/IdnaTestV2.txt.",
        "Do not edit. Run `pixi run python tools/gen_idna_cases.py` to redo it.",
        "",
        "Each case runs `encode_host` on `source`. A case with `fails` set expects a",
        "rejection and its `expected` is empty. The rest expect exactly `expected`.",
        '"""',
        "",
        "comptime IDNA_CORPUS_SHA256 = StaticString(",
        f'    "{digest}"',
        ")",
        "",
        "",
        "struct IdnaCase(Copyable, Movable):",
        "    var source: String",
        "    var expected: String",
        "    var fails: Bool",
        "",
        "    def __init__(",
        "        out self,",
        "        source: StringSpan,",
        "        expected: StringSpan,",
        "        fails: Bool,",
        "    ):",
        "        self.source = String(source)",
        "        self.expected = String(expected)",
        "        self.fails = fails",
        "",
        "",
        "def idna_cases() -> List[IdnaCase]:",
        "    var out = List[IdnaCase]()",
    ]
    for case in cases:
        source = mojo_string(str(case["source"]))
        expected = mojo_string(str(case["expected"]))
        fails = "True" if case["fails"] else "False"
        lines.append(f"    out.append(IdnaCase({source}, {expected}, {fails}))")
    lines.append("    return out^")
    return formatted("\n".join(lines) + "\n", "idna_cases.mojo")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="report whether the fixture matches the vendored corpus",
    )
    args = parser.parse_args()

    path, digest = source_path_and_digest()
    if not path.exists():
        print(
            f"{path.relative_to(ROOT)} is missing."
            " Run `python tools/vendor/fetch.py --update`.",
            file=sys.stderr,
        )
        return 1
    found = hashlib.sha256(path.read_bytes()).hexdigest()
    if found != digest:
        print(
            "the vendored corpus does not match the lock. Run"
            " `pixi run vendor-check` first.",
            file=sys.stderr,
        )
        return 1

    cases = cases_from(path)
    rendered = render(cases, digest)

    if args.check:
        current = OUTPUT.read_text() if OUTPUT.exists() else ""
        if current != rendered:
            print(
                f"idna: {OUTPUT.relative_to(ROOT)} is out of date."
                " Run `pixi run python tools/gen_idna_cases.py`.",
                file=sys.stderr,
            )
            return 1
        print(f"idna: ok, {len(cases)} cases match the vendored corpus")
        return 0

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(rendered)
    print(f"idna: wrote {len(cases)} cases to {OUTPUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
