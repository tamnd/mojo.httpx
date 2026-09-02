"""Differential fuzzing of the HPACK decoder against hpack.

hpack is the reference because it is the HPACK half of the h2 project, which is
what httpx speaks HTTP/2 through. A disagreement is therefore a real difference
in what a server would get away with against one client and not the other,
rather than a difference of opinion between two libraries nobody uses.

The comparison is deliberately asymmetric, the same way the HTTP/1.1 fuzzer's
is. Stricter than hpack is recorded and allowed: this decoder has bounds hpack
does not, and refusing a block hpack would have read costs a response nobody
wanted anyway. Looser than hpack is always a failure, because a header block
this accepts and hpack rejects is a block that reaches a caller here and reaches
nobody there. Reading the same block differently is a failure too, and it is the
worst of the three: two decoders that disagree about what a field says are two
programs that disagree about what the server answered.

One known and deliberate difference is counted separately rather than hidden.
This decoder produces `String`, so a name or a value that is not valid UTF-8 is
refused, and hpack hands back the bytes. Mutation produces those constantly, so
they get their own line in the summary and are not mixed in with the strictness
that comes from the bounds.

A case is a run of one to three blocks against a single decoder, because the
dynamic table outlives the block that filled it. A decoder can be right about
every block taken on its own and still leave a table the encoder would not
recognise, and every index in the next block is read against that table.

Failing cases print as comma separated hex, which is what the Mojo harness takes
on a line and what a Mojo test can be written around.
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
    import hpack
except ImportError:  # pragma: no cover
    print(
        "hpack is not installed. Run this as `pixi run -e fuzz fuzz-hpack`.",
        file=sys.stderr,
    )
    raise SystemExit(2)

ROOT = Path(__file__).resolve().parents[2]
HARNESS = ROOT / "tools" / "fuzz" / "hpack_harness.mojo"

# What the Mojo decoder is built with, so the reference is asked the same
# question. Neither number is reachable by a block this fuzzer generates, since
# a block is a few dozen bytes, but a decoder configured differently from the
# one under test is a decoder answering about something else.
MAX_HEADER_LIST_SIZE = 65536
MAX_TABLE_SIZE = 4096

# Response header sets, since this is a client. Mixed static table hits, static
# names with fresh values, and names that are in no table at all, because those
# are the three literal forms and each one indexes differently.
HEADER_SETS = [
    [(b":status", b"200")],
    [(b":status", b"204")],
    [(b":status", b"418")],
    [(b":status", b"200"), (b"content-length", b"0")],
    [(b":status", b"200"), (b"content-type", b"text/plain")],
    [(b":status", b"304"), (b"etag", b'W/"deadbeef"')],
    [(b"date", b"Mon, 01 Sep 2026 00:00:00 GMT")],
    [(b"server", b"nginx")],
    [(b"cache-control", b"no-cache, no-store, must-revalidate")],
    [(b"set-cookie", b"a=1; Path=/; HttpOnly")],
    [(b"set-cookie", b"b=2"), (b"set-cookie", b"c=3")],
    [(b"x-not-in-any-table", b"value")],
    [(b"x-empty", b"")],
    [(b"", b"")],
    [(b"x-long", b"z" * 200)],
    [(b"x-repeated", b"same"), (b"x-repeated", b"same")],
    # A value the Huffman encoder shortens a lot, and one it lengthens. Both
    # paths are in the encoder, and which one it takes decides what the decoder
    # is handed.
    [(b"x-huffman", b"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")],
    [(b"x-huffman", bytes(range(0x20, 0x40)))],
]


def integer(value: int, prefix_bits: int, mask: int) -> bytes:
    """One HPACK integer, so the raw blocks below can be written as intent."""
    limit = (1 << prefix_bits) - 1
    if value < limit:
        return bytes([mask | value])
    out = bytearray([mask | limit])
    value -= limit
    while value >= 128:
        out.append((value % 128) + 128)
        value //= 128
    out.append(value)
    return bytes(out)


def raw_blocks() -> list[bytes]:
    """Blocks written by hand, each one aimed at a branch a decoder has.

    An encoder does not produce any of these, which is the point. The cases
    that come out of hpack's encoder are the ones both sides get right; these
    are the ones where a decoder either has a bound or does not.
    """
    return [
        b"",
        # Indexed, and the ways an index can address nothing.
        b"\x80",
        integer(62, 7, 0x80),
        integer(127, 7, 0x80),
        integer(1 << 30, 7, 0x80),
        b"\xff\x80\x80\x80\x80\x80\x80\x80\x80\x80\x00",
        b"\xff",
        # Dynamic table size updates. Zero and the maximum are legal, above the
        # maximum is not, and one in the middle of a block changes what every
        # index after it means.
        b"\x20",
        integer(MAX_TABLE_SIZE, 5, 0x20),
        integer(MAX_TABLE_SIZE + 1, 5, 0x20),
        integer(1 << 30, 5, 0x20),
        b"\x82\x20",
        b"\x20\x20\x82",
        # Literals, in all three forms, truncated in all the places they can be.
        b"\x00\x00\x00",
        b"\x40\x00\x00",
        b"\x10\x00\x00",
        b"\x00",
        b"\x00\x0a",
        b"\x00\x02ab",
        b"\x00\x01a",
        b"\x08\x00",
        b"\x0f\x00",
        b"\x7f\x00\x00",
        b"\x0f\x80\x01\x00",
        # Huffman strings. A code that never terminates, padding that is not
        # ones, and a length that runs past the block.
        b"\x00\x81\xff",
        b"\x00\x81\x00",
        b"\x00\x8a",
        b"\x00\x00\x83\xff\xff\xff",
        # A name that is bytes rather than text, which is legal HPACK and legal
        # HTTP, and which this decoder refuses because it makes a String.
        b"\x00\x02\xc3\x28\x00",
        b"\x00\x02ab\x02\xff\xfe",
    ]


RAW_BLOCKS = raw_blocks()


def encoded_case(rng: random.Random) -> list[bytes]:
    """A run of blocks from hpack's own encoder, before any damage."""
    encoder = hpack.Encoder()
    blocks = []
    for _ in range(rng.randrange(1, 4)):
        headers = list(rng.choice(HEADER_SETS))
        if rng.random() < 0.4:
            headers += list(rng.choice(HEADER_SETS))
        if rng.random() < 0.15:
            # A resize the encoder announces at the start of the next block.
            # The last choice is above what we advertised, which both decoders
            # should refuse.
            encoder.header_table_size = rng.choice([0, 256, 4096, 8192])
        blocks.append(encoder.encode(headers, huffman=rng.random() < 0.5))
    return blocks


