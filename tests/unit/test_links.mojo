"""Tests for the `Link` header parser.

Two groups. One is the syntax that makes this a parser rather than a pair of
splits: a quoted parameter value can hold both separators, and a header carries
several links at once. The other is that nothing raises, because the header is
optional and arrives from the network, so a malformed one has to come back as no
links rather than as a failure to use the response.

The comma cases are the ones worth reading. httpx2 splits on a regular expression
and loses everything after a value containing a comma, which is not an exotic
input: a `title` is prose written by a person.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._util.links import Link, parse_links


def _links(value: StringSpan) -> List[Link]:
    return parse_links(value.as_bytes())


def _param(link: Link, name: StringSpan) raises -> String:
    var found = link.param(name)
    if not found:
        raise Error("no parameter named " + String(name))
    return found.value()


def test_one_link_with_one_parameter() raises:
    var found = _links('<https://api/items?page=2>; rel="next"')
    assert_equal(len(found), 1)
    assert_equal(found[0].url, "https://api/items?page=2")
    assert_equal(_param(found[0], "rel"), "next")


def test_several_links_keep_their_order() raises:
    var found = _links(
        '<https://api/1>; rel="prev", <https://api/3>; rel="next"'
    )
    assert_equal(len(found), 2)
    assert_equal(found[0].url, "https://api/1")
    assert_equal(found[1].url, "https://api/3")


def test_an_unquoted_parameter_value_is_read() raises:
    var found = _links("</a>; rel=next")
    assert_equal(len(found), 1)
    assert_equal(_param(found[0], "rel"), "next")


def test_a_quoted_value_may_hold_a_comma() raises:
    # The case httpx2's regular expression drops. A title is prose and prose has
    # commas in it.
    var found = _links('<https://api/2>; rel="next"; title="Volume 2, part 1"')
    assert_equal(len(found), 1)
    assert_equal(_param(found[0], "title"), "Volume 2, part 1")


def test_a_quoted_link_value_may_hold_a_semicolon() raises:
    var found = _links('</a>; rel="next"; title="one; two"; type="text/html"')
    assert_equal(_param(found[0], "title"), "one; two")
    assert_equal(_param(found[0], "type"), "text/html")


def test_a_quoted_value_may_hold_an_equals_sign() raises:
    # httpx2 stops reading parameters at the first value with an `=` in it,
    # because it splits on every one rather than the first.
    var found = _links('</a>; rel="next"; title="a=b"; type="text/html"')
    assert_equal(_param(found[0], "title"), "a=b")
    assert_equal(_param(found[0], "type"), "text/html")


def test_a_backslash_escapes_a_quote() raises:
    var found = _links('</a>; title="say \\"hi\\""')
    assert_equal(_param(found[0], "title"), 'say "hi"')


def test_parameter_names_are_lowercased_and_values_are_not() raises:
    var found = _links('</a>; REL="Next"')
    assert_equal(_param(found[0], "rel"), "Next")


def test_a_relative_target_is_left_alone() raises:
    # Resolving needs the response URL, which the parser does not have.
    var found = _links("</items?page=2>; rel=next")
    assert_equal(found[0].url, "/items?page=2")


def test_rel_may_name_several_relations() raises:
    var found = _links('</a>; rel="next preload"')
    assert_true(found[0].has_rel("next"))
    assert_true(found[0].has_rel("preload"))
    assert_false(found[0].has_rel("prev"))


def test_a_relation_is_matched_case_insensitively() raises:
    var found = _links('</a>; rel="Next"')
    assert_true(found[0].has_rel("next"))
    assert_true(found[0].has_rel("NEXT"))


def test_a_relation_is_matched_whole() raises:
    # `next` must not match inside `nextpage`, which is a different relation.
    var found = _links('</a>; rel="nextpage"')
    assert_false(found[0].has_rel("next"))


def test_space_around_the_relations_is_not_a_relation() raises:
    # A `rel` with space at either end leaves the walk over it standing at the
    # end of the value with nothing between where the token started and where it
    # stopped. That empty stretch is not a relation, and matching it would mean
    # `has_rel("")` answering yes to a link that has no such thing.
    var found = _links('</a>;   rel="  next preload  "')
    assert_true(found[0].has_rel("next"))
    assert_true(found[0].has_rel("preload"))
    assert_false(found[0].has_rel("prev"))
    assert_false(found[0].has_rel(""))
    assert_false(_links('</a>; rel="next"')[0].has_rel(""))


def test_a_link_with_no_rel_reports_an_empty_one() raises:
    var found = _links("</a>")
    assert_equal(found[0].rel(), "")
    assert_false(found[0].has_rel("next"))
    assert_false(found[0].has_rel(""))


def test_a_parameter_with_no_value_is_dropped() raises:
    var found = _links('</a>; noval; rel="next"')
    assert_false(found[0].has_param("noval"))
    assert_true(found[0].has_param("rel"))
    assert_true(found[0].has_rel("next"))


def test_a_parameter_with_no_value_at_the_end_is_dropped_too() raises:
    # The same case with nothing after it, which is where the walk runs out of
    # header rather than finding the next separator.
    var found = _links("</a>; noval")
    assert_equal(len(found), 1)
    assert_equal(found[0].url, "/a")
    assert_false(found[0].has_param("noval"))
    assert_equal(len(found[0].names), 0)


def test_the_separators_do_not_need_a_space_after_them() raises:
    # The space is conventional rather than required, and writing the parser
    # against headers that all have one is how a separator ends up being read as
    # two characters.
    var found = _links('</a>;rel="prev",</b>;rel="next";title="x"')
    assert_equal(len(found), 2)
    assert_equal(found[0].url, "/a")
    assert_true(found[0].has_rel("prev"))
    assert_equal(found[1].url, "/b")
    assert_true(found[1].has_rel("next"))
    assert_equal(_param(found[1], "title"), "x")


def test_space_between_the_equals_and_the_value_is_dropped() raises:
    # One space and then three, and neither is an accident. A walk that steps
    # over two bytes at a time clears a run of two and lands in the same place,
    # so a test written with two spaces would not notice it eating the first
    # character of the value.
    assert_equal(_param(_links("</a>; rel= next")[0], "rel"), "next")
    assert_equal(_param(_links('</a>; title=   "x"')[0], "title"), "x")


def test_an_unquoted_value_stops_at_the_separator() raises:
    # The value has an odd number of characters on purpose. A walk that moves
    # two at a time steps straight over the semicolon that ends an even length
    # one and lands on the same answer.
    var found = _links("</a>; type=text/html; rel=next")
    assert_equal(_param(found[0], "type"), "text/html")
    assert_equal(_param(found[0], "rel"), "next")


def test_a_header_that_stops_after_a_separator_is_still_one_link() raises:
    # Malformed and it still has to come back as something. Each of these ends
    # exactly where the parser is looking for the next thing, which is the
    # position every walk in here has to stop at rather than read past.
    for text in ["</a>;", "</a>; ", "</a>; rel=", "</a>,"]:
        var found = _links(text)
        assert_equal(len(found), 1)
        assert_equal(found[0].url, "/a")


def test_an_escaped_quote_does_not_close_a_value() raises:
    # The last two bytes are a backslash and a quote, so the quote is escaped
    # and the value runs off the end of the header. Reading it as the closing
    # quote instead gives back a title one character short and a header that is
    # suddenly well formed, which is the wrong answer in the quieter way.
    assert_equal(_param(_links('</a>; title="a\\"')[0], "title"), 'a"')


def test_a_backslash_ending_a_link_header_escapes_nothing() raises:
    # There is no next character for it to escape, so it is a literal. The check
    # that makes it one is also what keeps the parser from reading a byte past
    # the end of the header.
    assert_equal(_param(_links('</a>; title="a\\')[0], "title"), "a\\")


# Nothing here raises, and nothing here guesses.


def test_an_empty_header_is_no_links() raises:
    assert_equal(len(_links("")), 0)


def test_a_header_with_no_brackets_is_no_links() raises:
    # A bare URL is as likely to be a stray comma inside a parameter as it is to
    # be a link somebody meant, so it is skipped rather than guessed at.
    assert_equal(len(_links("https://api/2; rel=next")), 0)


def test_an_unterminated_target_is_still_read() raises:
    var found = _links("<https://api/2; rel=next")
    assert_equal(len(found), 1)
    assert_equal(found[0].url, "https://api/2; rel=next")


def test_an_unterminated_quote_takes_the_rest_of_the_value() raises:
    var found = _links('</a>; title="unfinished')
    assert_equal(_param(found[0], "title"), "unfinished")


def test_one_malformed_link_does_not_eat_the_next_one() raises:
    var found = _links('</a> junk here; rel="next", </b>; rel="prev"')
    assert_equal(len(found), 2)
    assert_equal(found[1].url, "/b")
    assert_true(found[1].has_rel("prev"))

    # The junk above is an even number of bytes, so a walk stepping over two at
    # a time lands on the semicolon anyway. This one is odd and it does not.
    var odd = _links('</a> junk; rel="next"')
    assert_equal(len(odd), 1)
    assert_true(odd[0].has_rel("next"))


def test_a_link_writes_back_out_readably() raises:
    var found = _links('</a>; rel="next"')
    assert_equal(String(found[0]), '</a>; rel="next"')
