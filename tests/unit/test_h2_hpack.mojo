"""Tests for the HPACK tables and the header block coder.

The bulk of this is RFC 7541 appendix C, worked through as the RFC presents it:
whole sequences against one decoder rather than one block at a time. That is not
a stylistic choice. Every block after the first depends on what the ones before
it put in the dynamic table, so a test that decoded C.4.3 on a fresh decoder
would be testing something the protocol never does, and would pass against an
implementation whose table never changed at all.

The appendix gives each sequence twice, plain and Huffman coded. Both are decoded
here. Only the Huffman ones are encoded, because the encoder sends whichever form
is shorter and that is the Huffman one for all of this text, so the plain
sequences are inputs and not expected outputs.

After that come the bounds. The dynamic table is a thing a peer writes into over
the life of a connection, and the index space it shares with the static table
means a decoder that got the accounting slightly wrong would not fail, it would
quietly hand back a different header than the one that was sent.
"""

from std.testing import assert_equal, assert_raises, assert_true

from httpx._bytes import Bytes
from httpx._proto.h2.hpack import HpackDecoder, HpackEncoder
from httpx._proto.h2.table import ENTRY_OVERHEAD, HeaderField, HpackTable

comptime _HEX = StaticString("0123456789abcdef")


def _nib(byte: UInt8) -> Int:
    if byte >= UInt8(ord("a")):
        return Int(byte - UInt8(ord("a"))) + 10
    return Int(byte - UInt8(ord("0")))


def _block(text: StringSpan) -> Bytes:
    """Hexadecimal with the spaces the RFC prints, so a case can be pasted."""
    var source = text.as_bytes()
    var out = Bytes()
    var high = -1
    for i in range(len(source)):
        if source[i] == UInt8(ord(" ")):
            continue
        if high < 0:
            high = _nib(source[i])
        else:
            out.append(UInt8(high * 16 + _nib(source[i])))
            high = -1
    return out^


def _hexed(data: Bytes) -> String:
    var out = String()
    for i in range(len(data)):
        var high = Int(data[i] >> 4)
        var low = Int(data[i] & 0xF)
        out += _HEX[byte = high : high + 1]
        out += _HEX[byte = low : low + 1]
    return out^


def _render(fields: List[HeaderField]) -> String:
    var out = String()
    for i in range(len(fields)):
        out += fields[i].name
        out += ": "
        out += fields[i].value
        out += "\n"
    return out^


def _read(mut decoder: HpackDecoder, text: StringSpan) raises -> String:
    var data = _block(text)
    return _render(decoder.decode(data.as_span()))


def _field(name: StringSpan, value: StringSpan) -> HeaderField:
    return HeaderField(String(name), String(value))


# The four representations, RFC 7541 appendix C.2.


def test_a_literal_with_a_new_name_is_added_to_the_table() raises:
    var decoder = HpackDecoder()
    assert_equal(
        _read(
            decoder,
            "400a 6375 7374 6f6d 2d6b 6579 0d63 7573 746f 6d2d 6865 6164 6572",
        ),
        "custom-key: custom-header\n",
    )
    assert_equal(len(decoder.table), 1)
    assert_equal(decoder.table.size(), 55)
    assert_equal(decoder.table.entry(62).name, "custom-key")


def test_a_literal_without_indexing_leaves_the_table_alone() raises:
    var decoder = HpackDecoder()
    assert_equal(
        _read(decoder, "040c 2f73 616d 706c 652f 7061 7468"),
        ":path: /sample/path\n",
    )
    assert_equal(len(decoder.table), 0)


def test_a_never_indexed_literal_says_so_and_stays_out_of_the_table() raises:
    var decoder = HpackDecoder()
    var data = _block("1008 7061 7373 776f 7264 0673 6563 7265 74")
    var fields = decoder.decode(data.as_span())

    assert_equal(_render(fields), "password: secret\n")
    assert_true(fields[0].sensitive)
    # RFC 7541 section 7.1.3. The flag is the whole point of the
    # representation, so losing it on the way through is the one thing this
    # test is here to catch.
    assert_equal(len(decoder.table), 0)