def generate(rng: random.Random) -> list[bytes]:
    """One case, as the blocks it is made of."""
    roll = rng.random()
    if roll < 0.60:
        blocks = encoded_case(rng)
    elif roll < 0.85:
        blocks = [rng.choice(RAW_BLOCKS) for _ in range(rng.randrange(1, 3))]
    else:
        # Blocks of nothing in particular. The structured cases are all shaped
        # like something, so they find the disagreements that come from reading
        # RFC 7541 differently; these find the ones that come from a decoder
        # walking off the end of a buffer.
        blocks = [
            bytes(rng.randrange(256) for _ in range(rng.randrange(0, 24)))
            for _ in range(rng.randrange(1, 3))
        ]

    # At most one block in a case is damaged, and not every case is. Damaging
    # them all makes a case that ends on the first block, and the case worth
    # having is the one where the earlier blocks build a table and a later one
    # lies about what is in it.
    if rng.random() < 0.45:
        at = rng.randrange(len(blocks))
        blocks[at] = mutate(blocks[at], rng)
    return blocks


def mutate(data: bytes, rng: random.Random) -> bytes:
    """Damage a block, the way a hostile peer would."""
    if not data:
        return data
    out = bytearray(data)
    roll = rng.random()
    if roll < 0.40:
        out[rng.randrange(len(out))] = rng.randrange(256)
    elif roll < 0.70:
        return bytes(out[: rng.randrange(len(out))])
    elif roll < 0.85:
        out.insert(rng.randrange(len(out) + 1), rng.randrange(256))
    else:
        del out[rng.randrange(len(out))]
    return bytes(out)


