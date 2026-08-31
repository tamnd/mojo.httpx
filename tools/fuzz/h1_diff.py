#!/usr/bin/env python3
"""Differential fuzzing of the response parser against h11.

h11 is the reference. It is the parser httpx itself sits on, it has been read
by more people than this one ever will be, and it has spent years being pointed
at hostile input. So the cheapest way to find out whether this library's parser
is wrong is to ask h11 the same question and compare the answers.

The comparison is deliberately asymmetric. Being stricter than h11 is allowed
and is recorded but not a failure, because this parser rejects several things
h11 tolerates and rejecting them is the point. Being looser is a failure, every
time, with no allowlist: a response this parser accepts and h11 rejects is a
smuggling vector waiting for a proxy to disagree with it. Accepting the same
bytes and disagreeing about the status or the body is a failure too, for the
same reason.

Run it:

    pixi run -e fuzz fuzz
    pixi run -e fuzz fuzz --cases 20000 --seed 7

The cases are generated from a seed and the seed is printed, so a failure can
be reproduced exactly. Every failing case is printed as hex, which is what the
Mojo harness takes, so a case that found something can be dropped straight into
a test.
"""

from __future__ import annotations

import argparse
import os
import random
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import h11
except ImportError:  # pragma: no cover
    print(
        "h11 is not installed. Run this as `pixi run -e fuzz fuzz`.",
        file=sys.stderr,
    )
    raise SystemExit(2)

ROOT = Path(__file__).resolve().parents[2]
HARNESS = ROOT / "tools" / "fuzz" / "harness.mojo"

CRLF = b"\r\n"

STATUS_LINES = [
    b"HTTP/1.1 200 OK",
    b"HTTP/1.1 201 Created",
    b"HTTP/1.1 204 No Content",
    b"HTTP/1.1 304 Not Modified",
    b"HTTP/1.1 404 Not Found",
    b"HTTP/1.1 500 Internal Server Error",
    b"HTTP/1.0 200 OK",
    b"HTTP/1.1 200 ",
    b"HTTP/1.1 200",
    # Everything below here is malformed, and both parsers should say so.
    b"HTTP/1.1 20 OK",
    b"HTTP/1.1 2000 OK",
    b"HTTP/1.1 abc OK",
    b"HTTP/2.0 200 OK",
    b"HTTP/1.1  200 OK",
    b"HTTP/1.1\t200 OK",
    b"HTTP /1.1 200 OK",
    b"200 OK",
    b"HTTP/1.1 200 OK\x00",
    b"",
]

HEADER_SETS = [
    # Ordinary framings.
    [(b"Content-Length", b"5")],
    [(b"Content-Length", b"0")],
    [(b"Transfer-Encoding", b"chunked")],
    [(b"Content-Type", b"text/plain")],
    [(b"Content-Length", b"5"), (b"Content-Type", b"text/plain")],
    # The framing conflicts. RFC 9112 section 6.3 says reject, and this is
    # where request smuggling lives.
    [(b"Content-Length", b"5"), (b"Transfer-Encoding", b"chunked")],
    [(b"Content-Length", b"5"), (b"Content-Length", b"6")],
    [(b"Content-Length", b"5"), (b"Content-Length", b"5")],
    [(b"Content-Length", b"5, 6")],
    [(b"Transfer-Encoding", b"gzip, chunked")],
    [(b"Transfer-Encoding", b"chunked, gzip")],
    [(b"Transfer-Encoding", b"identity")],
    [(b"Transfer-Encoding", b"chunked"), (b"Transfer-Encoding", b"chunked")],
    # Values that are not numbers, or are numbers with something extra.
    [(b"Content-Length", b"-1")],
    [(b"Content-Length", b"+5")],
    [(b"Content-Length", b"5 ")],
    [(b"Content-Length", b" 5")],
    [(b"Content-Length", b"0x5")],
    [(b"Content-Length", b"five")],
    [(b"Content-Length", b"")],
    [(b"Content-Length", b"99999999999999999999999999")],
    # Field lines that are malformed in themselves.
    [(b"Content-Length ", b"5")],
    [(b"Content Length", b"5")],
    [(b"", b"5")],
    [(b"X-Test\x00", b"1")],
    [(b"X-Test", b"a\x00b")],
    [(b"X-Test", b"a\rb")],
    [(b"X-Test", b"caf\xc3\xa9")],
    [(b"X-Test", b"")],
    [(b"X-Test", b"   spaced   ")],
    # Connection handling, which decides whether a close ends the body.
    [(b"Connection", b"close")],
    [(b"Connection", b"keep-alive"), (b"Content-Length", b"5")],
]

