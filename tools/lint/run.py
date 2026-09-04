#!/usr/bin/env python3
"""Project specific lints for the httpx package.

Five rules, each of which exists because breaking it produces a bug that no
test would reliably catch.

Layering. The package is a stack, and a module may only import from its own
layer or below. An upward import compiles fine and looks harmless, and then a
year later the protocol layer cannot be tested without a socket because
something in it reached up into the client. See docs/architecture.md.

Unsafe operations. Raw pointers, bitcasts and calls into libc are confined to
the two lowest layers, and every site carries a comment saying what makes it
sound. The interesting failures at this level are silent memory corruption, and
the only defence that scales is keeping the surface small enough to read.

Deadlines. Every operation that can wait has to carry a deadline. A read with no
deadline is a client that hangs forever on a server that stops talking, and
there is no timeout anywhere else in the stack that will rescue it, because a
blocked thread is blocked. This is the rule most likely to be broken by
accident, because leaving the argument off always compiles.

Docstrings on the public surface. Every name `import httpx` hands out has to
carry a docstring, because the API reference is generated from those and a name
without one shows up in docs/api.md as a bare signature. Nothing about that
fails, which is the problem: the page still builds and still looks complete.

Examples on the exported types. A paragraph tells you what something is and an
example tells you how to make one, and the second question is the one somebody
arrives with. The example has to be a whole program so that `pixi run docex`
can hand it to the compiler, which is what keeps it true a year from now.

    pixi run lint
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "httpx"

# The layer of every module in the package, lowest first. A module may import
# from a layer less than or equal to its own and nothing else.
#
# The keys are path prefixes relative to httpx/, matched longest first. A module
# that matches nothing is an error rather than a default, so that adding a
# directory is a decision somebody made rather than one that happened.
LAYERS: dict[str, int] = {
    # Foundations. No dependencies beyond the standard library, so anything may
    # use them without creating a cycle.
    "_exceptions.mojo": 0,
    "_bytes.mojo": 0,
    "_util/": 0,
    # L0 in docs/architecture.md, split in two because the libc declarations are
    # worth isolating from the code that uses them.
    "_ffi/": 1,
    "_io/": 2,
    # Data types. No I/O, which is why they sit below the protocol layer rather
    # than beside the client that mostly uses them.
    "_models/": 3,
    # Beside the data types rather than under them. A content coding is undone
    # by the response, so the response has to be able to import it, and it
    # needs nothing above _ffi itself. Not put in with the I/O layers because
    # it holds no pointers and calls no syscalls, and being there would hand it
    # a latitude it has no use for.
    "_codec/": 3,
    "_content/": 4,
    # L1 to L5.
    "_stream/": 5,
    "_proto/": 6,
    "_pool/": 7,
    "_transport/": 8,
    "_config.mojo": 9,
    "_auth.mojo": 9,
    "_redirects.mojo": 9,
    "_hooks.mojo": 9,
    "_client.mojo": 10,
    # Above the client rather than beside it. It is the client with its
    # transport parameter filled in, so it imports the client, and the client
    # must never learn that it exists.
    "_aio_client.mojo": 11,
    # L6, the public surface.
    "_api.mojo": 12,
    "__init__.mojo": 12,
    "cli/": 13,
}

# Only these layers may hold a raw pointer or call into C.
UNSAFE_LAYERS = {1, 2}

# And these three modules, none of which is I/O at all.
#
# _util/erase.mojo: storing a user's transport in a client means holding a value
# whose type has been forgotten, Mojo 1.0 has no trait objects, and the only way
# to do it is a pointer plus a function that remembers how to destroy what is on
# the end of it.
#
# _proto/h1/aio.mojo: a coroutine cannot return anything and cannot hold owned
# memory in its own frame, so every async driver reports its answer by writing
# through a pointer to a struct the caller owns. The pointers here are `Pointer`
# with an origin rather than raw addresses, so the compiler still checks the
# lifetimes; what the rule is really catching is that the file exists at all.
#
# _pool/aio_pool.mojo: the same reason as the driver, one level up. A pooled
# request has to run a connect and an exchange in one coroutine, because an
# awaited coroutine may not suspend in a loop, so the pool ends up holding the
# same shape the driver does and reporting through the same kind of pointer.
#
# Named file by file rather than opening up the whole layer, and every site in
# all three still has to carry its invariant like any other unsafe code.
UNSAFE_MODULES = {
    "_util/erase.mojo",
    "_proto/h1/aio.mojo",
    "_pool/aio_pool.mojo",
}

IMPORT_RE = re.compile(r"^\s*(?:from|import)\s+(httpx[\w.]*)", re.MULTILINE)

# Every construct that can corrupt memory if the invariant behind it is wrong.
UNSAFE_RE = re.compile(
    r"\bexternal_call\b|\bunsafe_\w+|\bPointer\s*[\[(]|\bCStringSlice\b|\bDLHandle\b"
)

# A wait that never returns. poll and its relatives treat a negative timeout as
# wait forever, which is the one value this library is never allowed to pass.
FOREVER_RE = re.compile(r"\b(?:poll|wait|select|kevent|epoll_wait)\s*\([^)]*-\s*1")

# Functions that block. In the I/O layer each one has to be reachable only from
# a caller that supplied a deadline.
BLOCKING_RE = re.compile(r"\b(?:poll|recv|send|connect_to|accept|resolve)\s*\(")

# `async def` counts. The async I/O layer is written entirely in coroutines, and
# a pattern that only matched `def` would have exempted every one of them from
# the deadline rule while still reporting success.
DEF_RE = re.compile(r"^(\s*)(?:async\s+)?def\s+(\w+)\s*\(")

# The same, for the cheap walk-back checks below that only need to know whether
# a line starts a definition.
HEADER_STARTS = ("def ", "async def ", "struct ")

# The same rule one storey up. Above the I/O layer nothing calls a syscall, but
# plenty of things drive a socket through a stream, run a whole exchange, or
# hand a request to a transport, and every one of those waits. A method that
# does any of it and was not given a deadline is a wait nobody can bound.
DRIVES_IO_RE = re.compile(
    r"\b(?:stream|sock|socket|conn|connection)\.(?:read|write)\s*\("
    r"|\.(?:exchange|handle_request)\s*\("
    r"|\bconnect_to_host\s*\("
)
DEADLINE_CALLER_LAYERS = {6, 7, 8}
"""Protocol, pool and transport. Not the client above them, which is where a
timeout is turned into deadlines and so is the one place allowed to start
without any."""


class Findings:
    def __init__(self) -> None:
        self.items: list[str] = []

    def add(self, path: Path, line: int, message: str) -> None:
        self.items.append(f"{path.relative_to(ROOT)}:{line}: {message}")

    def report(self, name: str) -> bool:
        if not self.items:
            print(f"{name}: ok")
            return True
        print(f"{name}: {len(self.items)} problem(s)")
        for item in sorted(self.items):
            print(f"  {item}")
        return False


def layer_of(path: Path) -> int | None:
    """The layer a module belongs to, or None if the table does not cover it."""
    relative = path.relative_to(PACKAGE).as_posix()
    best: tuple[int, int] | None = None
    for prefix, layer in LAYERS.items():
        if prefix.endswith("/"):
            matched = relative.startswith(prefix)
        else:
            matched = relative == prefix
        if matched and (best is None or len(prefix) > best[0]):
            best = (len(prefix), layer)
    return None if best is None else best[1]


def module_to_path(module: str) -> str:
    """`httpx._ffi.socket` to `_ffi/socket.mojo`, as the layer table spells it."""
    parts = module.split(".")[1:]
    return "/".join(parts) + ".mojo" if parts else "__init__.mojo"


def sources() -> list[Path]:
    return sorted(PACKAGE.rglob("*.mojo"))


def check_layering(files: list[Path]) -> bool:
    found = Findings()
    for path in files:
        own = layer_of(path)
        if own is None:
            found.add(
                path,
                1,
                "not covered by the layer table. Add it to LAYERS in "
                "tools/lint/run.py and say where it belongs.",
            )
            continue
        text = _without_examples(path.read_text())
        for match in IMPORT_RE.finditer(text):
            module = match.group(1)
            target = PACKAGE / module_to_path(module)
            other = layer_of(target) if target.parent.exists() else None
            if other is None:
                # A package import such as `from httpx._ffi import c` resolves
                # to a directory rather than a file. Fall back to the prefix.
                other = layer_of_module(module)
            line = text[: match.start()].count("\n") + 1
            if other is None:
                found.add(path, line, f"cannot place {module} in the layer table")
            elif other > own:
                found.add(
                    path,
                    line,
                    f"imports {module} from layer {other}, which is above "
                    f"layer {own}. Dependencies point downwards only.",
                )
    return found.report("layering")


def layer_of_module(module: str) -> int | None:
    relative = module_to_path(module)
    best: tuple[int, int] | None = None
    for prefix, layer in LAYERS.items():
        if relative.startswith(prefix.rstrip("/")):
            if best is None or len(prefix) > best[0]:
                best = (len(prefix), layer)
    return None if best is None else best[1]


def justified(lines: list[str], index: int) -> bool:
    """True when something nearby explains this line.

    Normally that means a comment or a docstring within the fifteen lines above,
    which in practice is the enclosing function's docstring or a note written
    directly over the call. Deliberately crude: the point is to make writing an
    unexplained pointer operation take more effort than explaining it.

    A signature is the exception, because its documentation comes after it
    rather than before, and the formatter splits a long signature across several
    lines so the pointer type often ends up on a line of its own. For those the
    docstring below counts.

    The search below a signature runs to the end of the parameter list rather
    than a fixed few lines. An async driver takes three pointers and two
    deadlines and its closing bracket is nine lines down, and a first parameter
    that fell outside the window was being asked to justify itself separately
    from the docstring that already does.
    """
    if in_signature(lines, index):
        for offset in range(0, 12):
            position = index + offset
            if position < len(lines) and '"""' in lines[position]:
                return True
        return False

    for offset in range(1, 16):
        position = index - offset
        if position < 0:
            return False
        stripped = lines[position].strip()
        if stripped.startswith("#") or '"""' in stripped:
            return True
        if stripped.startswith(HEADER_STARTS):
            return False
    return False


