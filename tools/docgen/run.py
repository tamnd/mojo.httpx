"""The API reference, rendered from what the compiler knows about the code.

`mojo doc` reads a source tree and writes out every declaration with its
docstring attached. This turns that JSON into `docs/api.md`, so the reference is
the code rather than a second description of it that drifts. A signature in this
page is the signature the compiler saw.

What counts as public is decided by `httpx/__init__.mojo` and nothing else. The
JSON has no idea which names are re-exported, and the import list in that file
is already the thing the library says is its surface, so it is read as a list
rather than guessed at from the underscore in a module name.

The page is grouped by what a reader is trying to do, and the groups are a table
in this file. There is no way to derive that order from the code, and the
alternative, one flat alphabetical list of ninety names, is a page people scroll
past. A public name missing from the table is an error rather than an appendix,
so adding an export makes somebody decide where it belongs.

Run it with `pixi run docs`. `pixi run docs-check` renders into memory and fails
when the checked in page is not what the code would produce now, which is what
keeps a rename from leaving the reference behind.
"""

import argparse
import json
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "httpx"
OUTPUT = ROOT / "docs" / "api.md"

# `mojo doc` refuses a `main()` inside a package, and the CLI has one. The
# command line client is documented in docs/cli.md as a program anyway, which is
# what somebody running it wants, so nothing is lost by leaving it out here.
SKIP_DIRS = {"cli"}

# Dunders that say nothing a reader of a reference needs. Lifecycle is the
# compiler's business, and `__ne__` is `__eq__` with a not in front of it.
SKIP_METHODS = {
    "__del__",
    "__copyinit__",
    "__moveinit__",
    "__merge_with__",
    "__ne__",
}

# The order of the page, and the only place that order exists. A name lands in
# the first group that claims it, and a public name in no group at all stops the
# render.
GROUPS = [
    (
        "Sending a request",
        "The top level functions. Each one opens a client, sends a single"
        " request and closes it again, which is the right shape for a script"
        " and the wrong one for a program that sends more than one.",
        [
            "request",
            "get",
            "head",
            "options",
            "post",
            "put",
            "patch",
            "delete",
            "stream",
        ],
    ),
    (
        "Clients",
        "A client holds the connection pool, the cookie jar and the"
        " configuration, so a program that sends more than one request should"
        " keep one and reuse it.",
        ["Client", "AsyncClient", "gather"],
    ),
    (
        "URLs",
        "A `URL` is parsed and normalized once, and every part of it is"
        " available both as text and as the bytes that went on the wire.",
        ["URL", "QueryParams"],
    ),
    (
        "Requests and responses",
        "What goes out and what comes back. A `Response` holds its body in"
        " memory unless it was made by `stream`, in which case it is read as it"
        " arrives.",
        [
            "Request",
            "Response",
            "Headers",
            "ByteChunks",
            "LineChunks",
            "TextChunks",
        ],
    ),
    (
        "Request bodies",
        "The ways of saying what to send. Text and bytes go as they are, a form"
        " is urlencoded, files are sent as multipart, and anything with a length"
        " that is not known ahead of time is chunked.",
        [
            "ByteSource",
            "ByteStream",
            "erase_source",
            "FileUpload",
            "MultipartData",
        ],
    ),
    (
        "JSON",
        "A parser and a value type, used for `json=` bodies and for"
        " `response.json()`.",
        ["Json", "JsonValue", "parse_json"],
    ),
    (
        "Cookies",
        "The jar a client keeps, and the rules a `Set-Cookie` header is held to"
        " before anything goes in it.",
        ["Cookies", "Cookie", "CookieJar", "SameSite"],
    ),
    (
        "Authentication",
        "A scheme puts credentials on a request, and may look at the response"
        " and send a second one. `AnyAuth` is the erased form the client stores,"
        " and the lowercase functions build it.",
        [
            "Auth",
            "AnyAuth",
            "erase_auth",
            "BasicAuth",
            "basic_auth",
            "DigestAuth",
            "digest_auth",
            "NetRCAuth",
            "netrc_auth",
            "NoAuth",
            "no_auth",
        ],
    ),
    (
        "Configuration",
        "What a client is given when it is built. Everything here has a default"
        " that is safe, so a client with no configuration at all is a client"
        " that verifies certificates and gives up eventually.",
        [
            "Timeout",
            "Deadline",
            "Deadlines",
            "Duration",
            "Limits",
            "SSLVerify",
            "ClientCert",
            "Proxy",
            "proxy_basic_auth",
            "DefaultEncoding",
        ],
    ),
    (
        "Transports",
        "The layer under the client, which turns a request into a response by"
        " whatever means. Replacing it is how tests avoid the network and how a"
        " program routes some hosts differently from others.",
        [
            "Transport",
            "AnyTransport",
            "erase_transport",
            "HTTPTransport",
            "AsyncTransport",
            "AnyAsyncTransport",
            "erase_async_transport",
            "AsyncHTTPTransport",
            "MockTransport",
            "MockRouter",
            "Route",
            "BlockedTransport",
            "blocked",
            "async_blocked",
            "MountTable",
            "Mounts",
            "AsyncMounts",
            "URLPattern",
        ],
    ),
    (
        "Event hooks",
        "Callbacks that run on the way out and on the way back, for logging and"
        " for the checks a program wants on every request it makes.",
        [
            "EventHooks",
            "RequestHook",
            "ResponseHook",
            "AnyRequestHook",
            "AnyResponseHook",
            "erase_request_hook",
            "erase_response_hook",
        ],
    ),
    (
        "Errors",
        "Mojo has one error type, so what would be a class hierarchy in Python"
        " is a kind on the error here. The predicates are httpx2's classes as"
        " questions you ask rather than types you catch, and they nest the same"
        " way: `is_timeout` is true for all four timeouts, `is_transport_error`"
        " for every network layer failure, `is_http_error` for anything raised"
        " for a request.",
        [
            "kind_of",
            "message_of",
            "ErrorKind",
            "is_http_error",
            "is_request_error",
            "is_transport_error",
            "is_timeout",
            "is_connect_timeout",
            "is_read_timeout",
            "is_write_timeout",
            "is_pool_timeout",
            "is_network_error",
            "is_connect_error",
            "is_protocol_error",
            "is_local_protocol_error",
            "is_remote_protocol_error",
            "is_proxy_error",
            "is_unsupported_protocol",
            "is_decoding_error",
            "is_too_many_redirects",
            "is_invalid_url",
            "is_status_error",
            "is_stream_error",
            "is_invalid_header",
            "is_invalid_argument",
            "is_cookie_conflict",
            "new_error",
        ],
    ),
    (
        "Utilities",
        "The small things that did not need a home of their own.",
        ["Link", "parse_links", "__version__", "MOJO_MIN_VERSION"],
    ),
]


