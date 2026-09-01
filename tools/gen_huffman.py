"""Turn the HPACK Huffman code into the tables the encoder and decoder use.

    python tools/gen_huffman.py            rewrite httpx/_proto/h2/_huffman_data.mojo
    python tools/gen_huffman.py --check    fail if the file on disk is out of date

The code itself is RFC 7541 appendix B, a fixed table of 257 symbols that never
changes. It is written out below rather than vendored, because there is no file
to vendor: the RFC prints it and every implementation carries its own copy.

A copy typed out by hand is a copy that can be wrong, so it is checked before
anything is generated from it. The lengths must satisfy Kraft equality exactly,
which for a complete prefix code means the sum of two to the minus length over
every symbol is one, and no code may be a prefix of another. A single mistyped
digit breaks one or the other with near certainty, and both checks run on every
generate and every `--check`.

The decoder table is the interesting output. Decoding bit by bit would mean up
to thirty branches per byte, so the table is a state machine over four bit
nibbles instead: for each state and each nibble, walk the four bits through the
code tree and record where it ended up, whether it emitted a symbol, and whether
the state it landed in is one a string may legally end on. That is two lookups
per byte and no branching on individual bits. It is the same shape nghttp2 uses.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "httpx" / "_proto" / "h2" / "_huffman_data.mojo"

# One entry per symbol, in symbol order: the code, and how many bits of it are
# significant. Symbol 256 is EOS, which never appears in a well formed encoding.
CODES: list[tuple[int, int]] = [
    (0x1FF8, 13), (0x7FFFD8, 23), (0xFFFFFE2, 28), (0xFFFFFE3, 28),
    (0xFFFFFE4, 28), (0xFFFFFE5, 28), (0xFFFFFE6, 28), (0xFFFFFE7, 28),
    (0xFFFFFE8, 28), (0xFFFFEA, 24), (0x3FFFFFFC, 30), (0xFFFFFE9, 28),
    (0xFFFFFEA, 28), (0x3FFFFFFD, 30), (0xFFFFFEB, 28), (0xFFFFFEC, 28),
    (0xFFFFFED, 28), (0xFFFFFEE, 28), (0xFFFFFEF, 28), (0xFFFFFF0, 28),
    (0xFFFFFF1, 28), (0xFFFFFF2, 28), (0x3FFFFFFE, 30), (0xFFFFFF3, 28),
    (0xFFFFFF4, 28), (0xFFFFFF5, 28), (0xFFFFFF6, 28), (0xFFFFFF7, 28),
    (0xFFFFFF8, 28), (0xFFFFFF9, 28), (0xFFFFFFA, 28), (0xFFFFFFB, 28),
    (0x14, 6), (0x3F8, 10), (0x3F9, 10), (0xFFA, 12),
    (0x1FF9, 13), (0x15, 6), (0xF8, 8), (0x7FA, 11),
    (0x3FA, 10), (0x3FB, 10), (0xF9, 8), (0x7FB, 11),
    (0xFA, 8), (0x16, 6), (0x17, 6), (0x18, 6),
    (0x0, 5), (0x1, 5), (0x2, 5), (0x19, 6),
    (0x1A, 6), (0x1B, 6), (0x1C, 6), (0x1D, 6),
    (0x1E, 6), (0x1F, 6), (0x5C, 7), (0xFB, 8),
    (0x7FFC, 15), (0x20, 6), (0xFFB, 12), (0x3FC, 10),
    (0x1FFA, 13), (0x21, 6), (0x5D, 7), (0x5E, 7),
    (0x5F, 7), (0x60, 7), (0x61, 7), (0x62, 7),
    (0x63, 7), (0x64, 7), (0x65, 7), (0x66, 7),
    (0x67, 7), (0x68, 7), (0x69, 7), (0x6A, 7),
    (0x6B, 7), (0x6C, 7), (0x6D, 7), (0x6E, 7),
    (0x6F, 7), (0x70, 7), (0x71, 7), (0x72, 7),
    (0xFC, 8), (0x73, 7), (0xFD, 8), (0x1FFB, 13),
    (0x7FFF0, 19), (0x1FFC, 13), (0x3FFC, 14), (0x22, 6),
    (0x7FFD, 15), (0x3, 5), (0x23, 6), (0x4, 5),
    (0x24, 6), (0x5, 5), (0x25, 6), (0x26, 6),
    (0x27, 6), (0x6, 5), (0x74, 7), (0x75, 7),
    (0x28, 6), (0x29, 6), (0x2A, 6), (0x7, 5),
    (0x2B, 6), (0x76, 7), (0x2C, 6), (0x8, 5),
    (0x9, 5), (0x2D, 6), (0x77, 7), (0x78, 7),
    (0x79, 7), (0x7A, 7), (0x7B, 7), (0x7FFE, 15),
    (0x7FC, 11), (0x3FFD, 14), (0x1FFD, 13), (0xFFFFFFC, 28),
    (0xFFFE6, 20), (0x3FFFD2, 22), (0xFFFE7, 20), (0xFFFE8, 20),
    (0x3FFFD3, 22), (0x3FFFD4, 22), (0x3FFFD5, 22), (0x7FFFD9, 23),
    (0x3FFFD6, 22), (0x7FFFDA, 23), (0x7FFFDB, 23), (0x7FFFDC, 23),
    (0x7FFFDD, 23), (0x7FFFDE, 23), (0xFFFFEB, 24), (0x7FFFDF, 23),
    (0xFFFFEC, 24), (0xFFFFED, 24), (0x3FFFD7, 22), (0x7FFFE0, 23),
    (0xFFFFEE, 24), (0x7FFFE1, 23), (0x7FFFE2, 23), (0x7FFFE3, 23),
    (0x7FFFE4, 23), (0x1FFFDC, 21), (0x3FFFD8, 22), (0x7FFFE5, 23),
    (0x3FFFD9, 22), (0x7FFFE6, 23), (0x7FFFE7, 23), (0xFFFFEF, 24),
    (0x3FFFDA, 22), (0x1FFFDD, 21), (0xFFFE9, 20), (0x3FFFDB, 22),
    (0x3FFFDC, 22), (0x7FFFE8, 23), (0x7FFFE9, 23), (0x1FFFDE, 21),
    (0x7FFFEA, 23), (0x3FFFDD, 22), (0x3FFFDE, 22), (0xFFFFF0, 24),
    (0x1FFFDF, 21), (0x3FFFDF, 22), (0x7FFFEB, 23), (0x7FFFEC, 23),
    (0x1FFFE0, 21), (0x1FFFE1, 21), (0x3FFFE0, 22), (0x1FFFE2, 21),
    (0x7FFFED, 23), (0x3FFFE1, 22), (0x7FFFEE, 23), (0x7FFFEF, 23),
    (0xFFFEA, 20), (0x3FFFE2, 22), (0x3FFFE3, 22), (0x3FFFE4, 22),
    (0x7FFFF0, 23), (0x3FFFE5, 22), (0x3FFFE6, 22), (0x7FFFF1, 23),
    (0x3FFFFE0, 26), (0x3FFFFE1, 26), (0xFFFEB, 20), (0x7FFF1, 19),
    (0x3FFFE7, 22), (0x7FFFF2, 23), (0x3FFFE8, 22), (0x1FFFFEC, 25),
    (0x3FFFFE2, 26), (0x3FFFFE3, 26), (0x3FFFFE4, 26), (0x7FFFFDE, 27),
    (0x7FFFFDF, 27), (0x3FFFFE5, 26), (0xFFFFF1, 24), (0x1FFFFED, 25),
    (0x7FFF2, 19), (0x1FFFE3, 21), (0x3FFFFE6, 26), (0x7FFFFE0, 27),
    (0x7FFFFE1, 27), (0x3FFFFE7, 26), (0x7FFFFE2, 27), (0xFFFFF2, 24),
    (0x1FFFE4, 21), (0x1FFFE5, 21), (0x3FFFFE8, 26), (0x3FFFFE9, 26),
    (0xFFFFFFD, 28), (0x7FFFFE3, 27), (0x7FFFFE4, 27), (0x7FFFFE5, 27),
    (0xFFFEC, 20), (0xFFFFF3, 24), (0xFFFED, 20), (0x1FFFE6, 21),
    (0x3FFFE9, 22), (0x1FFFE7, 21), (0x1FFFE8, 21), (0x7FFFF3, 23),
    (0x3FFFEA, 22), (0x3FFFEB, 22), (0x1FFFFEE, 25), (0x1FFFFEF, 25),
    (0xFFFFF4, 24), (0xFFFFF5, 24), (0x3FFFFEA, 26), (0x7FFFF4, 23),
    (0x3FFFFEB, 26), (0x7FFFFE6, 27), (0x3FFFFEC, 26), (0x3FFFFED, 26),
    (0x7FFFFE7, 27), (0x7FFFFE8, 27), (0x7FFFFE9, 27), (0x7FFFFEA, 27),
    (0x7FFFFEB, 27), (0xFFFFFFE, 28), (0x7FFFFEC, 27), (0x7FFFFED, 27),
    (0x7FFFFEE, 27), (0x7FFFFEF, 27), (0x7FFFFF0, 27), (0x3FFFFEE, 26),
    (0x3FFFFFFF, 30),
]

EOS = 256

# What a decoder needs to know about the state it landed in.
ACCEPTED = 1
"""A string may legally end here, so what follows is padding."""

SYMBOL = 2
"""A symbol came out on the way, and it is in this entry."""

FAIL = 4
"""The bits walked into the EOS code, which no valid encoding contains."""


def validate() -> None:
    """Refuse to generate from a table that is not a complete prefix code."""
    if len(CODES) != 257:
        raise SystemExit("the table has %d symbols, not 257" % len(CODES))

    for symbol, (code, bits) in enumerate(CODES):
        if bits < 5 or bits > 30:
            raise SystemExit("symbol %d has %d bits" % (symbol, bits))
        if code >> bits:
            raise SystemExit(
                "symbol %d has bits outside its %d bit length" % (symbol, bits)
            )

    # Kraft equality. A complete prefix code uses up exactly all the space, so
    # this sums to one. Done in integers against 2 ** 30 rather than in floats,
    # because "exactly" is the whole point of the check.
    total = sum(1 << (30 - bits) for _code, bits in CODES)
    if total != 1 << 30:
        raise SystemExit(
            "the lengths do not satisfy Kraft equality: %d against %d"
            % (total, 1 << 30)
        )

    # Prefix freeness. Kraft equality alone allows a table where one code is a
    # prefix of another and some other pair leaves a matching hole, so both
    # checks are needed and neither implies the other.
    seen: dict[tuple[int, int], int] = {}
    for symbol, (code, bits) in enumerate(CODES):
        seen[(code, bits)] = symbol
    for symbol, (code, bits) in enumerate(CODES):
        for shorter in range(5, bits):
            found = seen.get((code >> (bits - shorter), shorter))
            if found is not None:
                raise SystemExit(
                    "symbol %d is a prefix of symbol %d" % (found, symbol)
                )


class Node:
    """One node of the code tree, built once and walked to fill the table."""

    __slots__ = ("children", "symbol")

    def __init__(self) -> None:
        self.children: list[Node | None] = [None, None]
        self.symbol: int | None = None


def build_tree() -> Node:
    root = Node()
    for symbol, (code, bits) in enumerate(CODES):
        node = root
        for shift in range(bits - 1, -1, -1):
            bit = (code >> shift) & 1
            child = node.children[bit]
            if child is None:
                child = Node()
                node.children[bit] = child
            node = child
        node.symbol = symbol
    return root


def build_states() -> list[list[tuple[int, int, int]]]:
    """The nibble state machine: for each state, sixteen transitions.

    A state is a position in the code tree, numbered in the order the states are
    first reached so that state zero is the root. Each transition walks four
    bits and records where it ended, whether a symbol fell out along the way,
    and whether the walk ran into EOS.

    At most one symbol can be emitted per nibble. That is a property of the
    code rather than an assumption: the shortest code is five bits, so four bits
    can complete at most one of them.
    """
    root = build_tree()
    numbering: dict[int, int] = {id(root): 0}
    states: list[Node] = [root]

    table: list[list[tuple[int, int, int]]] = []
    at = 0
    while at < len(states):
        node = states[at]
        row: list[tuple[int, int, int]] = []
        for nibble in range(16):
            walk = node
            flags = 0
            symbol = 0
            for shift in range(3, -1, -1):
                if flags & FAIL:
                    break
                child = walk.children[(nibble >> shift) & 1]
                if child is None:
                    # Nothing in the code tree goes this way. Only reachable
                    # through the EOS branch, which is the failure below.
                    flags |= FAIL
                    break
                if child.symbol is not None:
                    if child.symbol == EOS:
                        # RFC 7541 section 5.2: an encoding containing the EOS
                        # symbol must be treated as a decoding error. Recorded
                        # in the table so the decoder does not have to check.
                        flags |= FAIL
                        break
                    flags |= SYMBOL
                    symbol = child.symbol
                    walk = root
                else:
                    walk = child
            if flags & FAIL:
                row.append((0, FAIL, 0))
                continue
            key = id(walk)
            if key not in numbering:
                numbering[key] = len(states)
                states.append(walk)
            row.append((numbering[key], flags, symbol))
        table.append(row)
        at += 1

    accepting = _accepting(numbering, root)
    out = []
    for row in table:
        marked = []
        for state, flags, symbol in row:
            if not (flags & FAIL) and state in accepting:
                flags |= ACCEPTED
            marked.append((state, flags, symbol))
        out.append(marked)
    return out


def _accepting(numbering, root):
    """The states a string may legally stop in.

    RFC 7541 section 5.2 allows a string to end with fewer than eight bits of
    padding, and requires the padding to be the most significant bits of the EOS
    code. Every one of those bits is a one, so the only place a decoder may find
    itself when the bytes run out is the root, or somewhere on the chain of ones
    leading away from it, no more than seven steps along.

    Nothing on that chain within seven steps is a leaf, so the walk below never
    has to decide what to do about one. That is a property of the code: the
    shortest code is five bits and neither 0b11111 nor any longer run of ones up
    to seven is a code.
    """
    out = {0}
    walk = root
    for _step in range(7):
        walk = walk.children[1]
        if walk is None or walk.symbol is not None:
            break
        index = numbering.get(id(walk))
        if index is not None:
            out.add(index)
    return out


CODE_WIDTH = 10
"""Eight hex digits of code, then two of length."""

STATE_WIDTH = 6
"""Two hex digits of next state, two of flags, two of symbol."""

CHUNK = 60


def _rows(text: str) -> list[str]:
    return [
        '    "%s"' % text[at : at + CHUNK] for at in range(0, len(text), CHUNK)
    ]


def render(states) -> str:
    codes = "".join("%08X%02X" % (code, bits) for code, bits in CODES)
    transitions = "".join(
        "%02X%02X%02X" % (state, flags, symbol)
        for row in states
        for state, flags, symbol in row
    )

    lines = [
        '"""The HPACK Huffman code, as a pair of tables.',
        "",
        "Generated by tools/gen_huffman.py from RFC 7541 appendix B.",
        "Do not edit. Run `pixi run python tools/gen_huffman.py` instead.",
        "",
        "Both tables are runs of fixed width hexadecimal records in a single",
        "string, which is how every generated table in this project is stored:",
        "the record at position n starts at n times the width, so there is no",
        "index to keep in step with the data.",
        "",
        "`HUFFMAN_CODES` is one record per symbol, in symbol order, holding the",
        "code and then how many of its bits are significant. Symbol 256 is EOS,",
        "which an encoder uses for padding and a decoder must reject if it ever",
        "appears whole.",
        "",
        "`HUFFMAN_STATES` is the decoder, as a state machine over four bit",
        "nibbles: sixteen records per state, each holding the state to move to,",
        "the flags, and the symbol emitted if there was one. Decoding a byte is",
        "two lookups and no branching on individual bits.",
        '"""',
        "",
        "comptime HUFFMAN_SYMBOLS = %d" % len(CODES),
        "",
        "comptime HUFFMAN_EOS = %d" % EOS,
        "",
        "comptime HUFFMAN_CODE_WIDTH = %d" % CODE_WIDTH,
        "",
        "comptime HUFFMAN_STATE_COUNT = %d" % len(states),
        "",
        "comptime HUFFMAN_STATE_WIDTH = %d" % STATE_WIDTH,
        "",
        "comptime HUFFMAN_ACCEPTED = %d" % ACCEPTED,
        '"""A string may legally end in this state, so what follows is padding."""',
        "",
        "comptime HUFFMAN_SYMBOL = %d" % SYMBOL,
        '"""A symbol came out on the way here, and this record holds it."""',
        "",
        "comptime HUFFMAN_FAIL = %d" % FAIL,
        '"""These bits walked into EOS, which no valid encoding contains."""',
        "",
        "comptime HUFFMAN_CODES = StaticString(",
    ]
    lines.extend(_rows(codes))
    lines.append(")")
    lines.append("")
    lines.append("comptime HUFFMAN_STATES = StaticString(")
    lines.extend(_rows(transitions))
    lines.append(")")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="report whether the generated file is up to date",
    )
    args = parser.parse_args()

    validate()
    states = build_states()
    rendered = render(states)

    if args.check:
        current = OUTPUT.read_text() if OUTPUT.exists() else ""
        if current != rendered:
            print(
                "huffman: %s is out of date. Run"
                " `python tools/gen_huffman.py`." % OUTPUT.relative_to(ROOT),
                file=sys.stderr,
            )
            return 1
        print(
            "huffman: ok, %d symbols and %d decoder states"
            % (len(CODES), len(states))
        )
        return 0

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(rendered)
    print(
        "huffman: wrote %d symbols and %d decoder states to %s"
        % (len(CODES), len(states), OUTPUT.relative_to(ROOT))
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
