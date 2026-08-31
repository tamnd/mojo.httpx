"""The JSON parser, the builder and the serializer.

The cases are modelled on JSONTestSuite, Nicolas Seriot's collection of the
documents parsers disagree about, and follow its three categories: `y_` for
what has to be accepted, `n_` for what has to be rejected, and `i_` for what
the specification leaves open. They are written out here rather than vendored,
because the suite is three hundred and eighteen separate files and the vendor
tooling in this repository fetches one file per entry. So this is the same
thinking, not the same bytes, and a document that behaves differently here than
in the real suite is a bug in this file.

The rejection cases matter more than the acceptance ones. Any parser accepts
`{"a": 1}`. What separates them is whether `{"a": 1,}` and `01` and a lone
surrogate get through, and each of those is a place where this client and the
service it is talking to would read the same body as two different things.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from httpx._models.headers import Headers
from httpx._models.json import (
    KIND_ARRAY,
    KIND_BOOL,
    KIND_NULL,
    KIND_NUMBER,
    KIND_OBJECT,
    KIND_STRING,
    MAX_DEPTH,
    Json,
    parse_json,
)
from httpx._models.response import Response


def parse(text: StringSpan) raises -> Json:
    return parse_json(text.as_bytes())


def accepts(text: StringSpan) raises:
    """One `y_` case. Parsing has to succeed, and what it produced has to
    survive being written back out and read again."""
    var first = parse(text)
    var written = String(first)
    var second = parse(written)
    assert_equal(String(second), written)


def rejects(text: StringSpan, mentions: StringSpan) raises:
    """One `n_` case.

    The message is checked as well as the refusal, because a parser that says
    "invalid JSON" for all forty of these is no help to the person holding a
    body they cannot see anything wrong with.
    """
    try:
        var doc = parse(text)
        _ = doc
    except e:
        var message = String(e)
        if mentions not in message:
            raise Error(
                String(
                    "rejected ",
                    text,
                    " for the wrong reason. Wanted the message to mention '",
                    mentions,
                    "', got: ",
                    message,
                )
            )
        return
    raise Error(String("accepted ", text, ", which is not JSON"))


def test_the_smallest_documents_parse() raises:
    assert_equal(parse("null").kind(), KIND_NULL)
    assert_equal(parse("true").as_bool(), True)
    assert_equal(parse("false").as_bool(), False)
    assert_equal(parse("0").as_int(), 0)
    assert_equal(parse('""').as_string(), "")
    assert_equal(len(parse("[]")), 0)
    assert_equal(len(parse("{}")), 0)


def test_y_cases_survive_a_round_trip() raises:
    """Parse, write, parse again, and the second writing has to match.

    A parser and a serializer that agree with each other but not with anybody
    else would still pass every other test in this file. This is the one that
    would notice a string escape written back out wrong, or a number quietly
    losing its exponent.
    """
    accepts("null")
    accepts("[]")
    accepts("{}")
    accepts("[[[[[]]]]]")
    accepts('{"a":{"b":{"c":{}}}}')
    accepts("[0,-0,1,-1,1.5,-1.5,1e10,1E-10,1.5e+10]")
    accepts('["\\u0000","\\u001f","\\"","\\\\","\\/","\\b\\f\\n\\r\\t"]')
    accepts('["é","€","😀","日本語"]')
    accepts('{"":""}')
    accepts('[true,false,null,"",0,{},[]]')
    accepts('{"a":1,"a":2}')


def test_a_bare_scalar_is_a_whole_document() raises:
    # RFC 7159 allowed this and RFC 4627 did not. Everything current allows it,
    # and an API that answers a HEAD-like endpoint with `42` is not wrong.
    assert_equal(parse("42").kind(), KIND_NUMBER)
    assert_equal(parse('"hi"').as_string(), "hi")


def test_whitespace_around_everything() raises:
    var doc = parse(' \t\r\n { \n "a" \t : \r 1 \n } \t ')
    assert_equal(doc["a"].as_int(), 1)


def test_nested_containers() raises:
    var doc = parse('{"a":{"b":{"c":[1,[2,[3]]]}}}')
    assert_equal(doc["a"]["b"]["c"][1][1][0].as_int(), 3)


def test_object_lookup_and_keys() raises:
    var doc = parse('{"one":1,"two":2,"three":3}')
    assert_equal(len(doc), 3)
    assert_true("two" in doc)
    assert_false("four" in doc)
    assert_equal(doc["two"].as_int(), 2)
    var names = doc.keys()
    assert_equal(len(names), 3)
    assert_equal(names[0], "one")
    assert_equal(names[2], "three")


def test_array_indexing_from_both_ends() raises:
    var doc = parse('["a","b","c"]')
    assert_equal(doc[0].as_string(), "a")
    assert_equal(doc[2].as_string(), "c")
    assert_equal(doc[-1].as_string(), "c")
    assert_equal(doc[-3].as_string(), "a")


def test_an_index_past_the_end_says_how_long_the_array_is() raises:
    var doc = parse("[1,2]")
    with assert_raises(contains="which has 2 element"):
        _ = doc[5]
    with assert_raises(contains="which has 2 element"):
        _ = doc[-3]


def test_a_missing_key_lists_the_keys_there_are() raises:
    var doc = parse('{"user_id":1,"user_name":"x"}')
    with assert_raises(contains="'user_id', 'user_name'"):
        _ = doc["userId"]


def test_a_missing_key_on_an_empty_object_says_it_is_empty() raises:
    var doc = parse("{}")
    with assert_raises(contains="it is empty"):
        _ = doc["a"]


def test_get_returns_nothing_rather_than_raising() raises:
    var doc = parse('{"a":1}')
    assert_true(doc.get("a").__bool__())
    assert_false(doc.get("b").__bool__())
    # And on something that is not an object at all, rather than an error,
    # because `get` is the form for code that does not know the shape yet.
    var list = parse("[1]")
    assert_false(list.get("a").__bool__())


def test_the_wrong_type_says_what_was_there_instead() raises:
    var doc = parse('{"count":"12"}')
    with assert_raises(
        contains="expected a number under 'count', found a string"
    ):
        _ = doc["count"].as_int()


def test_asking_an_array_for_a_key() raises:
    var doc = parse("[1,2]")
    with assert_raises(contains="expected an object, found an array"):
        _ = doc["a"]


def test_members_walks_in_document_order() raises:
    var doc = parse('{"a":1,"b":2,"c":3}')
    var total = 0
    var names = String()
    for value in doc.members():
        total += value.as_int()
        names += value.key().value()
    assert_equal(total, 6)
    assert_equal(names, "abc")


def test_the_last_duplicate_key_wins() raises:
    # What Python and JavaScript do. Worth pinning down, because the other
    # answer is just as defensible and a change here would be silent.
    var doc = parse('{"a":1,"a":2,"a":3}')
    assert_equal(doc["a"].as_int(), 3)
    assert_equal(len(doc.keys()), 3)


def test_integers_are_exact_past_what_a_double_holds() raises:
    # 2^53 + 1 is the smallest integer a Float64 cannot represent, and an id
    # arriving as a different number is the bug this design exists to avoid.
    var doc = parse("9007199254740993")
    assert_equal(doc.as_int(), 9007199254740993)


def test_a_number_too_big_for_an_int_says_so() raises:
    var doc = parse("999999999999999999999999")
    with assert_raises(contains="does not fit in an Int"):
        _ = doc.as_int()


def test_a_number_with_a_fraction_is_not_an_int() raises:
    var doc = parse("1.0")
    with assert_raises(contains="not a whole number"):
        _ = doc.as_int()
    assert_equal(doc.as_float(), 1.0)


def test_negative_and_exponent_numbers() raises:
    assert_equal(parse("-7").as_int(), -7)
    assert_equal(parse("1e2").as_float(), 100.0)
    assert_equal(parse("1E+2").as_float(), 100.0)
    assert_equal(parse("1.5e-1").as_float(), 0.15)
    assert_equal(parse("-0").as_int(), 0)


def test_a_number_keeps_the_text_it_arrived_as() raises:
    # Round tripping a number through a Float64 turns 1e2 into 100.0 and
    # 0.1 into something ending in 5551. Keeping the text avoids all of it.
    assert_equal(String(parse("1e2")), "1e2")
    assert_equal(String(parse("0.1")), "0.1")


def test_string_escapes() raises:
    var doc = parse('"a\\"b\\\\c\\/d\\be\\ff\\ng\\rh\\ti"')
    var text = doc.as_string()
    assert_true(text.startswith("a"))
    assert_true('"' in text)
    assert_true("\\" in text)
    assert_true("/" in text)
    assert_true("\n" in text)
    assert_true("\t" in text)


def test_unicode_escapes() raises:
    assert_equal(parse('"\\u0041"').as_string(), "A")
    assert_equal(parse('"\\u00e9"').as_string(), "é")
    assert_equal(parse('"\\u20ac"').as_string(), "€")
    assert_equal(parse('"\\uD83D\\uDE00"').as_string(), "😀")
    # Upper and lower case hexadecimal both, since servers write both.
    assert_equal(parse('"\\u00E9"').as_string(), "é")


def test_an_escaped_nul_survives() raises:
    # An escaped nul is legal JSON and a decoder that carries a length has to
    # keep it. One that treats the bytes as a C string loses everything after
    # it, which is how a filter and a consumer are made to disagree about what
    # a string contains.
    var text = parse('"a\\u0000b"').as_string()
    assert_equal(text.byte_length(), 3)


def test_raw_utf8_passes_through() raises:
    var doc = parse('{"greeting":"héllo wörld 😀"}')
    assert_equal(doc["greeting"].as_string(), "héllo wörld 😀")


def test_serializing_leaves_non_ascii_alone() raises:
    # ensure_ascii=False in Python's terms. Every modern service reads UTF-8
    # and \u escapes only make the body bigger.
    assert_equal(String(parse('"é"')), '"é"')


def test_serializing_escapes_what_it_has_to() raises:
    var doc = Json.object()
    doc.set("k", String('a"b\\c\nd\te\x01f'))
    assert_equal(String(doc), '{"k":"a\\"b\\\\c\\nd\\te\\u0001f"}')


def test_serializing_is_compact() raises:
    assert_equal(String(parse('{ "a" : [ 1 , 2 ] }')), '{"a":[1,2]}')


def test_n_trailing_comma() raises:
    rejects('{"a":1,}', "expected a quoted member name")
    rejects("[1,2,]", "expected a value")


def test_n_missing_comma() raises:
    rejects('{"a":1 "b":2}', "expected ',' or '}'")
    rejects("[1 2]", "expected ',' or ']'")


def test_n_unclosed_containers() raises:
    rejects('{"a":1', "ends before an object is closed")
    rejects("[1,2", "ends before an array is closed")
    rejects('"abc', "ends inside a string")


def test_n_single_quotes() raises:
    rejects("'a'", "double quoted")
    rejects("{'a':1}", "expected a quoted member name")


def test_n_unquoted_key() raises:
    rejects("{a:1}", "expected a quoted member name")


def test_n_missing_colon() raises:
    rejects('{"a" 1}', "expected ':' after the member name")


def test_n_comments() raises:
    rejects("/* nope */ 1", "no comments")
    rejects("// nope", "no comments")


def test_n_python_float_spellings() raises:
    # `json.dumps(float("nan"))` writes NaN by default and nothing else reads
    # it, so this is a real body somebody will hit.
    rejects("NaN", "not JSON")
    rejects("[Infinity]", "not JSON")
    rejects("-Infinity", "a digit after the minus")


def test_n_leading_zero() raises:
    rejects("01", "leading zero")
    rejects("[-01]", "leading zero")


def test_n_leading_plus() raises:
    rejects("+1", "expected a value")


def test_n_incomplete_numbers() raises:
    rejects("1.", "a digit after the point")
    rejects(".5", "expected a value")
    rejects("1e", "a digit in its exponent")
    rejects("1e+", "a digit in its exponent")
    rejects("-", "a digit after the minus")


def test_n_bare_control_character_in_a_string() raises:
    rejects('"a\nb"', "control byte")
    rejects('"a\tb"', "control byte")


def test_n_bad_escapes() raises:
    rejects('"\\x41"', "not an escape JSON has")
    rejects('"\\u00"', "four hexadecimal digits")
    rejects('"\\uZZZZ"', "four hexadecimal digits")
    rejects('"\\', "ends after a backslash")


def test_n_lone_surrogates() raises:
    rejects('"\\uD800"', "has to be followed by the second half")
    rejects('"\\uDC00"', "no first half")
    rejects('"\\uD800\\u0041"', "range \\uDC00 to \\uDFFF")


def test_n_invalid_utf8_in_a_string() raises:
    # A lone 0xFF, which no UTF-8 sequence contains anywhere.
    var body = List[UInt8]()
    body.append(UInt8(ord('"')))
    body.append(0xFF)
    body.append(UInt8(ord('"')))
    with assert_raises(contains="not valid UTF-8"):
        _ = parse_json(Span(body))


def test_n_overlong_utf8_is_not_accepted() raises:
    # 0xC0 0x80 is a nul written the long way. Accepting it is how a filter
    # that scans encoded bytes and a consumer that scans decoded ones are made
    # to disagree about what the string contains.
    var body = List[UInt8]()
    body.append(UInt8(ord('"')))
    body.append(0xC0)
    body.append(0x80)
    body.append(UInt8(ord('"')))
    with assert_raises(contains="not valid UTF-8"):
        _ = parse_json(Span(body))


def test_n_trailing_content() raises:
    rejects("{} {}", "more here than one JSON value")
    rejects("1 2", "more here than one JSON value")
    rejects('"a" garbage', "more here than one JSON value")


def test_n_empty_body() raises:
    rejects("", "the body is empty")
    rejects("   \n  ", "the body is empty")


def test_n_deeply_nested_is_refused_rather_than_crashing() raises:
    # The point of the whole iterative parser. A body that is nothing but
    # brackets has to come back as an error, not as a stack overflow, because
    # a stack overflow is not something the caller can catch.
    var body = String()
    for _ in range(MAX_DEPTH + 10):
        body += "["
    with assert_raises(contains="nested more than"):
        _ = parse(body)


def test_nesting_right_up_to_the_limit_is_fine() raises:
    var body = String()
    for _ in range(MAX_DEPTH):
        body += "["
    body += "1"
    for _ in range(MAX_DEPTH):
        body += "]"
    var doc = parse(body)
    assert_equal(doc.kind(), KIND_ARRAY)


def test_errors_say_where_they_are() raises:
    try:
        _ = parse('{\n  "a": 1,\n  "b": nope\n}')
        raise Error("that should not have parsed")
    except e:
        var message = String(e)
        assert_true("line 3" in message)
        assert_true("column 8" in message)


def test_errors_do_not_paste_raw_bytes_into_the_message() raises:
    # The body is attacker controlled. A newline or an escape sequence in an
    # error message is a small vulnerability of its own, so the excerpt goes
    # through the same escaping every other error in this library uses.
    var body = List[UInt8]()
    body.append(UInt8(ord("[")))
    body.append(0x1B)
    body.append(UInt8(ord("[")))
    body.append(UInt8(ord("3")))
    body.append(UInt8(ord("1")))
    body.append(UInt8(ord("m")))
    try:
        _ = parse_json(Span(body))
        raise Error("that should not have parsed")
    except e:
        var message = String(e)
        assert_true("\\x1b" in message)


def test_building_an_object() raises:
    var doc = Json.object()
    doc.set("name", String("widget"))
    doc.set("count", 3)
    doc.set("price", 9.5)
    doc.set("active", True)
    doc.set("parent", Json.null())
    assert_equal(len(doc), 5)
    assert_equal(doc["name"].as_string(), "widget")
    assert_equal(doc["count"].as_int(), 3)
    assert_true(doc["parent"].is_null())


def test_building_an_array() raises:
    var doc = Json.array()
    doc.append(1)
    doc.append(String("two"))
    doc.append(False)
    assert_equal(String(doc), '[1,"two",false]')


def test_building_nested() raises:
    var inner = Json.object()
    inner.set("b", 2)
    var list = Json.array()
    list.append(inner^)
    list.append(1)
    var doc = Json.object()
    doc.set("a", list^)
    assert_equal(String(doc), '{"a":[{"b":2},1]}')
    assert_equal(doc["a"][0]["b"].as_int(), 2)


def test_setting_a_key_twice_replaces_it() raises:
    # A builder that let a caller write a duplicate would be a builder that
    # produced a document two parsers might read differently.
    var doc = Json.object()
    doc.set("a", 1)
    doc.set("b", 2)
    doc.set("a", 3)
    assert_equal(len(doc), 2)
    assert_equal(doc["a"].as_int(), 3)
    assert_equal(String(doc), '{"b":2,"a":3}')


def test_setting_on_something_that_is_not_an_object() raises:
    var doc = Json.array()
    with assert_raises(contains="Start from Json.object()"):
        doc.set("a", 1)


def test_appending_to_something_that_is_not_an_array() raises:
    var doc = Json.object()
    with assert_raises(contains="Start from Json.array()"):
        doc.append(1)


def test_the_builder_refuses_to_go_past_the_limit() raises:
    var doc = Json.array()
    for _ in range(MAX_DEPTH - 1):
        var outer = Json.array()
        outer.append(doc^)
        doc = outer^
    var one_too_many = Json.array()
    with assert_raises(contains="the limit is"):
        one_too_many.append(doc^)


def test_a_parsed_document_can_be_nested_into_a_built_one() raises:
    var parsed = parse('{"from":"the wire","n":[1,2]}')
    var doc = Json.object()
    doc.set("body", parsed^)
    assert_equal(doc["body"]["from"].as_string(), "the wire")
    assert_equal(doc["body"]["n"][1].as_int(), 2)


def test_to_bytes_is_what_goes_on_the_wire() raises:
    var doc = Json.object()
    doc.set("a", 1)
    var bytes = doc.to_bytes()
    assert_equal(String(StringSpan(from_utf8=Span(bytes))), '{"a":1}')


def test_a_default_document_is_null() raises:
    var doc = Json()
    assert_equal(doc.kind(), KIND_NULL)
    assert_equal(String(doc), "null")


def test_kinds() raises:
    assert_equal(parse("null").kind(), KIND_NULL)
    assert_equal(parse("true").kind(), KIND_BOOL)
    assert_equal(parse("1").kind(), KIND_NUMBER)
    assert_equal(parse('"a"').kind(), KIND_STRING)
    assert_equal(parse("[]").kind(), KIND_ARRAY)
    assert_equal(parse("{}").kind(), KIND_OBJECT)


def test_len_of_a_scalar_is_zero_rather_than_an_error() raises:
    assert_equal(len(parse("1")), 0)
    assert_equal(len(parse('"abcdef"')), 0)


def test_a_realistic_body() raises:
    var doc = parse(
        '{"page":1,"per_page":30,"total":2,"users":[{"id":1,"name":"Ada'
        ' Lovelace","email":null,"admin":true},{"id":2,"name":"Grace'
        ' Hopper","email":"grace@example.com","admin":false}]}'
    )
    assert_equal(doc["total"].as_int(), 2)
    assert_equal(len(doc["users"]), 2)
    assert_equal(doc["users"][0]["name"].as_string(), "Ada Lovelace")
    assert_true(doc["users"][0]["email"].is_null())
    assert_equal(doc["users"][1]["email"].as_string(), "grace@example.com")
    assert_false(doc["users"][1]["admin"].as_bool())


def response_with(
    body: StringSpan, content_type: StringSpan
) raises -> Response:
    var headers = Headers()
    headers.append("content-type", content_type)
    var r = Response(200, String("OK"), String("HTTP/1.1"), headers^)
    r.content.extend(body.as_bytes())
    return r^


def test_response_json_reads_the_body() raises:
    var r = response_with('{"ok":true,"n":2}', "application/json")
    var body = r.json()
    assert_true(body["ok"].as_bool())
    assert_equal(body["n"].as_int(), 2)


def test_response_json_ignores_the_content_type() raises:
    # Real services send JSON labelled text/plain, labelled octet-stream and
    # labelled nothing. Refusing a body that is obviously fine because of a
    # header the caller cannot change would only push them to parse_json.
    var plain = response_with('{"ok":true}', "text/plain")
    assert_true(plain.json()["ok"].as_bool())
    var octets = response_with('{"ok":true}', "application/octet-stream")
    assert_true(octets.json()["ok"].as_bool())


def test_response_json_on_a_body_that_is_not_json() raises:
    var r = response_with("<html>not json</html>", "text/html")
    with assert_raises(contains="not valid JSON"):
        _ = r.json()


def test_response_json_on_an_empty_body() raises:
    # A 204 with no body is the common way to hit this, and "the body is
    # empty" is a more useful thing to read than a column number.
    var r = response_with("", "application/json")
    with assert_raises(contains="the body is empty"):
        _ = r.json()