def test_an_indexed_field_names_the_static_table() raises:
    var decoder = HpackDecoder()
    assert_equal(_read(decoder, "82"), ":method: GET\n")
    assert_equal(len(decoder.table), 0)


# The request sequence, RFC 7541 appendices C.3 and C.4.

comptime _REQUEST_1 = (
    ":method: GET\n:scheme: http\n:path: /\n:authority: www.example.com\n"
)

comptime _REQUEST_2 = (
    ":method: GET\n:scheme: http\n:path: /\n:authority:"
    " www.example.com\ncache-control: no-cache\n"
)

comptime _REQUEST_3 = (
    ":method: GET\n:scheme: https\n:path: /index.html\n:authority:"
    " www.example.com\ncustom-key: custom-value\n"
)


def test_the_plain_request_sequence_decodes() raises:
    var decoder = HpackDecoder()

    assert_equal(
        _read(decoder, "8286 8441 0f77 7777 2e65 7861 6d70 6c65 2e63 6f6d"),
        _REQUEST_1,
    )
    assert_equal(decoder.table.size(), 57)

    assert_equal(
        _read(decoder, "8286 84be 5808 6e6f 2d63 6163 6865"), _REQUEST_2
    )
    assert_equal(decoder.table.size(), 110)

    assert_equal(
        _read(
            decoder,
            (
                "8287 85bf 400a 6375 7374 6f6d 2d6b 6579 0c63 7573 746f 6d2d"
                " 7661 6c75 65"
            ),
        ),
        _REQUEST_3,
    )
    assert_equal(decoder.table.size(), 164)


def test_the_huffman_request_sequence_decodes() raises:
    var decoder = HpackDecoder()

    assert_equal(
        _read(decoder, "8286 8441 8cf1 e3c2 e5f2 3a6b a0ab 90f4 ff"), _REQUEST_1
    )
    assert_equal(decoder.table.size(), 57)

    assert_equal(_read(decoder, "8286 84be 5886 a8eb 1064 9cbf"), _REQUEST_2)
    assert_equal(decoder.table.size(), 110)

    assert_equal(
        _read(
            decoder,
            "8287 85bf 4088 25a8 49e9 5ba9 7d7f 8925 a849 e95b b8e8 b4bf",
        ),
        _REQUEST_3,
    )
    assert_equal(decoder.table.size(), 164)


def _encoded(mut encoder: HpackEncoder, rendered: StringSpan) raises -> String:
    """Encode the header list `rendered` describes, one field per line."""
    var fields = List[HeaderField]()
    for line in String(rendered).splitlines():
        var at = line.find(": ")
        fields.append(
            _field(line[byte=0:at], line[byte = at + 2 : line.byte_length()])
        )
    var out = Bytes()
    encoder.encode(fields, out)
    return _hexed(out)


def test_the_request_sequence_encodes_to_the_huffman_bytes() raises:
    var encoder = HpackEncoder()

    assert_equal(
        _encoded(encoder, _REQUEST_1), "828684418cf1e3c2e5f23a6ba0ab90f4ff"
    )
    assert_equal(_encoded(encoder, _REQUEST_2), "828684be5886a8eb10649cbf")
    assert_equal(
        _encoded(encoder, _REQUEST_3),
        "828785bf408825a849e95ba97d7f8925a849e95bb8e8b4bf",
    )


# The response sequence, RFC 7541 appendices C.5 and C.6. These run with a
# dynamic table of 256 bytes, which is small enough that entries are evicted
# partway through, which is the point of them.

comptime _RESPONSE_1 = (
    ":status: 302\ncache-control: private\ndate: Mon, 21 Oct 2013 20:13:21"
    " GMT\nlocation: https://www.example.com\n"
)

