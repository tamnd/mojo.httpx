"""The HPACK decoder, wired up so another program can ask it what it thinks.

The differential fuzzer in tools/fuzz/hpack_diff.py needs to put the same header
blocks through this library's decoder and through hpack, and compare the two
readings. hpack is Python, this is Mojo, so the two sides talk through a file of
cases and a stream of one line answers.

One process for the whole run, not one per case, for the same reason the HTTP/1.1
harness does it: starting a Mojo binary costs more than decoding a header block
by several orders of magnitude.

A case is a run of blocks and not a single block. The dynamic table outlives the
block that filled it, so a decoder can be right about every block taken on its
own and still be wrong about the table it leaves behind, and a fuzzer that
started fresh each time would never see it. One decoder per case, in order,
which makes cases independent of each other but not blocks independent within a
case.
"""

from std.sys import argv

from httpx._proto.h2.hpack import HpackDecoder

comptime HEX = String("0123456789abcdef")


def main() raises:
    """Read a case file, print one verdict per line.

    Each input line is one case: the blocks in hex, separated by commas. An
    empty field between two commas is an empty block, which is a thing a server
    can send and so a thing worth asking about.

    Each output line is `OK ` followed by the decoded fields, or `ERR` for a case
    that was rejected anywhere in the run. Fields are `name:value` with both in
    hex, separated by semicolons, because a fuzzer generates names and values
    that no printable encoding survives.
    """
    var args = argv()
    if len(args) < 2:
        print("usage: hpack_harness.mojo <cases-file>")
        return

    # An empty line is a case, not a blank to skip past. It is a single empty
    # block, and the fuzzer counts answers against cases, so swallowing one
    # would look like the harness had fallen over.
    var text = open(String(args[1]), "r").read()
    for line in String(text).splitlines():
        print(_verdict(String(line).strip()))


def _verdict(line: StringSpan) -> String:
    """What this library makes of one run of blocks.

    Everything is caught, because from the fuzzer's side the only interesting
    question is whether the blocks were accepted and what came out if they were.
    The first refusal ends the case: the table is out of step with the encoder's
    from that point on, so what a later block decodes to says nothing.
    """
    var decoder = HpackDecoder()
    var out = String("OK ")
    var first = True
    try:
        var blocks = String(line).split(",")
        for i in range(len(blocks)):
            var data = _unhex(blocks[i])
            var fields = decoder.decode(Span(data))
            for f in range(len(fields)):
                if not first:
                    out += ";"
                first = False
                out += _hex(fields[f].name.as_bytes())
                out += ":"
                out += _hex(fields[f].value.as_bytes())
    except e:
        return String("ERR")
    return out^


def _unhex(text: StringSpan) -> List[UInt8]:
    var out = List[UInt8]()
    var bytes = text.as_bytes()
    var i = 0
    while i + 1 < len(bytes):
        out.append(_nibble(bytes[i]) * 16 + _nibble(bytes[i + 1]))
        i += 2
    return out^


def _nibble(c: UInt8) -> UInt8:
    var value = Int(c)
    if value >= ord("0") and value <= ord("9"):
        return UInt8(value - ord("0"))
    if value >= ord("a") and value <= ord("f"):
        return UInt8(value - ord("a") + 10)
    if value >= ord("A") and value <= ord("F"):
        return UInt8(value - ord("A") + 10)
    return UInt8(0)


def _hex[o: ImmOrigin](data: Span[UInt8, o]) -> String:
    var out = String()
    for i in range(len(data)):
        out += HEX[byte=Int(data[i] >> 4)]
        out += HEX[byte=Int(data[i] & 0xF)]
    return out^