def in_signature(lines: list[str], index: int) -> bool:
    """True when this line is part of a `def`, `async def` or `struct` header.

    Found by walking back to the nearest one and checking that the header has
    not already been closed by a line ending in a colon.
    """
    for position in range(index, max(index - 8, -1), -1):
        stripped = lines[position].strip()
        if stripped.startswith(HEADER_STARTS):
            for cursor in range(position, index):
                if lines[cursor].rstrip().endswith(":"):
                    return False
            return True
        if position < index and stripped.rstrip().endswith(":"):
            return False
    return False


def check_unsafe(files: list[Path]) -> bool:
    found = Findings()
    for path in files:
        layer = layer_of(path)
        module = path.relative_to(PACKAGE).as_posix()
        allowed = layer in UNSAFE_LAYERS or module in UNSAFE_MODULES
        lines = _without_examples(path.read_text()).splitlines()
        for index, line in enumerate(lines):
            if line.lstrip().startswith("#"):
                continue
            match = UNSAFE_RE.search(line)
            if not match:
                continue
            if not allowed and not _is_signature_use(line):
                found.add(
                    path,
                    index + 1,
                    f"{match.group(0)!r} outside the I/O layers. Raw pointers "
                    "and calls into C belong in httpx/_ffi or httpx/_io, or "
                    "in a module named in UNSAFE_MODULES.",
                )
            elif not justified(lines, index):
                found.add(
                    path,
                    index + 1,
                    f"{match.group(0)!r} with nothing above it saying why it "
                    "is sound. Every unsafe site carries its invariant.",
                )
    return found.report("unsafe")


