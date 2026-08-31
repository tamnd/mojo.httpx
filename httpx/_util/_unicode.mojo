"""Lookups into the generated Unicode tables, and NFC.

The tables are runs of fixed width hexadecimal records sorted by code point, so
every lookup here is the same binary search with a different width. Hexadecimal
rather than packed bytes because a Mojo string literal has to be valid UTF-8 and
a packed table is not, and because a table somebody can read in a diff is a table
somebody can check.

NFC is here rather than in a general text module because IDNA is the only thing
in this library that needs it. UTS-46 requires it: without it, a name typed with
a combining acute and a name typed with the precomposed letter are different
strings, punycode to different labels, and resolve to different hosts, even
though every reader sees the same name.
"""

from httpx._bytes import _hex_digit
from httpx._util._unicode_data import (
    BIDI,
    BIDI_COUNT,
    BIDI_WIDTH,
    COMBINING,
    COMBINING_COUNT,
    COMBINING_WIDTH,
    COMPOSITION,
    COMPOSITION_COUNT,
    COMPOSITION_WIDTH,
    DECOMPOSITION,
    DECOMPOSITION_COUNT,
    DECOMPOSITION_POOL,
    DECOMPOSITION_WIDTH,
    IDNA_MAP,
    IDNA_MAP_COUNT,
    IDNA_MAP_POOL,
    IDNA_MAP_WIDTH,
    JOINING,
    JOINING_COUNT,
    JOINING_WIDTH,
    MARKS,
    MARKS_COUNT,
    MARKS_WIDTH,
)

comptime VALID = UInt8(ord("v"))
comptime IGNORED = UInt8(ord("i"))
comptime MAPPED = UInt8(ord("m"))
comptime DISALLOWED = UInt8(ord("d"))

# The Hangul syllables compose and decompose by arithmetic, which is why they are
# not in the tables. This is Unicode 3.12, transcribed.
comptime _S_BASE = UInt32(0xAC00)
comptime _L_BASE = UInt32(0x1100)
comptime _V_BASE = UInt32(0x1161)
comptime _T_BASE = UInt32(0x11A7)
comptime _L_COUNT = UInt32(19)
comptime _V_COUNT = UInt32(21)
comptime _T_COUNT = UInt32(28)
comptime _N_COUNT = _V_COUNT * _T_COUNT
comptime _S_COUNT = _L_COUNT * _N_COUNT


def _hex_at(table: StaticString, at: Int, width: Int) -> Int:
    var bytes = table.as_bytes()
    var value = 0
    for i in range(at, at + width):
        value = value * 16 + _hex_digit(bytes[i])
    return value


def _find_range(
    table: StaticString, count: Int, width: Int, point: UInt32
) -> Int:
    """The record whose range holds `point`, or -1.

    The records are sorted and do not overlap, which is what makes the halving
    valid. Both are properties of how the table was generated rather than
    anything checked here, so if that ever stops being true this returns a
    plausible wrong answer rather than failing, and the generator is where to
    look.
    """
    var low = 0
    var high = count - 1
    while low <= high:
        var middle = (low + high) // 2
        var at = middle * width
        var first = UInt32(_hex_at(table, at, 6))
        var last = UInt32(_hex_at(table, at + 6, 6))
        if point < first:
            high = middle - 1
        elif point > last:
            low = middle + 1
        else:
            return middle
    return -1


def idna_status(point: UInt32) -> UInt8:
    """What UTS-46 says to do with `point`.

    A code point that is in no range is disallowed. The mapping table covers
    every assigned character, so a gap is an unassigned one, and an unassigned
    character in a hostname is a name that cannot resolve however it is spelled.
    """
    var index = _find_range(IDNA_MAP, IDNA_MAP_COUNT, IDNA_MAP_WIDTH, point)
    if index < 0:
        return DISALLOWED
    return IDNA_MAP.as_bytes()[index * IDNA_MAP_WIDTH + 12]


def idna_mapping(point: UInt32) -> StringSpan[ImmStaticOrigin]:
    """What `point` maps to, for a point whose status is `MAPPED`.

    Sound without a UTF-8 check because the pool was written as UTF-8 by the
    generator and every offset and length in the table is a boundary in it, both
    of which are asserted there.
    """
    var index = _find_range(IDNA_MAP, IDNA_MAP_COUNT, IDNA_MAP_WIDTH, point)
    var at = index * IDNA_MAP_WIDTH
    var offset = _hex_at(IDNA_MAP, at + 13, 5)
    var length = _hex_at(IDNA_MAP, at + 18, 2)
    return StringSpan(
        unsafe_from_utf8=IDNA_MAP_POOL.as_bytes()[offset : offset + length]
    )


def combining_class(point: UInt32) -> Int:
    var index = _find_range(COMBINING, COMBINING_COUNT, COMBINING_WIDTH, point)
    if index < 0:
        return 0
    return _hex_at(COMBINING, index * COMBINING_WIDTH + 12, 2)


def is_mark(point: UInt32) -> Bool:
    """Whether `point` is a combining mark of any kind."""
    return _find_range(MARKS, MARKS_COUNT, MARKS_WIDTH, point) >= 0


def bidi_class(point: UInt32) -> UInt8:
    """The bidi class of `point` as a single letter, or 0 for anything else.

    Only the classes the bidi rule names are in the table. Everything else is one
    bucket, because the rule only ever asks whether a character is one of the
    listed classes.
    """
    var index = _find_range(BIDI, BIDI_COUNT, BIDI_WIDTH, point)
    if index < 0:
        return 0
    return BIDI.as_bytes()[index * BIDI_WIDTH + 12]


