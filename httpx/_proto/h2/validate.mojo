"""What makes a received HTTP/2 message malformed, from RFC 9113 section 8.2.

HTTP/1.1 puts its field rules in the grammar. A name with a space in it does not
parse, so the parser is the check. HTTP/2 has no grammar at this level: HPACK
hands over a name and a value as two lengths and two runs of octets, and any
octet at all fits in that. So the rules that were structural in HTTP/1.1 have to
be written out here, and a client that skips them is one an intermediary can be
made to disagree with.

That is the whole reason this file exists rather than the rules being nice to
have. The named attack is request smuggling by way of a header that means
something to one hop and nothing to another. A `transfer-encoding` on an HTTP/2
message is the clearest case: it is meaningless in HTTP/2, where framing is the
frame layer's job, and a gateway translating the message back to HTTP/1.1 could
emit it and change where the next hop thinks the message ends. The RFC's answer
is that the message is malformed, and this is that answer.

A field value with a leading space is the same shape of problem in miniature.
HTTP/1.1 treats surrounding whitespace as not part of the value, so trimming it
is right there and wrong here: two implementations that disagree about whether
` 0` and `0` are the same content length disagree about the message.

Malformed is a stream error and not a connection error. Nothing about the
connection is in doubt, because the header block was decoded before it was
judged, so both HPACK tables are still in step and every other stream on the
connection is unaffected.
"""

from httpx._exceptions import ErrorKind, new_error

comptime CONNECTION_SPECIFIC: InlineArray[StaticString, 5] = [
    "connection",
    "proxy-connection",
    "keep-alive",
    "transfer-encoding",
    "upgrade",
]
"""The fields RFC 9113 section 8.2.2 says may not appear at all.

Each of them describes one hop of an HTTP/1.1 connection and HTTP/2 does what
they were for in the framing layer instead. `trailer` and `proxy-authenticate`
are deliberately not here even though this client refuses to send them: the
section names five fields and a client that rejected a response over a sixth
would be refusing messages the specification allows.
"""

comptime TRAILERS: StaticString = "trailers"
"""The only value `TE` may carry. RFC 9113 section 8.2.2."""

comptime _SPACE = UInt8(0x20)
comptime _HTAB = UInt8(0x09)
comptime _NUL = UInt8(0x00)
comptime _LF = UInt8(0x0A)
comptime _CR = UInt8(0x0D)
comptime _UPPER_A = UInt8(0x41)
comptime _UPPER_Z = UInt8(0x5A)
comptime _DEL = UInt8(0x7F)


def _malformed(message: String) -> Error:
    return new_error(ErrorKind.REMOTE_PROTOCOL_ERROR, message)


def check_field(name: StringSpan, value: StringSpan) raises:
    """Every rule that applies to one received field, name and value together.

    Called on each field of a response head and of a set of trailers, before
    anything is done with it. The order is name, then value, then the rules that
    need both, so the message names the most basic thing that is wrong rather
    than the first rule that happens to be checked.
    """
    check_field_name(name)
    check_field_value(name, value)
    check_not_connection_specific(name, value)


def check_field_name(name: StringSpan) raises:
    """RFC 9113 section 8.2.1, which forbids three ranges of octets.

    0x00 to 0x20 covers the controls and the space. 0x41 to 0x5A is the upper
    case letters, which is the rule people are surprised by: HTTP/1.1 field
    names are case insensitive and HTTP/2 field names are lower case, so
    `Content-Type` on the wire is not a stylistic difference, it is malformed.
    0x7F upwards is delete and everything above ASCII.

    Deliberately the RFC's ranges and not the RFC 9110 token rule, which is
    narrower. A colon is not a token character and pseudo-headers start with
    one, and octets such as `(` are allowed here and rejected a layer up by the
    header model, where the message can say what is wrong with them.
    """
    var bytes = name.as_bytes()
    if len(bytes) == 0:
        raise _malformed("the server sent a header with an empty name")

    for i in range(len(bytes)):
        var byte = bytes[i]
        if byte >= _UPPER_A and byte <= _UPPER_Z:
            raise _malformed(
                String(
                    "the server sent the header name ",
                    name,
                    (
                        ", and an upper case letter in a name makes an HTTP/2"
                        " message malformed"
                    ),
                )
            )
        if byte <= _SPACE or byte >= _DEL:
            raise _malformed(
                String(
                    "the server sent a header name containing an octet that is"
                    " not allowed in one"
                )
            )


def check_field_value(name: StringSpan, value: StringSpan) raises:
    """RFC 9113 section 8.2.1 again, for the other half of a field.

    Two rules. No NUL, carriage return or line feed, which are the three octets
    that would let a value become a second field once somebody writes the
    message out as HTTP/1.1. And no leading or trailing space or tab, because
    HTTP/1.1 says whitespace around a value is not part of it and HTTP/2 says a
    value with whitespace around it is not a value, and the gap between those
    two sentences is somewhere two hops can disagree.
    """
    var bytes = value.as_bytes()
    for i in range(len(bytes)):
        var byte = bytes[i]
        if byte == _NUL or byte == _CR or byte == _LF:
            raise _malformed(
                String(
                    "the server sent the header ",
                    name,
                    (
                        " with a value containing a null, carriage return or"
                        " line feed"
                    ),
                )
            )

    if len(bytes) == 0:
        return
    if _is_space(bytes[0]) or _is_space(bytes[len(bytes) - 1]):
        raise _malformed(
            String(
                "the server sent the header ",
                name,
                (
                    " with a value that starts or ends with whitespace, which"
                    " an HTTP/2 value may not"
                ),
            )
        )


def check_not_connection_specific(name: StringSpan, value: StringSpan) raises:
    """RFC 9113 section 8.2.2, the fields that HTTP/2 has no place for.

    `TE` is the exception the section carves out, and only with the exact value
    `trailers`. It survives because it is the one thing in the set that says
    something about the message rather than about the connection carrying it.
    """
    var known = materialize[CONNECTION_SPECIFIC]()
    for i in range(len(known)):
        if name == known[i]:
            raise _malformed(
                String(
                    "the server sent the header ",
                    name,
                    (
                        ", which describes an HTTP/1.1 connection and has no"
                        " meaning in HTTP/2"
                    ),
                )
            )

    if name == "te" and value != TRAILERS:
        raise _malformed(
            String(
                "the server sent te: ",
                value,
                ", and the only value HTTP/2 allows on te is trailers",
            )
        )


def _is_space(byte: UInt8) -> Bool:
    return byte == _SPACE or byte == _HTAB
