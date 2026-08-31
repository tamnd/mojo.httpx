"""The parser, wired up so another program can ask it what it thinks.

The differential fuzzer in tools/fuzz/h1_diff.py needs to put the same bytes
through this library's response parser and through h11, and compare the two
verdicts. h11 is Python, this is Mojo, so the two sides talk through a file of
cases and a stream of one line answers.

One process for the whole run, not one per case. Starting a Mojo binary costs
more than parsing a response by several orders of magnitude, and a fuzzer that
can only manage a few hundred cases a second is a fuzzer nobody runs for long
enough to find anything.

Every case is parsed with no network behind it. The bytes are all there from
the start, so a parser that wants more data has been given everything it is
ever going to get, which is the same thing as the server having closed.
"""

from std.sys import argv

from httpx._io.buffer import ByteBuffer
from httpx._proto.h1.body import BodyReader
from httpx._proto.h1.framing import framing_for
from httpx._proto.h1.head import parse_head

comptime HEX = String("0123456789abcdef")


def main() raises:
    """Read a case file, print one verdict per line.

    Each input line is a request method, a space, and the response bytes in
    hex. The method matters because it decides the framing: the answer to a
    HEAD has no body however much the headers say it does.

    Each output line is `OK <status> <body hex>`, `INCOMPLETE` for bytes that
    are a valid prefix of a response rather than a whole one, or `ERR` for
    anything rejected. The fuzzer compares those against what h11 said.
    """
    var args = argv()
    if len(args) < 2:
        print("usage: harness.mojo <cases-file>")
        return

    var text = open(String(args[1]), "r").read()
    for line in String(text).splitlines():
        var trimmed = String(line).strip()
        if trimmed.byte_length() == 0:
            continue
        var space = trimmed.find(" ")
        if space < 0:
            print("ERR")
            continue
        var method = String(trimmed[byte=0:space])
        var body = String(trimmed[byte = space + 1 :])
        print(_verdict(method, _unhex(body)))


def _verdict(method: StringSpan, data: List[UInt8]) -> String:
    """What this library makes of one response.

    Everything is caught, including the failures that are not parse errors,
    because from the fuzzer's side the only interesting question is whether the
    bytes were accepted and what came out if they were.
    """
    try:
        var buf = ByteBuffer()
        buf.extend(Span(data))

        var found = parse_head(buf)
        if not found:
            return String("INCOMPLETE")
        var head = found.take()

        var reader = BodyReader(framing_for(method, head))
        var content = List[UInt8]()
        if reader.read_from(buf, content):
            # It wants more and there is no more, which is exactly what a
            # server closing the connection looks like. Whether that is the end
            # of the body or a truncation is the reader's decision to make.
            reader.at_eof()
            _ = reader.read_from(buf, content)
        if not reader.is_complete():
            return String("INCOMPLETE")
        return String("OK ", head.status_code, " ", _hex(Span(content)))
    except e:
        return String("ERR")


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
        out += HEX[byte = Int(data[i] >> 4)]
        out += HEX[byte = Int(data[i] & 0xF)]
    return out^