def _is_signature_use(line: str) -> bool:
    """Allow the safe wrappers that merely name an unsafe type in a signature.

    `Span(unsafe_ptr=...)` is a use. `def f(s: Span[UInt8, o])` is not, and
    neither is a docstring line quoting one. Only the higher layers get this
    latitude, and only for names, never for calls.
    """
    return "unsafe_from_utf8" in line and "=" in line


def check_deadlines(files: list[Path]) -> bool:
    found = Findings()
    for path in files:
        layer = layer_of(path)
        text = _without_examples(path.read_text())
        lines = text.splitlines()
        for index, line in enumerate(lines):
            if line.lstrip().startswith("#"):
                continue
            if FOREVER_RE.search(line):
                found.add(
                    path,
                    index + 1,
                    "a negative timeout means wait forever. Every wait in this "
                    "library carries a deadline.",
                )
            if "sleep(" in line and "_ffi" not in path.as_posix():
                found.add(
                    path,
                    index + 1,
                    "sleeping in the request path. Wait on the event loop with "
                    "a deadline instead.",
                )

        # In the I/O layer, a function that blocks has to have been given a
        # deadline to block until. The layers below it are the raw syscalls,
        # which do not wait, and the layers above go through the I/O layer.
        if layer == 2:
            for name, signature, start, end in _functions(lines):
                if name.startswith("_raw_"):
                    continue
                body = "\n".join(lines[start:end])
                if BLOCKING_RE.search(body) and "deadline" not in signature:
                    found.add(
                        path,
                        start,
                        f"{name} can block but takes no deadline. Add one, or "
                        f"rename it _raw_{name} if it genuinely cannot wait.",
                    )

        # Above the I/O layer the wait happens through somebody else, but it is
        # still a wait, so whoever starts it still has to have been handed a
        # deadline. Methods count here, which is why this walks every `def`
        # rather than only the top level ones.
        if layer in DEADLINE_CALLER_LAYERS:
            for name, signature, start, end in _all_functions(lines):
                body = "\n".join(lines[start:end])
                if DRIVES_IO_RE.search(body) and "deadline" not in signature.lower():
                    found.add(
                        path,
                        start,
                        f"{name} drives a socket but takes no deadline. Pass "
                        "one in from the caller that knows the budget.",
                    )
    return found.report("deadlines")