comptime _RESPONSE_2 = (
    ":status: 307\ncache-control: private\ndate: Mon, 21 Oct 2013 20:13:21"
    " GMT\nlocation: https://www.example.com\n"
)

comptime _RESPONSE_3 = (
    ":status: 200\ncache-control: private\ndate: Mon, 21 Oct 2013 20:13:22"
    " GMT\nlocation: https://www.example.com\ncontent-encoding:"
    " gzip\nset-cookie: foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600;"
    " version=1\n"
)


def test_the_plain_response_sequence_decodes_and_evicts() raises:
    var decoder = HpackDecoder(256)

    assert_equal(
        _read(
            decoder,
            (
                "4803 3330 3258 0770 7269 7661 7465 611d 4d6f 6e2c 2032 3120"
                " 4f63 7420 3230 3133 2032 303a 3133 3a32 3120 474d 546e 1768"
                " 7474 7073 3a2f 2f77 7777 2e65 7861 6d70 6c65 2e63 6f6d"
            ),
        ),
        _RESPONSE_1,
    )
    assert_equal(decoder.table.size(), 222)
    assert_equal(len(decoder.table), 4)

    assert_equal(_read(decoder, "4803 3330 37c1 c0bf"), _RESPONSE_2)
    # The new entry did not fit, so the oldest went. Same size, different
    # contents, which is exactly the case a decoder that never evicted would
    # still pass the first block of.
    assert_equal(decoder.table.size(), 222)
    assert_equal(len(decoder.table), 4)

    assert_equal(
        _read(
            decoder,
            (
                "88c1 611d 4d6f 6e2c 2032 3120 4f63 7420 3230 3133 2032 303a"
                " 3133 3a32 3220 474d 54c0 5a04 677a 6970 7738 666f 6f3d 4153"
                " 444a 4b48 514b 425a 584f 5157 454f 5049 5541 5851 5745 4f49"
                " 553b 206d 6178 2d61 6765 3d33 3630 303b 2076 6572 7369 6f6e"
                " 3d31"
            ),
        ),
        _RESPONSE_3,
    )
    assert_equal(decoder.table.size(), 215)
    assert_equal(len(decoder.table), 3)


def test_the_huffman_response_sequence_decodes_and_evicts() raises:
    var decoder = HpackDecoder(256)

    assert_equal(
        _read(
            decoder,
            (
                "4882 6402 5885 aec3 771a 4b61 96d0 7abe 9410 54d4 44a8 2005"
                " 9504 0b81 66e0 82a6 2d1b ff6e 919d 29ad 1718 63c7 8f0b 97c8"
                " e9ae 82ae 43d3"
            ),
        ),
        _RESPONSE_1,
    )
    assert_equal(decoder.table.size(), 222)

    assert_equal(_read(decoder, "4883 640e ffc1 c0bf"), _RESPONSE_2)
    assert_equal(decoder.table.size(), 222)

    assert_equal(
        _read(
            decoder,
            (
                "88c1 6196 d07a be94 1054 d444 a820 0595 040b 8166 e084 a62d"
                " 1bff c05a 839b d9ab 77ad 94e7 821d d7f2 e6c7 b335 dfdf cd5b"
                " 3960 d5af 2708 7f36 72c1 ab27 0fb5 291f 9587 3160 65c0 03ed"
                " 4ee5 b106 3d50 07"
            ),
        ),
        _RESPONSE_3,
    )
    assert_equal(decoder.table.size(), 215)


def test_the_response_sequence_encodes_to_the_huffman_bytes() raises:
    var encoder = HpackEncoder(256)

    assert_equal(
        _encoded(encoder, _RESPONSE_1),
        (
            "488264025885aec3771a4b6196d07abe941054d444a8200595040b8166e082a6"
            "2d1bff6e919d29ad171863c78f0b97c8e9ae82ae43d3"
        ),
    )
    assert_equal(_encoded(encoder, _RESPONSE_2), "4883640effc1c0bf")
    assert_equal(
        _encoded(encoder, _RESPONSE_3),
        (
            "88c16196d07abe941054d444a8200595040b8166e084a62d1bffc05a839bd9ab77ad"
            "94e7821dd7f2e6c7b335dfdfcd5b3960d5af27087f3672c1ab270fb5291f95873160"
            "65c003ed4ee5b1063d5007"
        ),
    )


