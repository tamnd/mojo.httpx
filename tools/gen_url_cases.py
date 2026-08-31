"""Turn the WHATWG URL corpus into a Mojo fixture.

    pixi run python tools/gen_url_cases.py          rewrite the fixture
    pixi run python tools/gen_url_cases.py --check  fail if it is out of date

Only the http and https cases are compiled in. The corpus covers the whole
WHATWG parser, including `file:`, `javascript:`, blob URLs and every other
scheme a browser knows, and this library speaks two. A `file:` case that fails
here would say nothing about anything a request could be sent to.

`URL` is an RFC 3986 parser with the normalization rules in Spec/03-url.md, not
a WHATWG parser, so it is not going to agree with all of these and is not meant
to. What matters is that every disagreement is one somebody looked at. Cases we
knowingly answer differently carry a `divergence` note saying why, and the test
asserts they still diverge, so the note has to be deleted when the behaviour
changes rather than sitting there describing something that stopped being true.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import tomllib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from mojogen import formatted, mojo_string

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "tests" / "data" / "LOCK.toml"
OUTPUT = ROOT / "tests" / "fixtures" / "url_cases.mojo"

SPECIAL = ("http:", "https:")


def source_path_and_digest() -> tuple[Path, str]:
    with LOCK.open("rb") as handle:
        locked = tomllib.load(handle)["file"]["whatwg-url"]
    return ROOT / locked["path"], locked["sha256"]


def scheme_of(text: str) -> str:
    """The scheme a string starts with, lowercased and with its colon.

    Deliberately crude. It is only used to decide whether a case is about a
    scheme this library speaks, and a string too malformed to get a scheme out
    of is a string whose scheme is not http.
    """
    for index, char in enumerate(text):
        if char == ":":
            return text[: index + 1].lower()
        if not (char.isalnum() or char in "+-."):
            return ""
    return ""


def relevant(case: dict[str, object]) -> bool:
    base = case["base"]
    if base is not None and scheme_of(base) not in SPECIAL:
        return False
    if case.get("failure"):
        # A failure with no base has to name its own scheme to be ours. With a
        # base, the reference is relative and inherits it, so it counts.
        return base is not None or scheme_of(str(case["input"])) in SPECIAL
    return case.get("protocol") in SPECIAL


def cases_from(path: Path) -> list[dict[str, object]]:
    out: list[dict[str, object]] = []
    for case in json.loads(path.read_text(encoding="utf-8")):
        if isinstance(case, str):
            # Section headings. The corpus uses bare strings as comments.
            continue
        if "relativeTo" in case:
            # These exercise a browser API for resolving against a document
            # rather than a base URL, which has no counterpart here.
            continue
        if not relevant(case):
            continue
        base = case["base"]
        out.append(
            {
                "input": case["input"],
                "base": "" if base is None else base,
                "failure": bool(case.get("failure")),
                "href": "" if case.get("failure") else case["href"],
                "divergence": divergence_for(case),
            }
        )
    return out


def divergence_for(case: dict[str, object]) -> str:
    """The note for a case we knowingly answer differently, or an empty string.

    Exact cases win over rules, so a family that mostly comes down to one rule
    can still have a member that is here for its own reason.
    """
    key = (case["base"] or "", case["input"])
    if key in DIVERGENCES:
        MATCHED.add(key)
        return DIVERGENCES[key]
    for matches, reason in DIVERGENCE_RULES:
        if matches(case):
            return reason
    return ""


MATCHED: set[tuple[str, str]] = set()
"""Which exact cases were found, so a key that names no case can be reported.