# The public surface is exactly what `httpx/__init__.mojo` re-exports, so that
# is what the docstring rule is measured against. Anything else in the package
# is internal and documented for whoever is reading the source, which is a lower
# bar and not one a lint can judge.
INIT = "__init__.mojo"

# `from httpx._models.url import URL, QueryParams`, with the name list possibly
# parenthesised and running over several lines. The body is chopped up
# afterwards rather than matched precisely, because a regex that tried to spell
# the whole thing would be longer than the function that reads it.
EXPORT_RE = re.compile(
    r"^from[ \t]+(httpx[\w.]*)[ \t]+import[ \t]+([^\n]*(?:\n[ \t]+[^\n]*)*)", re.M
)
ALIAS_RE = re.compile(r"^comptime\s+(\w+)\s*=", re.M)

# `struct Mounts as MountTable` is not a thing, but `import Mounts as MountTable`
# is, so an export can be a rename and the docstring lives on the original.
RENAME_RE = re.compile(r"\b(\w+)\s+as\s+(\w+)\b")

DEFINITION_RE = re.compile(r"^(?:struct|trait)\s+(\w+)|^def\s+(\w+)|^comptime\s+(\w+)\s*=")

# An alias whose value starts with a type name, which is how `Client`, its async
# twin and the two mount tables are declared.
TYPE_ALIAS_RE = re.compile(r"^comptime\s+\w+\s*=\s*[A-Z]\w*")

# What an example looks like, and what makes it a program rather than a snippet.
# Both spellings have to agree with tools/docex/run.py, which is the thing that
# actually compiles them.
FENCE = "```mojo"
ENTRY = "def main("


def _without_prose(text: str) -> str:
    """The source with docstrings and comments removed.

    The import list is read out of this rather than the raw file, because the
    module docstring at the top of `__init__.mojo` is several hundred words of
    English and plenty of them look like identifiers.
    """
    text = re.sub(r'"""(?:.|\n)*?"""', "", text)
    return re.sub(r"(?m)#.*$", "", text)


def _without_examples(text: str) -> str:
    """The source with the inside of every ```mojo block blanked out.

    A docstring example is a program written from the outside, so it imports
    `httpx` and calls the public API, and every check here that reads a line at
    a time would otherwise see it as code in this file. The layering check is
    the loud one: `from httpx import Client` inside a transport docstring is an
    import from the top of the package into layer 8, which is exactly the thing
    it exists to refuse, and exactly what an example is supposed to look like.

    Blanked rather than dropped so that a finding still points at the line it is
    on.
    """
    out = []
    inside = False
    for line in text.split("\n"):
        stripped = line.strip()
        if inside:
            out.append("" if stripped != "```" else line)
            inside = stripped != "```"
        else:
            out.append(line)
            inside = stripped == "```mojo"
    return "\n".join(out)


