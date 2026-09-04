"""Reading a hexadecimal fixture back into bytes.

The codec tests are the only place in the suite with binary fixtures in them,
because a compressed body cannot be written out as text and there is no
compressor on this side to make one with. Hexadecimal in the source, with the
Python call that produced it in a comment above, is what keeps a fixture
readable and reproducible at the same time.

This lives here rather than in one of the test modules because three of them
want it, and three copies of a hex reader is three places for an off by one to
hide.
"""


def _digit(byte: UInt8) raises -> Int:
    """One hexadecimal digit, lower case only.

    Upper case is rejected rather than accepted, so that a fixture pasted from
    somewhere with a different convention is a failure here rather than a
    silently different body.
    """
    if byte >= UInt8(ord("a")) and byte <= UInt8(ord("f")):
        return Int(byte - UInt8(ord("a"))) + 10
    if byte >= UInt8(ord("0")) and byte <= UInt8(ord("9")):
        return Int(byte - UInt8(ord("0")))
    raise Error(String("not a hex digit: ", byte))


def unhex(text: StringSpan) raises -> List[UInt8]:
    """The bytes a hexadecimal fixture stands for."""
    var source = text.as_bytes()
    var out = List[UInt8]()
    var high = -1
    for i in range(len(source)):
        var nibble = _digit(source[i])
        if high < 0:
            high = nibble
        else:
            out.append(UInt8(high * 16 + nibble))
            high = -1
    if high >= 0:
        raise Error("odd number of hex digits in a fixture")
    return out^
