"""The http2jp HPACK vectors, decoded against the encoders that made them.

HPACK gives an encoder real freedom. The same header list can go out as a static
index, a dynamic index, a literal with indexing, a literal without it, Huffman
coded or not, with the table resized in the middle, and every one of those is
correct. So a decoder tested only against our own encoder is tested against our
own choices, and the choices nobody made are exactly where the bugs are.

These are four encoders that made different ones, and the descriptions in the
files say so. See tools/vendor/sources.toml for which four and why.

The stories are stateful and that is the point. A dynamic table is built up
across the cases in one story, so case seven decodes correctly only if cases zero
to six each put the right thing in the table. One decoder per story, and a
failure anywhere in it usually means the mistake was earlier.

The JSON is read and parsed here rather than compiled into a Mojo fixture, which
is what the URL and cookie corpora do. Those need filtering and annotating in
Python before they mean anything. These do not, and the suite is already built as
one binary that takes half an hour to compile in CI, so half a megabyte of
generated source is a real cost with nothing bought for it.
"""

from std.testing import assert_equal

from httpx._models.json import Json, JsonValue
from httpx._proto.h2.hpack import HpackDecoder
from httpx._proto.h2.table import HeaderField
from tests.corpus import read_corpus

comptime IMPLEMENTATIONS: InlineArray[StaticString, 4] = [
    "nghttp2",
    "nghttp2-change-table-size",
    "haskell-http2-naive",
    "haskell-http2-linear-huffman",
]

comptime STORIES = 10
"""How many stories from each encoder are vendored, numbered from zero."""


def _story_path(implementation: StringSpan, number: Int) -> String:
    var padded = String(number) if number >= 10 else String("0", number)
    return String("hpack/", implementation, "/story_", padded, ".json")


def _unhex(text: StringSpan) raises -> List[UInt8]:
    """The `wire` field, which is the header block written as hex digits."""
    var bytes = text.as_bytes()
    if len(bytes) % 2 != 0:
        raise Error("a wire field has an odd number of hex digits")
    var out = List[UInt8]()
    for i in range(0, len(bytes), 2):
        out.append(_nibble(bytes[i]) << 4 | _nibble(bytes[i + 1]))
    return out^


def _nibble(byte: UInt8) raises -> UInt8:
    if byte >= UInt8(ord("0")) and byte <= UInt8(ord("9")):
        return byte - UInt8(ord("0"))
    if byte >= UInt8(ord("a")) and byte <= UInt8(ord("f")):
        return byte - UInt8(ord("a")) + 10
    if byte >= UInt8(ord("A")) and byte <= UInt8(ord("F")):
        return byte - UInt8(ord("A")) + 10
    raise Error("a wire field has something in it that is not a hex digit")


def test_the_http2jp_hpack_vectors_decode() raises:
    var implementations = materialize[IMPLEMENTATIONS]()
    var report = String()
    var failed = 0
    var checked = 0
    var fields = 0

    for i in range(len(implementations)):
        for number in range(STORIES):
            var path = _story_path(implementations[i], number)
            var text = read_corpus(path)
            var document = Json.loads(text)
            var cases = document.value()["cases"]

            # One decoder for the whole story, because the dynamic table each
            # case leaves behind is what the next one indexes against.
            var decoder = HpackDecoder()

            for seqno in range(len(cases)):
                var item = cases[seqno]
                var wire = _unhex(item["wire"].as_string())
                var expected = item["headers"].members()
                checked += 1

                var found: List[HeaderField]
                try:
                    found = decoder.decode(Span(wire))
                except e:
                    failed += 1
                    report += String(
                        "\n  ", path, " case ", seqno, ": ", String(e)
                    )
                    # The rest of the story is decoded against a table that is
                    # now wrong, so reporting every later case would be one
                    # mistake reported ten times.
                    break

                fields += len(found)
                var complaint = _compare(found, expected)
                if complaint:
                    failed += 1
                    report += String(
                        "\n  ", path, " case ", seqno, ": ", complaint.value()
                    )
                    break

    if failed:
        raise Error(String(failed, " hpack story failure(s):", report))

    # Both counts, because a corpus test that reads nothing passes. The cases
    # would still be counted if every block decoded to an empty list, so the
    # fields are counted too, and the numbers are what is in the vendored files.
    assert_equal(checked, 340)
    assert_equal(fields, 3332)


def _compare[
    no: ImmOrigin, to: ImmOrigin
](
    found: List[HeaderField], expected: List[JsonValue[no, to]]
) raises -> Optional[String]:
    """What is wrong with a decoded header list, or nothing.

    Order matters as much as content. HPACK preserves the order a peer sent
    fields in, and a client that reordered them would change the meaning of
    repeated fields such as `set-cookie`.
    """
    if len(found) != len(expected):
        return Optional(
            String("expected ", len(expected), " fields, decoded ", len(found))
        )
    for i in range(len(expected)):
        var names = expected[i].keys()
        if len(names) != 1:
            raise Error("a corpus header object has more than one member")
        var value = expected[i][names[0]].as_string()
        if found[i].name != names[0] or found[i].value != value:
            return Optional(
                String(
                    "field ",
                    i,
                    ": expected ",
                    names[0],
                    ": ",
                    value,
                    ", decoded ",
                    found[i].name,
                    ": ",
                    found[i].value,
                )
            )
    return None