def _is_public(name: str) -> bool:
    """Whether a re-exported name is part of the API.

    Mojo re-exports everything a package `__init__` imports, with no way to keep
    one out, so a name only needed to build something else is brought in under a
    leading underscore. `__version__` and anything else with two is public,
    because that is the spelling Python uses for exactly these.
    """
    return not name.startswith("_") or name.startswith("__")


def exported_names(files: list[Path]) -> dict[str, tuple[str, str]]:
    """Every name `import httpx` hands out, and where its definition lives.

    The key is what a caller writes. The value is the name it is declared under,
    which differs only for a rename, and the module it was imported from.

    The module matters because a rename can make two things share a name. Today
    `Mounts` is both a struct in `_transport/mounts.mojo`, exported as
    `MountTable`, and an alias in `__init__.mojo` for that struct with its
    parameter filled in. Looking either of them up by name alone finds whichever
    file sorts first and documents the wrong one.
    """
    out: dict[str, tuple[str, str]] = {}
    for path in files:
        if path.name != INIT or path.parent != PACKAGE:
            continue
        source = _without_prose(path.read_text())
        for match in EXPORT_RE.finditer(source):
            module, body = match.group(1), match.group(2)
            renamed = {new: old for old, new in RENAME_RE.findall(body)}
            for word in re.split(r"[,\s()]+", body):
                if not re.fullmatch(r"[A-Za-z_]\w*", word or "") or word == "as":
                    continue
                if word in renamed.values():
                    continue
                if not _is_public(word):
                    continue
                out[word] = (renamed.get(word, word), module)
        for match in ALIAS_RE.finditer(source):
            out[match.group(1)] = (match.group(1), "httpx")
    return out


def _definitions(files: list[Path]) -> dict[tuple[str, str], tuple[Path, int, list[str]]]:
    """Where every top level definition in the package is, by module and name."""
    out: dict[tuple[str, str], tuple[Path, int, list[str]]] = {}
    for path in files:
        module = path.relative_to(PACKAGE).as_posix()
        lines = path.read_text().splitlines()
        for index, line in enumerate(lines):
            match = DEFINITION_RE.match(line)
            if not match:
                continue
            name = match.group(1) or match.group(2) or match.group(3)
            out.setdefault((module, name), (path, index, lines))
    return out


def _find(
    definitions: dict[tuple[str, str], tuple[Path, int, list[str]]],
    declared: str,
    module: str,
) -> tuple[Path, int, list[str]] | None:
    """The definition an export points at.

    The module it was imported from is tried first. Falling back to any module
    covers a name that was re-exported once already on its way up, which is not
    something the package does today but is not worth failing over.
    """
    here = definitions.get((module_to_path(module), declared))
    if here is not None:
        return here
    for (_, name), where in definitions.items():
        if name == declared:
            return where
    return None


def _docstring_of(lines: list[str], index: int) -> str | None:
    """The docstring on the definition starting at `index`, or None.

    The header can run over many lines, so it is walked to the line that ends
    it: a closing colon for a `def`, `struct` or `trait`, and the first line for
    an alias, which has no body to open.
    """
    if lines[index].startswith("comptime"):
        cursor = index
    else:
        cursor = index
        while cursor < len(lines) and not lines[cursor].rstrip().endswith(":"):
            cursor += 1
        if cursor >= len(lines):
            return None
    cursor += 1
    while cursor < len(lines) and not lines[cursor].strip():
        cursor += 1
    if cursor >= len(lines) or not lines[cursor].strip().startswith('"""'):
        return None
    first = lines[cursor].strip()
    if first.endswith('"""') and len(first) > 3:
        return first
    out = [lines[cursor]]
    cursor += 1
    while cursor < len(lines):
        out.append(lines[cursor])
        if '"""' in lines[cursor]:
            break
        cursor += 1
    return "\n".join(out)


def _has_docstring(lines: list[str], index: int) -> bool:
    return _docstring_of(lines, index) is not None