A key that matches nothing is a note about a case that is not in the corpus,
usually because it was reworded upstream. It reads like a documented divergence
and behaves like a comment, which is the worst of both.
"""

UNRESERVED = set(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
)
HEX = set("0123456789abcdefABCDEF")
STRIPPED = "".join(chr(code) for code in range(0x21))


def starts_with_an_empty_authority(case: dict[str, object]) -> bool:
    text = str(case["input"])
    return text.startswith("//") and len(text) > 2 and text[2] in "/\\"


def has_a_backslash(case: dict[str, object]) -> bool:
    return "\\" in str(case["input"])


def is_scheme_relative(case: dict[str, object]) -> bool:
    text = str(case["input"])
    scheme = scheme_of(text)
    return scheme in SPECIAL and not text.lower().startswith(scheme + "//")


def has_bytes_whatwg_deletes(case: dict[str, object]) -> bool:
    if case.get("failure"):
        # Something the corpus expects to be rejected is rejected here too, for
        # whatever else is wrong with it, so what the stripping would have done
        # never gets to show.
        return False
    text = str(case["input"])
    if any(char in text for char in "\t\n\r"):
        return True
    return text != text.strip(STRIPPED)


def after_authority(text: str) -> str:
    """The path, query and fragment of `text`, with the front cut off.

    Escapes in a host go through IDNA or the address parsers, which decode
    first and so land in the same place either way. It is only the parts that
    are kept as written where the spelling shows in the output.
    """
    rest = text[len(scheme_of(text)) :]
    if not rest.startswith("//"):
        return rest
    for index in range(2, len(rest)):
        if rest[index] in "/?#":
            return rest[index:]
    return ""


def percent_decoded(text: str) -> str:
    out = []
    index = 0
    while index < len(text):
        pair = text[index + 1 : index + 3]
        if text[index] == "%" and len(pair) == 2 and set(pair) <= HEX:
            out.append(chr(int(pair, 16)))
            index += 3
        else:
            out.append(text[index])
            index += 1
    return "".join(out)


def has_a_rewritten_escape(text: str) -> bool:
    for index, char in enumerate(text):
        if char != "%":
            continue
        pair = text[index + 1 : index + 3]
        if len(pair) < 2 or not set(pair) <= HEX:
            return True
        if pair != pair.upper() or chr(int(pair, 16)) in UNRESERVED:
            return True
    return False


def rewrites_an_escape(case: dict[str, object]) -> bool:
    """Whether normalizing percent encoding would change what comes out."""
    rest = after_authority(str(case["input"]))
    cut = len(rest)
    for index, char in enumerate(rest):
        if char in "?#":
            cut = index
            break
    for segment in rest[:cut].split("/"):
        # A segment that decodes to a dot segment is removed by both standards,
        # so how it was spelled never reaches the output and there is nothing
        # to disagree about.
        if percent_decoded(segment) in (".", ".."):
            continue
        if has_a_rewritten_escape(segment):
            return True
    return has_a_rewritten_escape(rest[cut:])


DIVERGENCE_RULES: list[tuple[object, str]] = [
    (
        starts_with_an_empty_authority,
        "an http url has to name a host, so this is rejected. WHATWG keeps"
        " reading past the empty authority and takes the first non empty path"
        " segment as the host instead.",
    ),
    (
        has_a_backslash,
        "a backslash is an ordinary path character here and is encoded as %5C."
        " WHATWG reads it as a path separator for http and https.",
    ),
    (
        is_scheme_relative,
        "a reference that names its own scheme is absolute, so the part after"
        " the colon is its path. WHATWG resolves http:x against the base and"
        " forces an authority on to the result.",
    ),
    (
        has_bytes_whatwg_deletes,
        "WHATWG deletes tabs and newlines from anywhere in the input and trims"
        " leading and trailing control characters and spaces. Nothing is"
        " deleted here, because two readers that disagree about which bytes are"
        " part of a url disagree about where the request goes.",
    ),
    (
        rewrites_an_escape,
        "RFC 3986 section 6.2.2 normalizes percent encoding, so escapes of"
        " unreserved characters are decoded, the rest are uppercased, and a"
        " percent that is not followed by two hex digits is an error. WHATWG"
        " keeps whatever was written.",
    ),
]

EMPTY_LABEL = (
    "a name with an empty label in it is rejected, because no resolver answers"
    " one and `a..b` reads as one host to a person and as two to a resolver."
    " WHATWG turns VerifyDnsLength off, which allows the empty label along with"
    " names over the DNS length limits."
)

ACE = (
    "a label that starts with xn-- has to decode to something UTS-46 would have"
    " produced, and this one does not, so it is rejected rather than passed"
    " through. WHATWG keeps the label as written when the decode is not usable,"
    " which sends a name to DNS that no conforming encoder would have written."
)

ENCODE_SET = (
    "the set of characters escaped in each part of the url follows RFC 3986"
    " rather than the WHATWG encode sets, which differ over a handful of"
    " characters that neither standard reserves."
)

DIVERGENCES: dict[tuple[str, str], str] = {
    ("", "http://./"): EMPTY_LABEL,
    ("", "http://../"): EMPTY_LABEL,
    ("", "http://foo.09.."): EMPTY_LABEL,
    ("", "http://a.b.c.xn--pokxncvks"): ACE,
    ("", "http://10.0.0.xn--pokxncvks"): ACE,
    ("", "http://a.b.c.XN--pokxncvks"): ACE,
    ("", "http://a.b.c.Xn--pokxncvks"): ACE,
    ("", "http://10.0.0.XN--pokxncvks"): ACE,
    ("", "http://10.0.0.xN--pokxncvks"): ACE,
    ("", "https://xn--/"): ACE,
    ("http://example.org/foo/bar", "http://foo/path;a??e#f#g"): ENCODE_SET,
    ("http://example.org/foo/bar", "[61:24:74]:98"): ENCODE_SET,
    ("http://doesnotmatter/", "http://`{}:`{}@h/`{}?`{}"): ENCODE_SET,
    ("", "http://host/?'"): ENCODE_SET,
    (
        "",
        "https://www.example.com/path{\x7fpath.html?query'\x7f=query#"
        "fragment<\x7ffragment",
    ): ENCODE_SET,
    (
        "",
        "http://!\"$&'()*+,-.;=_`{}~/",
    ): "the characters a host may contain follow RFC 3986, which reserves the"
    " sub delimiters for a use a host does not have, so a host built out of"
    " them is rejected. WHATWG allows everything that is not on its own list"
    " of forbidden host code points.",
}


def render(cases: list[dict[str, object]], digest: str) -> str:
    lines = [
        '"""URL conformance cases, compiled from the WHATWG corpus.',
        "",
        "Generated by tools/gen_url_cases.py from tests/data/url/urltestdata.json.",
        "Do not edit. Run `pixi run python tools/gen_url_cases.py` to redo it.",
        "",
        "Only the http and https cases are here. `base` is empty when the case parses",
        "`input` on its own, and set when it resolves `input` against it. `failure`",
        "means the corpus expects the parse to be rejected, and `divergence` is a note",
        "saying why this library deliberately answers differently.",
        '"""',
        "",
        "comptime URL_CORPUS_SHA256 = StaticString(",
        f'    "{digest}"',
        ")",
        "",
        "",
        "struct UrlCase(Copyable, Movable):",
        "    var input: String",
        "    var base: String",
        "    var failure: Bool",
        "    var href: String",
        "    var divergence: String",
        "",
        "    def __init__(",
        "        out self,",
        "        input: StringSpan,",
        "        base: StringSpan,",
        "        failure: Bool,",
        "        href: StringSpan,",
        "        divergence: StringSpan,",
        "    ):",
        "        self.input = String(input)",
        "        self.base = String(base)",
        "        self.failure = failure",
        "        self.href = String(href)",
        "        self.divergence = String(divergence)",
        "",
        "",
        "def url_cases() -> List[UrlCase]:",
        "    var out = List[UrlCase]()",
    ]
    for case in cases:
        lines.append("    out.append(")
        lines.append("        UrlCase(")
        lines.append(f"            {mojo_string(case['input'])},")
        lines.append(f"            {mojo_string(case['base'])},")
        lines.append(f"            {case['failure']},")
        lines.append(f"            {mojo_string(case['href'])},")
        lines.append(f"            {mojo_string(case['divergence'])},")
        lines.append("        )")
        lines.append("    )")
    lines.append("    return out^")
    return formatted("\n".join(lines) + "\n", "url_cases.mojo")


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
    missing = sorted(set(DIVERGENCES) - MATCHED)
    if missing:
        for key in missing:
            print(f"urls: no case matches {key!r}", file=sys.stderr)
        return 1
    rendered = render(cases, digest)

    if args.check:
        current = OUTPUT.read_text() if OUTPUT.exists() else ""
        if current != rendered:
            print(
                f"urls: {OUTPUT.relative_to(ROOT)} is out of date."
                " Run `pixi run python tools/gen_url_cases.py`.",
                file=sys.stderr,
            )
            return 1
        print(f"urls: ok, {len(cases)} cases match the vendored corpus")
        return 0

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(rendered)
    print(f"urls: wrote {len(cases)} cases to {OUTPUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