def test_what_the_encoder_writes_the_decoder_reads_back() raises:
    # The two keep separate tables that only stay in step because every
    # insertion happens in the same order on both sides, so running a sequence
    # through both is the cheapest way to catch a policy that indexes on one
    # side and not the other.
    var encoder = HpackEncoder(256)
    var decoder = HpackDecoder(256)

    assert_equal(_read(decoder, _encoded(encoder, _RESPONSE_1)), _RESPONSE_1)
    assert_equal(_read(decoder, _encoded(encoder, _RESPONSE_2)), _RESPONSE_2)
    assert_equal(_read(decoder, _encoded(encoder, _RESPONSE_3)), _RESPONSE_3)

    assert_equal(encoder.table.size(), decoder.table.size())


def test_a_sensitive_field_round_trips_without_entering_a_table() raises:
    var encoder = HpackEncoder()
    var decoder = HpackDecoder()

    var fields = List[HeaderField]()
    fields.append(HeaderField("authorization", "Bearer hunter2", True))
    var out = Bytes()
    encoder.encode(fields, out)

    var back = decoder.decode(out.as_span())
    assert_equal(_render(back), "authorization: Bearer hunter2\n")
    assert_true(back[0].sensitive)
    assert_equal(len(encoder.table), 0)
    assert_equal(len(decoder.table), 0)


# The table on its own.


def test_the_static_table_is_searched_before_the_dynamic_one() raises:
    var table = HpackTable()
    assert_equal(table.find(":method", "GET"), 2)
    assert_equal(table.find(":method", "POST"), 3)
    assert_equal(table.find_name(":status"), 8)
    assert_equal(table.find("nothing", "here"), 0)
    assert_equal(table.find_name("nothing"), 0)

    # A name that also exists in the static table answers with the static
    # index, which is the one that encodes in the fewest bytes.
    table.add(_field(":status", "418"))
    assert_equal(table.find_name(":status"), 8)
    assert_equal(table.find(":status", "418"), 62)


def test_an_entry_costs_thirty_two_bytes_more_than_it_holds() raises:
    # RFC 7541 section 4.1. Without the overhead a peer could fill a table with
    # empty entries and hand every one of them an index.
    var table = HpackTable()
    table.add(_field("", ""))
    assert_equal(table.size(), ENTRY_OVERHEAD)
    table.add(_field("ab", "cde"))
    assert_equal(table.size(), ENTRY_OVERHEAD * 2 + 5)


def test_the_newest_entry_is_always_index_sixty_two() raises:
    var table = HpackTable()
    table.add(_field("first", "1"))
    table.add(_field("second", "2"))
    assert_equal(table.entry(62).name, "second")
    assert_equal(table.entry(63).name, "first")


def test_an_entry_too_big_for_the_table_empties_it_and_is_dropped() raises:
    # RFC 7541 section 4.4, and it is not an error. Both sides do the same
    # thing and end up with the same empty table, which is all that matters.
    var table = HpackTable(64)
    table.add(_field("small", "one"))
    assert_equal(len(table), 1)

    table.add(_field("a-name-that-does-not-fit-in-sixty-four-bytes", "value"))
    assert_equal(len(table), 0)
    assert_equal(table.size(), 0)


def test_lowering_the_capacity_evicts_down_to_it() raises:
    var table = HpackTable(4096)
    table.add(_field("one", "1"))
    table.add(_field("two", "2"))
    table.add(_field("three", "3"))
    assert_equal(len(table), 3)

    table.set_capacity(80)
    # Two entries at thirty six each is over eighty, so the oldest goes.
    assert_equal(len(table), 2)
    assert_equal(table.entry(62).name, "three")

    table.set_capacity(0)
    assert_equal(len(table), 0)
    assert_equal(table.size(), 0)