BODIES = [
    b"",
    b"hello",
    b"hell",
    b"hello world",
    b"5\r\nhello\r\n0\r\n\r\n",
    b"5\r\nhello\r\n",
    b"0\r\n\r\n",
    b"0\r\nX-Trailer: yes\r\n\r\n",
    b"5;ext=1\r\nhello\r\n0\r\n\r\n",
    b"5 \r\nhello\r\n0\r\n\r\n",
    b"-5\r\nhello\r\n0\r\n\r\n",
    b"0x5\r\nhello\r\n0\r\n\r\n",
    b"5\r\nhello0\r\n\r\n",
    b"fffffffffffffffff\r\nhello\r\n0\r\n\r\n",
    b"\r\n",
]

METHODS = [b"GET", b"GET", b"GET", b"HEAD", b"POST"]

# Line endings, because a parser that accepts a bare newline where the standard
# says CRLF is one half of a smuggling pair.
TERMINATORS = [b"\r\n", b"\r\n", b"\r\n", b"\n"]


def generate(rng: random.Random) -> tuple[bytes, bytes]:
    """One case, as (method, response bytes)."""
    method = rng.choice(METHODS)
    status = rng.choice(STATUS_LINES)
    headers = list(rng.choice(HEADER_SETS))
    if rng.random() < 0.3:
        headers += list(rng.choice(HEADER_SETS))
    terminator = rng.choice(TERMINATORS)

    out = status + terminator
    for name, value in headers:
        out += name + b": " + value + terminator
    if rng.random() < 0.08:
        # An obsolete folded continuation line, which RFC 9112 section 5.2 says
        # a client must reject rather than unfold.
        out += b" folded\r\n"
    out += terminator
    out += rng.choice(BODIES)
    return method, mutate(out, rng)


def mutate(data: bytes, rng: random.Random) -> bytes:
    """Sometimes damage the bytes, the way a hostile peer would.

    Structured cases find the disagreements that come from reading the standard
    differently. Random damage finds the ones that come from a parser walking
    off the end of a buffer, which the structured cases never will because they
    are all well formed enough to reach the end.
    """
    roll = rng.random()
    if roll < 0.55 or not data:
        return data
    out = bytearray(data)
    if roll < 0.70:
        out[rng.randrange(len(out))] = rng.randrange(256)
    elif roll < 0.82:
        return bytes(out[: rng.randrange(len(out))])
    elif roll < 0.92:
        out.insert(rng.randrange(len(out) + 1), rng.randrange(256))
    else:
        del out[rng.randrange(len(out))]
    return bytes(out)


def h11_verdict(method: bytes, data: bytes) -> tuple[str, int | None, bytes]:
    """What h11 makes of one response, in the harness's own vocabulary."""
    conn = h11.Connection(our_role=h11.CLIENT)
    try:
        conn.send(
            h11.Request(
                method=method,
                target="/",
                headers=[("Host", "example.com")],
            )
        )
        conn.send(h11.EndOfMessage())
        conn.receive_data(data)
    except Exception:
        # A request h11 will not even send says nothing about the response, so
        # the case is not comparable rather than a disagreement.
        return ("SKIP", None, b"")

    status: int | None = None
    body = b""
    eof_sent = False
    while True:
        try:
            event = conn.next_event()
        except h11.RemoteProtocolError:
            return ("ERR", None, b"")
        except Exception:
            return ("SKIP", None, b"")
        if event is h11.NEED_DATA:
            if eof_sent:
                return ("INCOMPLETE", status, body)
            conn.receive_data(b"")
            eof_sent = True
            continue
        if isinstance(event, h11.InformationalResponse):
            continue
        if isinstance(event, h11.Response):
            status = event.status_code
            continue
        if isinstance(event, h11.Data):
            body += bytes(event.data)
            continue
        if isinstance(event, h11.EndOfMessage):
            return ("OK", status, body)
        if event is h11.PAUSED:
            return ("OK", status, body)
        return ("SKIP", status, body)