def exports():
    """Every public name, mapped to the module and the name declared there.

    Parsed out of `httpx/__init__.mojo` rather than out of the doc JSON, because
    a re-export leaves no trace in the JSON: the package shows the aliases it
    declares itself and nothing else. Reading the import list means this tool
    agrees with the file that decides the question.

    The two names come apart on `import Mounts as MountTable`, where the
    reference has to look the declaration up under one name and print it under
    the other.

    A leading underscore means the name is only there to build something else.
    Mojo re-exports whatever a package imports and gives no way to keep one out,
    so that spelling is how the file says a name is not part of the surface. Two
    underscores are public again, since `__version__` is.
    """
    source = (PACKAGE / "__init__.mojo").read_text()
    found = {}

    def add(text, module):
        for name in text.split(","):
            name = name.strip().strip("()")
            if not name:
                continue
            declared, _, exported = name.partition(" as ")
            public = (exported or declared).strip()
            if public.startswith("_") and not public.startswith("__"):
                continue
            found[public] = (module, declared.strip())

    module = None
    for line in source.splitlines():
        text = line.strip()
        if text.startswith("from httpx"):
            module = text.split()[1]
            rest = text.split(" import ", 1)[1]
            if rest == "(":
                continue
            add(rest, module)
            module = None
            continue
        if module is not None:
            if text == ")":
                module = None
            else:
                add(text, module)
            continue
        if text.startswith("comptime "):
            name = text.split()[1]
            found[name] = ("httpx", name)
    return found


def targets():
    """The paths to hand to `mojo doc`, one invocation each.

    A directory would be one invocation for the whole tree, except that `mojo
    doc` skips a package whose name starts with an underscore, and every module
    in this library starts with one. Passing each of them by hand is what gets
    them documented.
    """
    found = sorted(PACKAGE.glob("*.mojo"))
    for path in sorted(PACKAGE.iterdir()):
        if path.is_dir() and path.name not in SKIP_DIRS:
            found.append(path)
    return found


