"""How the CLI lays out what it prints, and when it colours it.

The golden suite under `tools/golden/` compares whole runs of the real binary
and is the thing that would catch a change in the output as a whole. These are
the cases underneath it: a JSON document with one awkward feature each, and the
rules that decide whether there is any colour at all. They are here because a
golden file tells you that something changed and not which rule it broke.
"""

from std.testing import assert_equal, assert_true

from httpx.cli.progress import human_size
from httpx.cli.render import format_json
from httpx.cli.style import BOLD, CYAN, Style


def _plain(source: String) raises -> String:
    """`source` laid out with no colour, which is what a pipe would get."""
    var out = format_json(source.as_bytes(), Style(False))
    return String(StringSpan(from_utf8=Span(out)))


def _coloured(source: String) raises -> String:
    var out = format_json(source.as_bytes(), Style(True))
    return String(StringSpan(from_utf8=Span(out)))


def test_an_object_is_laid_out_one_member_to_a_line() raises:
    assert_equal(
        _plain('{"a":1,"b":2}'),
        '{\n  "a": 1,\n  "b": 2\n}\n',
    )


def test_nesting_indents_by_two_spaces_a_level() raises:
    assert_equal(
        _plain('{"a":{"b":[1]}}'),
        '{\n  "a": {\n    "b": [\n      1\n    ]\n  }\n}\n',
    )


def test_an_empty_container_stays_on_one_line() raises:
    # Three lines for `{}` is the thing that makes people turn a formatter off.
    assert_equal(_plain('{"a":{},"b":[]}'), '{\n  "a": {},\n  "b": []\n}\n')


def test_whitespace_the_server_used_is_replaced_rather_than_kept() raises:
    assert_equal(_plain('{  "a" :\n\t1 }'), '{\n  "a": 1\n}\n')


def test_a_number_keeps_the_spelling_it_arrived_with() raises:
    # Not reformatted through a float, because 1.50 and 1e3 are the server's
    # way of writing those and a client that rewrites them is changing data to
    # make it look tidier.
    assert_equal(
        _plain('{"a":1.50,"b":1e3}'), '{\n  "a": 1.50,\n  "b": 1e3\n}\n'
    )


def test_a_string_keeps_its_own_escapes() raises:
    var out = _plain('{"a":"say \\"hi\\"\\u00e9"}')
    assert_true(out.find('"say \\"hi\\"\\u00e9"') >= 0)


def test_a_top_level_value_that_is_not_a_container_is_still_printed() raises:
    assert_equal(_plain("42"), "42\n")


def test_something_that_is_not_json_is_refused_rather_than_guessed_at() raises:
    var raised = False
    try:
        _ = _plain("{oops")
    except:
        raised = True
    assert_true(raised)


def test_a_key_and_a_string_value_are_coloured_differently() raises:
    # The whole point of colouring a body is telling the two apart at a glance,
    # so a change that made them the same colour would be a regression that
    # every golden file would still accept.
    var out = _coloured('{"a":"b"}')
    assert_true(out.find(String("\x1b[", CYAN, 'm"a"\x1b[0m')) >= 0)
    assert_true(out.find('\x1b[32m"b"\x1b[0m') >= 0)


def test_colour_adds_nothing_but_escapes() raises:
    var source = String('{"a":[1,true,null,"b"],"c":{}}')
    var coloured = _coloured(source)
    var plain = _plain(source)
    var bytes = coloured.as_bytes()
    var escape = UInt8(ord("\x1b"))
    var end_of_code = UInt8(ord("m"))
    var stripped = List[UInt8]()
    var i = 0
    while i < len(bytes):
        if bytes[i] == escape:
            while i < len(bytes) and bytes[i] != end_of_code:
                i += 1
            i += 1
            continue
        stripped.append(bytes[i])
        i += 1
    assert_equal(String(StringSpan(from_utf8=Span(stripped))), plain)


def test_a_style_that_is_off_writes_the_text_and_nothing_else() raises:
    assert_equal(Style(False).paint(BOLD, "hello"), "hello")


def test_a_style_that_is_on_wraps_the_text_and_resets_after_it() raises:
    assert_equal(Style(True).paint(BOLD, "hello"), "\x1b[1mhello\x1b[0m")


def test_sizes_below_a_kilobyte_are_counted_in_bytes() raises:
    assert_equal(human_size(0), "0 B")
    assert_equal(human_size(1023), "1023 B")


def test_larger_sizes_get_one_decimal_place() raises:
    assert_equal(human_size(1024), "1.0 KiB")
    assert_equal(human_size(1536), "1.5 KiB")
    assert_equal(human_size(1024 * 1024), "1.0 MiB")
    assert_equal(human_size(3 * 1024 * 1024 + 512 * 1024), "3.5 MiB")