def joining_type(point: UInt32) -> UInt8:
    """`D`, `L`, `R`, `C` or `T`, or 0 for non joining, which is the default."""
    var index = _find_range(JOINING, JOINING_COUNT, JOINING_WIDTH, point)
    if index < 0:
        return 0
    return JOINING.as_bytes()[index * JOINING_WIDTH + 12]


def _find_exact(
    table: StaticString, count: Int, width: Int, point: UInt32
) -> Int:
    """The record keyed on exactly `point`, or -1."""
    var low = 0
    var high = count - 1
    while low <= high:
        var middle = (low + high) // 2
        var found = UInt32(_hex_at(table, middle * width, 6))
        if point < found:
            high = middle - 1
        elif point > found:
            low = middle + 1
        else:
            return middle
    return -1


def _decompose_into(point: UInt32, mut out: List[UInt32]):
    """Append the full canonical decomposition of `point` to `out`.

    The table holds decompositions that were already expanded all the way down,
    so this does not recurse and cannot be made to.
    """
    if point >= _S_BASE and point < _S_BASE + _S_COUNT:
        var index = point - _S_BASE
        out.append(_L_BASE + index // _N_COUNT)
        out.append(_V_BASE + (index % _N_COUNT) // _T_COUNT)
        var trailing = index % _T_COUNT
        if trailing != 0:
            out.append(_T_BASE + trailing)
        return

    var found = _find_exact(
        DECOMPOSITION, DECOMPOSITION_COUNT, DECOMPOSITION_WIDTH, point
    )
    if found < 0:
        out.append(point)
        return
    var at = found * DECOMPOSITION_WIDTH
    var offset = _hex_at(DECOMPOSITION, at + 6, 5)
    var length = _hex_at(DECOMPOSITION, at + 11, 2)
    # Sound for the same reason as `idna_mapping`: the pool is UTF-8 the
    # generator wrote and the offsets are boundaries in it.
    var span = StringSpan(
        unsafe_from_utf8=DECOMPOSITION_POOL.as_bytes()[offset : offset + length]
    )
    for codepoint in span.codepoints():
        out.append(codepoint.to_u32())


def _compose(first: UInt32, second: UInt32) -> UInt32:
    """The single character `first` and `second` make, or 0 if they make none.

    Zero is safe as the answer for none because nothing composes to U+0000, so
    there is no need for a second return value nobody would check.
    """
    if first >= _L_BASE and first < _L_BASE + _L_COUNT:
        if second >= _V_BASE and second < _V_BASE + _V_COUNT:
            return (
                _S_BASE
                + ((first - _L_BASE) * _V_COUNT + (second - _V_BASE)) * _T_COUNT
            )
    if first >= _S_BASE and first < _S_BASE + _S_COUNT:
        if (first - _S_BASE) % _T_COUNT == 0:
            if second > _T_BASE and second < _T_BASE + _T_COUNT:
                return first + (second - _T_BASE)

    var low = 0
    var high = COMPOSITION_COUNT - 1
    while low <= high:
        var middle = (low + high) // 2
        var at = middle * COMPOSITION_WIDTH
        var a = UInt32(_hex_at(COMPOSITION, at, 6))
        var b = UInt32(_hex_at(COMPOSITION, at + 6, 6))
        if first < a or (first == a and second < b):
            high = middle - 1
        elif first > a or (first == a and second > b):
            low = middle + 1
        else:
            return UInt32(_hex_at(COMPOSITION, at + 12, 6))
    return 0


def nfc(points: List[UInt32]) -> List[UInt32]:
    """`points` in Normalization Form C.

    The three steps of Unicode 3.11, in order: decompose canonically, put
    combining marks back into canonical order, then compose. Doing it as
    decompose and recompose rather than trying to compose in place is what makes
    it correct for input that is already partly composed, which is most input.
    """
    var decomposed = List[UInt32]()
    for i in range(len(points)):
        _decompose_into(points[i], decomposed)
    _canonical_order(decomposed)
    return _compose_all(decomposed)


def _canonical_order(mut points: List[UInt32]):
    """Sort each run of combining marks by combining class, stably.

    An insertion sort rather than anything cleverer, because the runs are two or
    three characters long in real text and the stability is not optional: two
    marks with the same class are ordered by what the writer typed and reordering
    them would change the string.
    """
    var i = 1
    while i < len(points):
        var this_class = combining_class(points[i])
        if this_class != 0:
            var j = i
            while j > 0:
                var previous = combining_class(points[j - 1])
                if previous == 0 or previous <= this_class:
                    break
                var held = points[j - 1]
                points[j - 1] = points[j]
                points[j] = held
                j -= 1
        i += 1


def _compose_all(points: List[UInt32]) -> List[UInt32]:
    """Unicode 3.11 canonical composition, transcribed.

    A character composes on to the starter only when nothing between them blocks
    it, and what blocks it is a character of equal or higher combining class.
    That is the whole of the `last_class` bookkeeping. The `last_class == 0` arm
    is the case of two starters next to each other, which is not blocked and is
    how the Hangul jamo and a few others join.
    """
    var out = List[UInt32]()
    if len(points) == 0:
        return out^

    var starter_at = 0
    var starter = points[0]
    out.append(starter)
    var last_class = combining_class(starter)
    if last_class != 0:
        # A string that begins with a mark has no starter to compose on to. 256
        # is above every real class, which is how that is said here.
        last_class = 256

    for i in range(1, len(points)):
        var point = points[i]
        var this_class = combining_class(point)
        var composed = _compose(starter, point)
        if composed != 0 and (last_class < this_class or last_class == 0):
            out[starter_at] = composed
            starter = composed
            continue
        if this_class == 0:
            starter_at = len(out)
            starter = point
        last_class = this_class
        out.append(point)
    return out^