def check_docstrings(files: list[Path]) -> bool:
    """Every exported name carries a docstring.

    Measured against the re-export list rather than against every public looking
    name in the package, because that list is the API and everything else is
    somebody's implementation detail that happens not to start with an
    underscore.
    """
    found = Findings()
    wanted = exported_names(files)
    if not wanted:
        return found.report("docstrings")
    definitions = _definitions(files)
    init = PACKAGE / INIT
    for public, (defined, module) in sorted(wanted.items()):
        where = _find(definitions, defined, module)
        if where is None:
            found.add(
                init,
                1,
                f"{public} is exported but nothing in the package defines it. "
                "A stale re-export compiles until somebody imports the name.",
            )
            continue
        path, index, lines = where
        if not _has_docstring(lines, index):
            found.add(
                path,
                index + 1,
                f"{public} is part of the public API and has no docstring. "
                "docs/api.md is generated from these, so it lands there as a "
                "bare signature.",
            )
    return found.report("docstrings")


def check_examples(files: list[Path]) -> bool:
    """Every exported type carries a compilable example.

    Types only, not every exported name. A type is what somebody looks up when
    they do not know how to build one, and the answer to that is a few lines of
    code and not a paragraph. The error predicates are the other end of it:
    twenty one of them differing by one word, where twenty one examples would
    say less than the one sentence each already has.

    A whole program rather than a snippet, because `pixi run docex` compiles
    these and a snippet cannot be compiled. It is also the more honest form. An
    example that leaves out the imports is one nobody has run.
    """
    found = Findings()
    wanted = exported_names(files)
    if not wanted:
        return found.report("examples")
    definitions = _definitions(files)
    for public, (defined, module) in sorted(wanted.items()):
        where = _find(definitions, defined, module)
        if where is None:
            continue
        path, index, lines = where
        if not _is_type(lines[index]):
            continue
        docstring = _docstring_of(lines, index) or ""
        if FENCE not in docstring:
            found.add(
                path,
                index + 1,
                f"{public} is an exported type with no example. Put a ```mojo "
                "block in its docstring showing how to make one.",
            )
        elif ENTRY not in docstring:
            found.add(
                path,
                index + 1,
                f"the example on {public} is a fragment rather than a program. "
                "Give it a `def main` so pixi run docex can compile it.",
            )
    return found.report("examples")


def _is_type(line: str) -> bool:
    """Whether a definition line declares a type.

    An alias counts when its right hand side starts with a type name, which is
    how `Client` and `Mounts` are declared. `MOJO_MIN_VERSION` is an alias too
    and is not a type, and telling them apart by the shape of the value is
    enough here and does not need the compiler.
    """
    return line.startswith(("struct ", "trait ")) or bool(TYPE_ALIAS_RE.match(line))


def _functions(lines: list[str]) -> list[tuple[str, str, int, int]]:
    """Every top level `def`, as (name, signature, first body line, end)."""
    return _defs(lines, top_level_only=True)


def _all_functions(lines: list[str]) -> list[tuple[str, str, int, int]]:
    """Every `def`, methods and nested ones included.

    A definition ends where the next one begins, whatever the indentation, so a
    nested function's body is attributed to the nested function and not also to
    the one around it. Otherwise a shim that only builds a closure would be
    blamed for what the closure does.
    """
    return _defs(lines, top_level_only=False)


def _defs(
    lines: list[str], top_level_only: bool
) -> list[tuple[str, str, int, int]]:
    out = []
    starts = []
    for index, line in enumerate(lines):
        match = DEF_RE.match(line)
        if match and (not top_level_only or match.group(1) == ""):
            starts.append((index, match.group(2)))
    for position, (index, name) in enumerate(starts):
        end = starts[position + 1][0] if position + 1 < len(starts) else len(lines)
        signature = ""
        cursor = index
        while cursor < end:
            signature += lines[cursor]
            if lines[cursor].rstrip().endswith(":"):
                break
            cursor += 1
        out.append((name, signature, cursor + 1, end))
    return out