def hpack_verdict(blocks: list[bytes]) -> tuple[str, list[tuple[bytes, bytes]]]:
    """What hpack makes of one run of blocks, in the harness's vocabulary.

    Every exception is a refusal, not only the HPACK ones. A decoder that comes
    apart on a block has refused it as far as a caller is concerned, and there
    is no reading of the block to compare against.
    """
    decoder = hpack.Decoder(max_header_list_size=MAX_HEADER_LIST_SIZE)
    decoder.max_allowed_table_size = MAX_TABLE_SIZE
    found: list[tuple[bytes, bytes]] = []
    for block in blocks:
        try:
            fields = decoder.decode(block, raw=True)
        except Exception:
            return ("ERR", [])
        found.extend((bytes(name), bytes(value)) for name, value in fields)
    return ("OK", found)


def parse_ours(line: str) -> tuple[str, list[tuple[bytes, bytes]]]:
    if not line.startswith("OK"):
        return ("ERR", [])
    payload = line[2:].strip()
    if not payload:
        return ("OK", [])
    found = []
    for item in payload.split(";"):
        name, _, value = item.partition(":")
        found.append((bytes.fromhex(name), bytes.fromhex(value)))
    return ("OK", found)


def is_text(fields: list[tuple[bytes, bytes]]) -> bool:
    """Whether every name and value in a reading is valid UTF-8."""
    for name, value in fields:
        try:
            name.decode("utf-8")
            value.decode("utf-8")
        except UnicodeDecodeError:
            return False
    return True


def show(blocks: list[bytes]) -> str:
    return ",".join(block.hex() for block in blocks)


def run_harness(cases: list[list[bytes]]) -> list[str]:
    """Put every case through the Mojo decoder, in one process."""
    mojo = os.environ.get("MOJO") or shutil.which("mojo")
    if not mojo:
        launcher = Path.home() / ".pixi" / "bin" / "mojo"
        mojo = str(launcher) if launcher.exists() else ""
    if not mojo:
        print("mojo not found. Run this through pixi.", file=sys.stderr)
        raise SystemExit(2)

    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as handle:
        for blocks in cases:
            handle.write(show(blocks) + "\n")
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

    read_alike = 0
    refused_alike = 0
    stricter = 0
    refused_bytes = 0
    failures: list[str] = []
    for blocks, line in zip(cases, ours):
        mine = parse_ours(line)
        theirs = hpack_verdict(blocks)
        if mine[0] == "OK" and theirs[0] == "OK":
            if mine[1] == theirs[1]:
                read_alike += 1
            else:
                failures.append(
                    f"same block, different reading\n"
                    f"  ours:  {mine[1]}\n"
                    f"  hpack: {theirs[1]}\n"
                    f"  case:  {show(blocks)}"
                )
            continue
        if mine[0] == "OK":
            failures.append(
                f"accepted what hpack rejected, which is the dangerous"
                f" direction\n"
                f"  ours:  {mine[1]}\n"
                f"  hpack: rejected\n"
                f"  case:  {show(blocks)}"
            )
            continue
        if theirs[0] == "OK":
            if is_text(theirs[1]):
                stricter += 1
            else:
                refused_bytes += 1
            continue
        refused_alike += 1

    # The two agreements are counted apart because they say different things. A
    # run where almost everything was refused by both is a run that spent its
    # time on blocks no decoder would read, and the number to watch is the one
    # above it.
    print(f"read alike {read_alike}")
    print(f"refused alike {refused_alike}")
    print(f"stricter than hpack on {stricter}")
    print(f"refused for a name or value that is not UTF-8 on {refused_bytes}")
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
