"""Tests for the generated Unicode tables and for NFC.

The IdnaTestV2 corpus in test_idna_corpus.mojo covers the tables through the
whole of UTS-46, which is thorough but says almost nothing when it breaks: one
wrong record shows up as a few hundred hostnames coming out wrong. These tests go
at the pieces directly, so a table that regenerates wrong says which table.

The normalization cases are written as code points rather than as literals,
because a combining sequence and the precomposed character it normalizes to look
the same in an editor and whether they are the same is the whole question here.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._util._unicode import (
    DISALLOWED,
    IGNORED,
    MAPPED,
    VALID,
    bidi_class,
    combining_class,
    idna_mapping,
    idna_status,
    is_mark,
    joining_type,
    nfc,
)
from httpx._util._unicode_data import UNICODE_VERSION

# Named so the sequences below read as what they are. The class is what decides
# ordering and blocking, so it is worth having in front of you.
comptime ACUTE = UInt32(0x0301)  # class 230, above
comptime DIAERESIS = UInt32(0x0308)  # class 230, above
comptime DOT_ABOVE = UInt32(0x0307)  # class 230, above
comptime GRAVE_BELOW = UInt32(0x0316)  # class 220, below
comptime CEDILLA = UInt32(0x0327)  # class 202, below
comptime OGONEK = UInt32(0x0328)  # class 202, below

comptime LETTER_A = UInt32(0x0061)
comptime LETTER_C = UInt32(0x0063)


def _same(left: List[UInt32], right: List[UInt32]) -> Bool:
    if len(left) != len(right):
        return False
    for i in range(len(left)):
        if left[i] != right[i]:
            return False
    return True


def test_the_tables_come_from_one_release() raises:
    assert_equal(UNICODE_VERSION, "17.0.0")


def test_idna_statuses_are_what_the_mapping_table_says() raises:
    assert_equal(idna_status(LETTER_A), VALID)
    assert_equal(idna_status(UInt32(ord("A"))), MAPPED)
    assert_equal(idna_mapping(UInt32(ord("A"))), "a")
    # Fullwidth latin capital A, the compatibility character a name can be
    # spelled with to look like an ASCII one.
    assert_equal(idna_status(UInt32(0xFF21)), MAPPED)
    assert_equal(idna_mapping(UInt32(0xFF21)), "a")
    # The ideographic full stop separates labels rather than being a character in
    # one, which is why it maps to a dot instead of being rejected.
    assert_equal(idna_mapping(UInt32(0x3002)), ".")
    # A soft hyphen disappears rather than being rejected, so a name with one in
    # it resolves to the name without it.
    assert_equal(idna_status(UInt32(0x00AD)), IGNORED)
    # A noncharacter. Nothing may be spelled with one.
    assert_equal(idna_status(UInt32(0xFDD0)), DISALLOWED)


def test_a_code_point_no_range_covers_is_disallowed() raises:
    # Past the last assigned plane. An unassigned character in a hostname is a
    # name that cannot resolve however it is spelled.
    assert_equal(idna_status(UInt32(0x10FFFE)), DISALLOWED)


def test_combining_classes_and_marks_are_read_off_the_table() raises:
    assert_equal(combining_class(ACUTE), 230)
    assert_equal(combining_class(GRAVE_BELOW), 220)
    assert_equal(combining_class(CEDILLA), 202)
    assert_equal(combining_class(LETTER_A), 0)
    # Devanagari virama, class 9, which is what the ContextJ rules key on.
    assert_equal(combining_class(UInt32(0x094D)), 9)
    assert_true(is_mark(ACUTE))
    assert_false(is_mark(LETTER_A))


def test_bidi_and_joining_types_are_read_off_the_table() raises:
    assert_equal(bidi_class(LETTER_A), UInt8(ord("L")))
    # Hebrew alef is R and Arabic alef is AL. The bidi rule treats the two
    # differently, so collapsing them would let a name through.
    assert_equal(bidi_class(UInt32(0x05D0)), UInt8(ord("R")))
    assert_equal(bidi_class(UInt32(0x0627)), UInt8(ord("A")))
    # Arabic beh joins on both sides, alef only on the right.
    assert_equal(joining_type(UInt32(0x0628)), UInt8(ord("D")))
    assert_equal(joining_type(UInt32(0x0627)), UInt8(ord("R")))
    assert_equal(joining_type(LETTER_A), UInt8(0))


def test_nfc_composes_a_mark_on_to_the_letter_before_it() raises:
    assert_true(_same(nfc([LETTER_A, ACUTE]), [UInt32(0x00E1)]))


def test_nfc_leaves_composed_text_alone() raises:
    assert_true(_same(nfc([UInt32(0x00E1)]), [UInt32(0x00E1)]))


def test_a_mark_with_no_starter_in_front_of_it_stays_a_mark() raises:
    # Nothing to compose on to. It must not reach forward to the letter after it
    # either, which is what the leading class of 256 is for.
    assert_true(_same(nfc([ACUTE, LETTER_A]), [ACUTE, LETTER_A]))


def test_nfc_orders_marks_by_combining_class() raises:
    # 220 sorts before 230 whichever order they were typed in, and then the 230
    # one composes on to what is left. Two spellings of one name have to reach
    # one host.
    var typed_one_way = nfc([LETTER_A, ACUTE, GRAVE_BELOW])
    var typed_the_other = nfc([LETTER_A, GRAVE_BELOW, ACUTE])
    assert_true(_same(typed_one_way, typed_the_other))
    assert_true(_same(typed_one_way, [UInt32(0x00E1), GRAVE_BELOW]))


def test_nfc_does_not_reorder_two_marks_of_the_same_class() raises:
    # Both are class 230, so the order is what the writer typed. Sorting them
    # would change the string rather than normalize it.
    var acute_first = nfc([LETTER_A, ACUTE, DIAERESIS])
    var diaeresis_first = nfc([LETTER_A, DIAERESIS, ACUTE])
    assert_false(_same(acute_first, diaeresis_first))


def test_nfc_does_not_compose_across_a_blocking_mark() raises:
    # The ogonek and the cedilla are both class 202, so they stay in the order
    # they were typed, and the ogonek then blocks the cedilla from reaching the
    # c. Without the blocking check this composes to c cedilla followed by a
    # stray ogonek, which is a different string and a different host.
    assert_true(
        _same(nfc([LETTER_C, OGONEK, CEDILLA]), [LETTER_C, OGONEK, CEDILLA])
    )
    # The same two characters the other way round do compose, which is what
    # makes the case above about blocking rather than about the pair.
    assert_true(_same(nfc([LETTER_C, CEDILLA]), [UInt32(0x00E7)]))


def test_nfc_composes_hangul_by_arithmetic() raises:
    # The jamo are not in the composition table. They compose by the formula in
    # Unicode 3.12, and both the two part and the three part forms have to work.
    assert_true(_same(nfc([UInt32(0x1100), UInt32(0x1161)]), [UInt32(0xAC00)]))
    assert_true(
        _same(
            nfc([UInt32(0x1100), UInt32(0x1161), UInt32(0x11A8)]),
            [UInt32(0xAC01)],
        )
    )


def test_nfc_decomposes_all_the_way_before_composing() raises:
    # U+1E0A is D with dot above. With a cedilla after it the marks reorder, the
    # cedilla composes on to the bare D first, and the result is U+1E10 with the
    # dot left over. Composing in place instead of decomposing first gets this
    # wrong and leaves the two spellings different.
    assert_true(
        _same(nfc([UInt32(0x1E0A), CEDILLA]), [UInt32(0x1E10), DOT_ABOVE])
    )


def test_a_singleton_decomposition_does_not_come_back() raises:
    # The angstrom sign decomposes to A with ring above and never recomposes to
    # the sign. That is what the composition exclusions are for, and without them
    # one name would have two encodings.
    assert_true(_same(nfc([UInt32(0x212B)]), [UInt32(0x00C5)]))
