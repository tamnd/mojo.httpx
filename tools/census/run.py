"""The public API census: no exported name is missing from the test suite.

The public API is everything `httpx/__init__.mojo` re-exports, plus the fields,
methods and constants of the types it re-exports. This walks that surface and
fails when a name does not appear anywhere under `tests/`. A public name nobody
mentions in a test is a name whose behaviour is whatever the implementation
happens to do, and the semver promise in M9 is a promise about all of it and not
only about the parts somebody remembered to check.

What this proves is a floor and it is worth saying exactly where the floor is. A
name appearing in a test is not the same as that name being tested well: the
match is textual, so a method called `close` gets credit from any type with a
method of that name. What it does catch is the case that actually happens, which
is a method added to a public type and exercised only from inside the library,
or a name exported and then forgotten. Both of those are invisible to the
compiler and to the test suite, and neither shows up anywhere else.

Members with no name at a call site are outside the census rather than checked
with a weaker probe. `__eq__` is spelled `==`, `__len__` is `len(x)`, `write_to`
is `String(x)`, and a probe for those is a probe for punctuation that passes on
any file long enough. Counting them would raise the number the census reports
without raising what it knows, which is the wrong direction for a gate. They are
listed under `--all` so that the surface can still be read whole.

`SKIPPED` holds the names that are allowed to be missing, each with a reason,
and an entry that stops being missing fails the run the same way a missing name
does. That is the rule the parity suite uses for its accepted differences, for
the same reason: an allowance nobody has to justify again is how a gate quietly
stops gating.

Run it with `pixi run census`, and `pixi run census --all` to see the whole
surface rather than only the gaps.
"""

import argparse
import importlib.util
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TESTS = ROOT / "tests"

# The census needs the public surface, which is what the reference generator
# already works out: the export list out of `httpx/__init__.mojo` and the
# declarations out of `mojo doc`. Loading it by path rather than importing it
# keeps `tools/` a directory of programs rather than a package, which is what
# every other tool here assumes.
_spec = importlib.util.spec_from_file_location(
    "docgen", ROOT / "tools" / "docgen" / "run.py"
)
docgen = importlib.util.module_from_spec(_spec)
sys.modules["docgen"] = docgen
_spec.loader.exec_module(docgen)

# Names that are allowed to be missing, with the reason. Everything here has to
# still be missing on every run.
SKIPPED = {
    "SSLVerify.ca_path": (
        "a directory of hashed certificates, which OpenSSL only reads when it"
        " is laid out by c_rehash, so a test would be checking c_rehash"
    ),
    "SSLVerify.from_directory": (
        "the constructor for that field, untestable for the same reason"
    ),
}


def surface():
    """Every public name, as (kind, owner, name) rows.

    `kind` is one of export, method, field or const. An export is a name you can
    import; the rest are members of a type you can import, reached through a dot
    and therefore probed for as `.name`.
    """
    known = docgen.modules()
    rows = []
    for public, (where, declared) in sorted(docgen.exports().items()):
        module = known.get(where)
        decl = docgen.declaration(module, declared) if module else None
        if decl is None:
            raise SystemExit(f"census: {public} is exported but not declared")
        rows.append(("export", "", public))
        target = behind(known, module, where, decl)
        if target["kind"] not in ("struct", "trait"):
            continue
        for method in docgen.members(target):
            rows.append(("method", public, method["name"]))
        for field in target.get("fields") or []:
            rows.append(("field", public, field["name"]))
        for const in target.get("aliases") or []:
            rows.append(("const", public, const["name"]))
    return rows


def behind(known, module, where, decl):
    """The struct an alias points at, or the declaration itself.

    `Client` is an alias for a parameterized struct nobody can name, so stopping
    at the alias would leave the most used type in the library with no members in
    the census. This is the same step the reference generator takes to give that
    type a set of methods on the page.
    """
    if decl["kind"] != "alias":
        return decl
    value = docgen.written_value(where, decl["name"]) or ""
    name = value.split("[")[0].strip()
    if not name:
        return decl
    found, _ = docgen.find(known, module, name)
    if found is None or found["kind"] not in ("struct", "trait"):
        return decl
    return found


def by_syntax(kind, name):
    """Whether this member is reached by punctuation rather than by its name.

    A dunder is an operator, and `write_to` is what `String(x)` and `print(x)`
    call, so none of them appear in a test as the name written here. Searching
    for the syntax instead would be searching for `==` or `(`, which any file
    matches, so they are counted apart rather than counted wrong.
    """
    return kind == "method" and (name.startswith("__") or name == "write_to")


def sources():
    found = {}
    for path in sorted(TESTS.rglob("*.mojo")):
        found[path] = path.read_text()
    if not found:
        raise SystemExit("census: no test sources found under tests/")
    return found


def mentioned(text, kind, name):
    if kind == "export":
        return re.search(r"\b%s\b" % re.escape(name), text) is not None
    return re.search(r"\.%s\b" % re.escape(name), text) is not None


def census(rows, text):
    """Split the surface into what is covered, what is missing and what is not
    checkable by name."""
    covered, missing, uncheckable = [], [], []
    for kind, owner, name in rows:
        if by_syntax(kind, name):
            uncheckable.append((kind, owner, name))
        elif any(mentioned(one, kind, name) for one in text.values()):
            covered.append((kind, owner, name))
        else:
            missing.append((kind, owner, name))
    return covered, missing, uncheckable


def label(kind, owner, name):
    return name if kind == "export" else f"{owner}.{name}"


def report(rows, title):
    if not rows:
        return
    print(f"\n{title}")
    for kind, owner, name in rows:
        print("  %-7s %s" % (kind, label(kind, owner, name)))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument(
        "--all",
        action="store_true",
        help="print the whole surface, not only what is missing",
    )
    args = ap.parse_args()

    rows = surface()
    text = sources()
    covered, missing, uncheckable = census(rows, text)

    allowed = [one for one in missing if label(*one) in SKIPPED]
    missing = [one for one in missing if label(*one) not in SKIPPED]
    stale = sorted(
        set(SKIPPED) - {label(*one) for one in allowed}
    )

    if args.all:
        report(covered, "in the tests")
        report(uncheckable, "reached by syntax, so not checked by name")
        report(allowed, "allowed to be missing")

    report(missing, "not mentioned anywhere in tests/")
    if stale:
        print("\nallowed to be missing, but present now")
        for name in stale:
            print("  %s" % name)

    print(
        "\ncensus: %d public names, %d in the tests, %d reached by syntax,"
        " %d allowed, %d missing"
        % (
            len(rows),
            len(covered),
            len(uncheckable),
            len(allowed),
            len(missing),
        )
    )
    if missing or stale:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