def parse_ours(line: str) -> tuple[str, int | None, bytes]:
    if line.startswith("OK "):
        parts = line.split(" ", 2)
        payload = parts[2].strip() if len(parts) > 2 else ""
        return ("OK", int(parts[1]), bytes.fromhex(payload))
    if line.startswith("INCOMPLETE"):
        return ("INCOMPLETE", None, b"")
    return ("ERR", None, b"")


def run_harness(cases: list[tuple[bytes, bytes]]) -> list[str]:
    """Put every case through the Mojo parser, in one process."""
    mojo = os.environ.get("MOJO") or shutil.which("mojo")
    if not mojo:
        launcher = Path.home() / ".pixi" / "bin" / "mojo"
        mojo = str(launcher) if launcher.exists() else ""
    if not mojo:
        print("mojo not found. Run this through pixi.", file=sys.stderr)
        raise SystemExit(2)

    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as handle:
        for method, data in cases:
            handle.write(f"{method.decode()} {data.hex()}\n")
        path = handle.name
    try:
        result = subprocess.run(
            [mojo, "run", "-I", str(ROOT), str(HARNESS), path],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
    finally:
        os.unlink(path)

    if result.returncode != 0:
        print(result.stdout[-4000:], file=sys.stderr)
        print(result.stderr[-4000:], file=sys.stderr)
        print("the harness did not run to completion", file=sys.stderr)
        raise SystemExit(2)
    return result.stdout.splitlines()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--cases", type=int, default=2000, help="how many to try")
    ap.add_argument("--seed", type=int, default=0, help="for reproducing a run")
    ap.add_argument(
        "--show",
        type=int,
        default=10,
        help="how many failing cases to print in full",
    )
    args = ap.parse_args()

    rng = random.Random(args.seed)
    cases = [generate(rng) for _ in range(args.cases)]
    print(f"seed {args.seed}, {len(cases)} case(s)")

    ours = run_harness(cases)
    if len(ours) != len(cases):
        print(
            f"the harness answered {len(ours)} of {len(cases)} cases",
            file=sys.stderr,
        )
        return 2

    agreed = 0
    stricter = 0
    skipped = 0
    failures: list[str] = []
    for (method, data), line in zip(cases, ours):
        mine = parse_ours(line)
        theirs = h11_verdict(method, data)
        if theirs[0] == "SKIP":
            skipped += 1
            continue
        if mine[0] == "OK" and theirs[0] == "OK":
            if mine[1] == theirs[1] and mine[2] == theirs[2]:
                agreed += 1
            else:
                failures.append(
                    f"same bytes, different reading\n"
                    f"  ours:  {mine[0]} {mine[1]} {mine[2]!r}\n"
                    f"  h11:   {theirs[0]} {theirs[1]} {theirs[2]!r}\n"
                    f"  case:  {method.decode()} {data.hex()}"
                )
            continue
        if mine[0] == "OK":
            failures.append(
                f"accepted what h11 rejected, which is the dangerous direction\n"
                f"  ours:  {mine[0]} {mine[1]} {mine[2]!r}\n"
                f"  h11:   {theirs[0]}\n"
                f"  case:  {method.decode()} {data.hex()}"
            )
            continue
        if theirs[0] == "OK":
            stricter += 1
            continue
        agreed += 1

    print(f"agreed on {agreed}")
    print(f"stricter than h11 on {stricter}")
    print(f"not comparable, skipped {skipped}")
    if not failures:
        print("\nno disagreement that matters")
        return 0

    print(f"\n{len(failures)} disagreement(s) that matter\n")
    for item in failures[: args.show]:
        print(item)
        print("")
    if len(failures) > args.show:
        print(f"and {len(failures) - args.show} more")
    return 1


if __name__ == "__main__":
    sys.exit(main())