# The selftest below is not decoration. A lint that has silently stopped
# matching anything reports success forever and is worse than no lint, because
# the green result is taken as evidence. Each case here is a violation the
# corresponding check must still catch.
SELFTEST_CASES = [
    (
        "_ffi/bad_import.mojo",
        "from httpx._client import Client\n",
        check_layering,
    ),
    (
        "_models/bad_pointer.mojo",
        "def f():\n    var p = Pointer(to=x)\n",
        check_unsafe,
    ),
    (
        "_ffi/bare_call.mojo",
        "def f():\n    return external_call[\"read\", Int](0)\n",
        check_unsafe,
    ),
    (
        # A signature is allowed to be explained by the docstring below it
        # rather than a comment above. Without one it is still a violation.
        "_ffi/split_signature.mojo",
        "def f[\n    o: ImmOrigin\n](p: Pointer[UInt8, o]) -> Int:\n    return 0\n",
        check_unsafe,
    ),
    (
        "_io/forever.mojo",
        '"""m."""\n\n\ndef wait_ready(fd: Int) -> Int:\n'
        "    # No deadline anywhere.\n"
        "    return poll(fd, 1, -1)\n",
        check_deadlines,
    ),
    (
        "_io/no_deadline.mojo",
        '"""m."""\n\n\ndef read_some(fd: Int) -> Int:\n'
        "    # Blocks with nothing to stop it.\n"
        "    return recv(fd, 0, 0, 0)\n",
        check_deadlines,
    ),
    (
        # A coroutine blocks the same way a plain function does, and the async
        # I/O layer is nothing but coroutines, so the deadline rule has to see
        # through `async def` as well.
        "_io/async_no_deadline.mojo",
        '"""m."""\n\n\nasync def read_some(fd: Int) -> Int:\n'
        "    # Blocks with nothing to stop it.\n"
        "    return recv(fd, 0, 0, 0)\n",
        check_deadlines,
    ),
    (
        # A method one layer up that drives a socket with no budget for it.
        "_pool/leaky.mojo",
        '"""m."""\n\n\nstruct P:\n    def send(mut self, body: Span[UInt8]):\n'
        "        self.stream.write(body)\n",
        check_deadlines,
    ),
    (
        "_newthing/mystery.mojo",
        '"""m."""\n',
        check_layering,
    ),
    (
        # An alias exported straight out of `__init__.mojo` with nothing under
        # it. The whole file is the case, because the export list and the
        # definition are both in it.
        "__init__.mojo",
        '"""m."""\n\ncomptime Undocumented = 1\n',
        check_docstrings,
    ),
    (
        # A re-export that no longer resolves. This compiles until somebody
        # writes `httpx.Ghost`, and then fails in their code rather than ours.
        "__init__.mojo",
        '"""m."""\n\nfrom httpx._models.ghost import Ghost\n',
        check_docstrings,
    ),
    (
        # An exported type documented in prose and nothing else.
        "__init__.mojo",
        '"""m."""\n\ncomptime Widget = Gadget\n"""A widget."""\n',
        check_examples,
    ),
    (
        # And one whose example is a snippet, which reads like an example and
        # cannot be compiled, so nothing would ever tell anyone it had rotted.
        "__init__.mojo",
        '"""m."""\n\ncomptime Widget = Gadget\n"""A widget.\n\n'
        "```mojo\nvar w = Widget()\n```\n"
        '"""\n',
        check_examples,
    ),
]


def selftest() -> int:
    """Check that each lint still fires on a violation it is meant to catch."""
    import tempfile

    global ROOT, PACKAGE
    failures = 0
    for relative, body, check in SELFTEST_CASES:
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            package = root / "httpx"
            path = package / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body)
            saved = (ROOT, PACKAGE)
            ROOT, PACKAGE = root, package
            try:
                passed = check([path])
            finally:
                ROOT, PACKAGE = saved
        if passed:
            print(f"selftest: {check.__name__} did not catch {relative}")
            failures += 1
    if failures:
        print(f"\nselftest failed: {failures} lint(s) have stopped working")
        return 1
    print(f"\nselftest passed: {len(SELFTEST_CASES)} violation(s) still caught")
    return 0


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    files = sources()
    if not files:
        print("no sources found under httpx/", file=sys.stderr)
        return 2
    print(f"linting {len(files)} file(s)\n")
    results = [
        check_layering(files),
        check_unsafe(files),
        check_deadlines(files),
        check_docstrings(files),
        check_examples(files),
    ]
    print("")
    if all(results):
        print("all lints passed")
        return 0
    print("lint failed")
    return 1


if __name__ == "__main__":
    sys.exit(main())
