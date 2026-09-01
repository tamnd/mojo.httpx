"""Base64, in the one form HTTP asks for it.

Standard alphabet, always padded, no line breaks. That is what `Authorization:
Basic` wants and it is the only thing in this library that needs base64 at all,
so the URL safe alphabet and the line wrapped MIME variant are not here.

Encoding only. Nothing in an HTTP client reads a base64 credential back: the
header goes out and the server is the one that takes it apart.
"""

comptime _ALPHABET = StaticString(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
)


def base64_encode[o: ImmOrigin](data: Span[UInt8, o]) -> String:
    """Three bytes in, four characters out, padded with `=` to a multiple of
    four."""
    var out = String()
    var at = 0

    while at + 3 <= len(data):
        var group = (
            (UInt32(data[at]) << 16)
            | (UInt32(data[at + 1]) << 8)
            | UInt32(data[at + 2])
        )
        for shift in range(18, -1, -6):
            var index = Int((group >> UInt32(shift)) & 0x3F)
            out += _ALPHABET[byte = index : index + 1]
        at += 3

    var left = len(data) - at
    if left == 0:
        return out^

    # One or two bytes over. The remainder is padded with zero bits up to the
    # next six bit boundary, which is why the last character of a group of two
    # is not the same as it would be with a third byte of zero following.
    var group = UInt32(data[at]) << 16
    if left == 2:
        group |= UInt32(data[at + 1]) << 8

    var characters = 3 if left == 2 else 2
    for i in range(characters):
        var index = Int((group >> UInt32(18 - 6 * i)) & 0x3F)
        out += _ALPHABET[byte = index : index + 1]
    for _ in range(4 - characters):
        out += "="
    return out^