def test_a_capacity_above_what_we_advertised_is_refused() raises:
    # Clamping instead would leave the peer indexing against the size it asked
    # for while we evict at a different point, and from the first eviction
    # onwards every index would name a different header on each side.
    var table = HpackTable(4096)
    table.set_capacity(4096)
    with assert_raises():
        table.set_capacity(4097)
    with assert_raises():
        table.set_capacity(-1)


def test_lowering_the_limit_lowers_the_capacity_with_it() raises:
    var table = HpackTable(4096)
    table.add(_field("one", "1"))
    table.add(_field("two", "2"))

    table.set_limit(40)
    assert_equal(table.capacity(), 40)
    assert_equal(len(table), 1)


# The bounds a peer runs into.


def test_an_index_of_zero_addresses_nothing() raises:
    var decoder = HpackDecoder()
    # `80` is an indexed field with an index of zero.
    with assert_raises():
        _ = _read(decoder, "80")


def test_an_index_past_the_end_of_the_table_is_refused() raises:
    var decoder = HpackDecoder()
    # `be` is index 62, and nothing has been added to the dynamic table.
    with assert_raises():
        _ = _read(decoder, "be")


def test_a_literal_naming_a_missing_index_is_refused() raises:
    var decoder = HpackDecoder()
    with assert_raises():
        _ = _read(decoder, "7e 03 61 62 63")


def test_a_table_size_update_partway_through_a_block_is_refused() raises:
    # RFC 7541 section 4.2. An update in the middle changes what every index
    # after it means, so the rest of the block would be decoded against a table
    # the encoder never had.
    var decoder = HpackDecoder()
    assert_equal(_read(decoder, "20 82"), ":method: GET\n")

    var again = HpackDecoder()
    with assert_raises():
        _ = _read(again, "82 20")


def test_a_table_size_update_over_the_limit_is_refused() raises:
    var decoder = HpackDecoder(256)
    # `3f e1 01` is a size update of 256, which is exactly the limit.
    assert_equal(_read(decoder, "3f e1 01"), "")
    assert_equal(decoder.table.capacity(), 256)

    var again = HpackDecoder(256)
    # One more than the limit.
    with assert_raises():
        _ = _read(again, "3f e2 01")


def test_a_header_list_over_the_ceiling_is_refused() raises:
    # The HPACK bomb. Four octets name the same entry four times, and each one
    # costs the full accounted size of it, so what comes out is not bounded by
    # what came in.
    var decoder = HpackDecoder(4096, 200)
    var big = String()
    for _ in range(100):
        big += "x"

    var fields = List[HeaderField]()
    fields.append(_field("name", big))
    var out = Bytes()
    var encoder = HpackEncoder()
    encoder.encode(fields, out)
    assert_equal(len(decoder.decode(out.as_span())), 1)

    var repeat = Bytes()
    repeat.extend(out.as_span())
    # `be` is index 62, which is the entry the block above just added.
    repeat.append(0xBE)
    var again = HpackDecoder(4096, 200)
    with assert_raises():
        _ = again.decode(repeat.as_span())


def test_the_ceiling_counts_the_accounted_size_and_not_the_bytes_sent() raises:
    # Three indexed fields are three octets on the wire and well over two
    # hundred bytes of header list, which is the distinction the bound has to
    # be on.
    var decoder = HpackDecoder(4096, 200)
    assert_equal(len(decoder.decode(_block("82").as_span())), 1)
    with assert_raises():
        _ = decoder.decode(_block("82 86 84 82 86").as_span())


def test_a_block_that_stops_partway_through_a_field_is_refused() raises:
    var decoder = HpackDecoder()
    # A literal with a new name, announcing ten bytes of name and sending four.
    with assert_raises():
        _ = _read(decoder, "40 0a 6375 7374")