def document(path):
    """The doc JSON for one path, with the modules keyed by dotted name."""
    result = subprocess.run(
        ["mojo", "doc", "-I", str(ROOT), str(path)],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise SystemExit(f"mojo doc failed on {path}:\n{result.stderr}")
    found = {}
    collect(json.loads(result.stdout)["decl"], "httpx", found)
    return found


def collect(decl, prefix, found):
    if decl["kind"] == "module":
        name = prefix
        if decl["name"] != "__init__":
            name = f"{prefix}.{decl['name']}"
        found[name] = decl
        return
    prefix = prefix if decl["name"] == "httpx" else f"{prefix}.{decl['name']}"
    for module in decl.get("modules") or []:
        collect(module, prefix, found)
    for package in decl.get("packages") or []:
        collect(package, prefix, found)


def modules():
    """Every module in the library, keyed by its dotted name.

    The invocations are independent and each one is a compile, so they run
    together. On this laptop that is the difference between a minute and a few
    seconds, which decides whether the check belongs in `pixi run check`.
    """
    found = {}
    with ThreadPoolExecutor() as pool:
        for one in pool.map(document, targets()):
            found.update(one)
    return found


def declaration(module, name):
    for kind in ("structs", "traits", "functions", "aliases"):
        for decl in module.get(kind) or []:
            if decl["name"] == name:
                return decl
    return None


WIDTH = 79
"""Where a signature is broken over lines. The same width the Mojo formatter
uses on the source, so a signature here looks like the one in the file."""


def signature(overload):
    """The signature as it would be written, with `raises` put back.

    The JSON records raising as a flag and leaves it out of the rendered
    signature, which would have the reference claim that half the library cannot
    fail.
    """
    text = overload["signature"]
    if overload.get("raises"):
        if " -> " in text:
            head, tail = text.split(" -> ", 1)
            text = f"{head} raises -> {tail}"
        else:
            text = f"{text} raises"
    return wrap(text)


def wrap(text):
    """Break a long signature at its top level commas, one argument to a line.

    A client method takes sixteen keyword arguments and its signature is four
    hundred characters. On one line that is a horizontal scrollbar, and the
    reader has to drag it to find out whether the argument they want exists.
    Nesting is counted so that a default like `List[UInt8]()` or a tuple stays
    in one piece.
    """
    if len(text) <= WIDTH or "(" not in text:
        return text
    head, rest = text.split("(", 1)
    depth = 1
    args = []
    current = ""
    tail = ""
    for i, c in enumerate(rest):
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                args.append(current)
                tail = rest[i:]
                break
        if depth == 1 and c == ",":
            args.append(current)
            current = ""
            continue
        current += c
    lines = [f"{head}("]
    for arg in args:
        arg = arg.strip()
        if arg:
            lines.append(f"    {arg},")
    lines.append(tail)
    return "\n".join(lines)


def prose(out, decl, depth):
    summary = (decl.get("summary") or "").strip()
    description = (decl.get("description") or "").strip()
    if summary:
        out.append(summary)
        out.append("")
    if description:
        out.append(demote(description, depth))
        out.append("")


def demote(text, depth):
    """Push the headings inside a docstring below the heading it sits under.

    A long docstring here uses `##` for its own sections, which is the right
    level in the file it is in and the wrong one in a page where `##` is a group
    of the reference. The shallowest heading in the docstring is moved to one
    below the declaration and the rest keep their distance from it, so the
    structure the author wrote survives. Fenced blocks are left alone, since
    every comment in a Mojo example starts with the same character.
    """
    lines = text.splitlines()
    fenced = False
    levels = []
    for line in lines:
        if line.startswith("```"):
            fenced = not fenced
        elif not fenced and line.startswith("#"):
            levels.append(len(line) - len(line.lstrip("#")))
    if not levels:
        return text
    shift = depth + 1 - min(levels)
    fenced = False
    for i, line in enumerate(lines):
        if line.startswith("```"):
            fenced = not fenced
        elif not fenced and line.startswith("#"):
            level = len(line) - len(line.lstrip("#"))
            lines[i] = "#" * min(level + shift, 6) + line[level:]
    return "\n".join(lines)


def arguments(out, overload):
    """A table of the arguments, when the docstring said anything about them.

    Most of this library explains its arguments in prose, because an argument
    called `follow_redirects` documented as "whether to follow redirects" is a
    row that costs a reader time. So the table appears only where somebody wrote
    an `Args:` section, and the prose stands alone everywhere else.
    """
    args = [a for a in overload.get("args") or [] if a["name"] != "self"]
    if not any((a.get("description") or "").strip() for a in args):
        return
    out.append("| Argument | Type | What |")
    out.append("| --- | --- | --- |")
    for arg in args:
        described = " ".join((arg.get("description") or "").split())
        out.append(f"| `{arg['name']}` | `{arg['type']}` | {described} |")
    out.append("")


def function(out, decl, depth, owner="", exported=""):
    name = exported or decl["name"]
    if owner:
        name = f"{owner}.{decl['name']}"
    out.append(f"{'#' * depth} `{name}`")
    out.append("")
    for overload in decl["overloads"]:
        out.append("```mojo")
        # A constructor is static too, and saying so above every `__init__`
        # would be noise about something the syntax already makes obvious.
        if overload.get("isStatic") and not overload["name"].startswith("__"):
            out.append("@staticmethod")
        out.append(signature(overload))
        out.append("```")
        out.append("")
        prose(out, overload, depth)
        arguments(out, overload)
        raised = (overload.get("raisesDoc") or "").strip()
        if raised:
            out.append(f"Raises: {raised}")
            out.append("")
        returned = (overload.get("returns") or {}).get("doc", "").strip()
        if returned:
            out.append(f"Returns: {returned}")
            out.append("")


def fields(out, decl):
    """The public fields. Private ones are not in the JSON to begin with.

    The last column is dropped when no field has anything in it, because a
    column of empty cells reads as documentation that went missing rather than
    as four fields whose names say what they are.
    """
    shown = decl.get("fields") or []
    if not shown:
        return
    described = {
        f["name"]: " ".join((f.get("summary") or "").split()) for f in shown
    }
    if any(described.values()):
        out.append("| Field | Type | What |")
        out.append("| --- | --- | --- |")
        for field in shown:
            name = field["name"]
            out.append(f"| `{name}` | `{field['type']}` | {described[name]} |")
    else:
        out.append("| Field | Type |")
        out.append("| --- | --- |")
        for field in shown:
            out.append(f"| `{field['name']}` | `{field['type']}` |")
    out.append("")


def constants(out, decl, where):
    """The aliases a struct declares, which is how this library spells an enum.

    A table with the value in it, because `ErrorKind` and `SameSite` are read
    for their members and a bare list of eighteen names would leave a reader
    with no way to tell which of them is the ancestor of which.
    """
    shown = decl.get("aliases") or []
    if not shown:
        return
    described = {
        a["name"]: " ".join((a.get("summary") or "").split()) for a in shown
    }
    header = ["| Constant | Value |", "| --- | --- |"]
    if any(described.values()):
        header = ["| Constant | Value | What |", "| --- | --- | --- |"]
    out.extend(header)
    for alias in shown:
        value = written_value(where, alias["name"]) or alias.get("value", "")
        row = f"| `{alias['name']}` | `{value}` |"
        if any(described.values()):
            row += f" {described[alias['name']]} |"
        out.append(row)
    out.append("")


def composite(out, decl, depth, where, exported=""):
    """A struct or a trait, with its fields and its methods under it."""
    name = exported or decl["name"]
    out.append(f"{'#' * depth} `{name}`")
    out.append("")
    out.append("```mojo")
    out.append(decl.get("signature") or f"{decl['kind']} {decl['name']}")
    out.append("```")
    out.append("")
    if name != decl["name"]:
        out.append(
            f"Declared as `{decl['name']}` and exported under this name, so the"
            f" signature above says `{decl['name']}` and `httpx.{name}` is what"
            " you import."
        )
        out.append("")
    prose(out, decl, depth)
    fields(out, decl)
    constants(out, decl, where)
    for method in members(decl):
        function(out, method, depth + 1, name)


def members(decl):
    found = []
    for method in decl.get("functions") or []:
        if method["name"] in SKIP_METHODS:
            continue
        overloads = [o for o in method["overloads"] if not inherited(o)]
        if overloads:
            found.append({**method, "overloads": overloads})
    return found


def inherited(overload):
    """Whether this is a requirement of `Movable` or `Copyable` rather than
    something this type declares.

    A trait that inherits `Movable` picks up its move constructor, with the
    standard library's docstring on it, and it turns up in the JSON looking like
    a method somebody wrote. Every type in the library moves, so printing it
    would be one paragraph about the compiler on nearly every heading.
    """
    text = overload.get("signature", "")
    return "deinit move: Self" in text or "out self, *, other: Self" in text


def alias(out, decl, depth, where, module, known, expanded, exported=""):
    """An alias, followed through to the struct behind it when there is one.

    `Client` is `BaseClient[AnyTransport, _default_transport]` and `BaseClient`
    is not exported, so stopping at the alias would leave the reference with a
    line about the most used type in the library and none of its methods. The
    struct is bound at compile time to something a caller cannot name, which is
    the whole reason the alias exists, so its members are printed here under the
    name people actually type.
    """
    name = exported or decl["name"]
    out.append(f"{'#' * depth} `{name}`")
    out.append("")
    out.append("```mojo")
    out.append(alias_line(decl, where))
    out.append("```")
    out.append("")
    prose(out, decl, depth)

    behind = (written_value(where, decl["name"]) or "").split("[")[0].strip()
    target, home = find(known, module, behind) if behind else (None, None)
    home = home or where
    if target is None or target["kind"] not in ("struct", "trait"):
        return
    # `Client` and `AsyncClient` are the same struct with different parameters,
    # so the second one gets a pointer. A hundred methods printed twice would be
    # a page nobody scrolls through, and the reader who wants a method wants it
    # in one place.
    if behind in expanded:
        out.append(
            f"The same as `{expanded[behind]}` above, with an async transport"
            " behind it. Its members are listed there."
            if "Async" in name
            else f"The members are `{expanded[behind]}`'s, listed above."
        )
        out.append("")
        return
    expanded[behind] = name
    out.append(
        f"The members below are `{behind}`'s. It is bound at compile time and"
        " cannot be named on its own, so they are listed here."
    )
    out.append("")
    prose(out, target, depth)
    fields(out, target)
    constants(out, target, home)
    for method in members(target):
        function(out, method, depth + 1, name)


def find(known, module, name):
    """A declaration by name, in this module first and anywhere after that.

    `AsyncClient` is an alias in `httpx._aio_client` to a struct declared in
    `httpx._client`, so the module the alias is in does not always hold the
    thing it points at.
    """
    found = declaration(module, name)
    if found is not None:
        return found, None
    for where, other in known.items():
        found = declaration(other, name)
        if found is not None:
            return found, where
    return None, None


def written_value(where, name):
    """What the source says an alias is equal to, or nothing when it is not
    on one line.

    The JSON gives the value after the compiler has resolved it, and resolving
    it is exactly what makes it wrong to print. `MountTable[AnyTransport]` comes
    back as `Mounts[AnyTransport]`, naming a struct under a name nobody can
    import, and `ErrorKind(0x11100)` comes back as `ErrorKind(UInt32(69888))`,
    which throws away the nibble structure the docstring above it is explaining.
    What the file says is the form somebody could type.
    """
    parts = where.split(".")[1:]
    path = PACKAGE / "__init__.mojo"
    if parts:
        path = PACKAGE.joinpath(*parts).with_suffix(".mojo")
        if not path.exists():
            path = PACKAGE.joinpath(*parts) / "__init__.mojo"
    if not path.exists():
        return None
    start = f"comptime {name} = "
    for line in path.read_text().splitlines():
        text = line.strip()
        if text.startswith(start):
            value = text[len(start) :]
            # A value that runs on to the next line would be quoted as half of
            # itself, and the resolved one is at least whole.
            return value if value.count("(") == value.count(")") else None
    return None


def alias_line(decl, where):
    value = written_value(where, decl["name"]) or decl.get("value", "")
    return f"comptime {decl['name']} = {value}".rstrip(" =")


def slug(text):
    """GitHub's heading anchor. Lowercased, punctuation dropped, spaces
    hyphenated."""
    kept = [c for c in text.lower() if c.isalnum() or c in " -_"]
    return "".join(kept).strip().replace(" ", "-")


def anchors(lines):
    """Every heading in the page, mapped to the link that reaches it.

    The slugs collide. `## JSON` and `### Json` are both `json`, and so are the
    `request` function and the `Request` struct, and GitHub resolves that by
    numbering the later ones. Working the numbering out here rather than
    guessing at it is what keeps the contents from pointing at the wrong
    section, which is the failure nobody notices because a link that lands on
    the wrong heading still looks like it worked.
    """
    seen = {}
    found = {}
    fenced = False
    # Split first: a docstring arrives as one entry with its own newlines in it,
    # and a fence halfway through one of those has to count.
    for line in "\n".join(lines).splitlines():
        if line.startswith("```"):
            fenced = not fenced
            continue
        if fenced or not line.startswith("#"):
            continue
        text = line.lstrip("#").strip()
        base = slug(text)
        count = seen.get(base, 0)
        seen[base] = count + 1
        link = f"#{base}" if count == 0 else f"#{base}-{count}"
        found.setdefault(text, []).append(link)
    return found


def contents(found):
    """A list of everything on the page, at the top of it.

    Five thousand lines of reference with no way in is a page people search
    rather than read. One line per group, with every name in it, is small enough
    to stay out of the way and complete enough to answer "is there a `Link`
    type" without scrolling.
    """
    taken = {}

    def link(text):
        i = taken.get(text, 0)
        taken[text] = i + 1
        links = found.get(text) or []
        return links[i] if i < len(links) else ""

    out = ["## Contents", ""]
    for title, _, names in GROUPS:
        where = link(title)
        items = ", ".join(f"[`{n}`]({link(f'`{n}`')})" for n in names)
        out.append(f"[{title}]({where}): {items}")
        out.append("")
    return out


def render():
    public = exports()
    known = modules()
    placed = set()
    expanded = {}

    out = []
    for title, blurb, names in GROUPS:
        out.append(f"## {title}")
        out.append("")
        out.append(blurb)
        out.append("")
        for name in names:
            if name not in public:
                raise SystemExit(
                    f"docgen: `{name}` is in a group but is not exported by"
                    " httpx/__init__.mojo"
                )
            placed.add(name)
            where, declared = public[name]
            module = known.get(where)
            if module is None:
                raise SystemExit(f"docgen: no documentation for module {where}")
            decl = declaration(module, declared)
            if decl is None:
                raise SystemExit(f"docgen: {where} does not declare `{declared}`")
            if decl["kind"] == "function":
                function(out, decl, 3, exported=name)
            elif decl["kind"] == "alias":
                alias(
                    out, decl, 3, where, module, known, expanded, exported=name
                )
            else:
                composite(out, decl, 3, where, exported=name)

    missing = sorted(set(public) - placed)
    if missing:
        raise SystemExit(
            "docgen: exported but in no group in tools/docgen/run.py: "
            + ", ".join(missing)
        )

    # The contents comes last because the links in it have to know how many
    # headings share a slug, and that is only knowable once the page exists.
    out = (
        [
            "# API reference",
            "",
            "Every name `import httpx` gives you, with the signature the"
            " compiler saw and the docstring that is on it in the source. This"
            " page is generated by `pixi run docs` from `mojo doc` output, so a"
            " signature here is not a description of the code, it is the code."
            " Do not edit it by hand.",
            "",
            "A name that is not on this page is not public, whatever it is"
            " spelled like. The modules under `httpx` all begin with an"
            " underscore and are free to move.",
            "",
        ]
        + contents(anchors(["## Contents"] + out))
        + out
    )

    # A page of sections that each end in a blank line collects runs of them.
    text = "\n".join(out)
    while "\n\n\n" in text:
        text = text.replace("\n\n\n", "\n\n")
    return text.rstrip("\n") + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail when docs/api.md is not what the code would produce",
    )
    options = parser.parse_args()

    text = render()
    if not options.check:
        OUTPUT.write_text(text)
        print(f"docgen: wrote {OUTPUT.relative_to(ROOT)}")
        return 0

    current = OUTPUT.read_text() if OUTPUT.exists() else ""
    if current != text:
        print(
            f"{OUTPUT.relative_to(ROOT)} is out of date. Run `pixi run docs`.",
            file=sys.stderr,
        )
        return 1
    print(f"docgen: {OUTPUT.relative_to(ROOT)} is up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
