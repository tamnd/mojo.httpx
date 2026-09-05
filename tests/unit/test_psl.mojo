"""Tests for the Public Suffix List lookup.

Most of the weight is on the vendored reference corpus, because the two rule
kinds that make this non obvious, wildcards and exceptions, only show up in a
handful of real suffixes and hand written cases tend to miss exactly those. The
cases written out here are the ones that describe why the lookup exists at all,
which the corpus does not say anywhere.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._util._psl_data import PSL_RULES
from httpx._util.idna import encode_host
from httpx._util.psl import (
    is_public_suffix,
    public_suffix_start,
    registrable_domain,
    rule_count,
    source_digest,
)
from tests.corpus import quoted_fields, read_corpus


def _registrable(host: StringSpan) raises -> String:
    return String(StringSpan(from_utf8=registrable_domain(host.as_bytes())))


def _suffix(host: StringSpan) raises -> String:
    var bytes = host.as_bytes()
    return String(
        StringSpan(
            from_utf8=bytes[public_suffix_start(bytes) : bytes.__len__()]
        )
    )


def test_the_embedded_table_was_actually_generated() raises:
    # A lookup against an empty table answers no to everything, which reads as a
    # working cookie jar with the public suffix check quietly switched off. This
    # is the assertion that fails loudly instead.
    assert_true(rule_count() > 5000)
    assert_equal(source_digest().byte_length(), 64)


def test_the_reference_corpus_passes() raises:
    # The list's own cases, run as written. Unicode inputs go through the same
    # A-label conversion a request would use, since that is the form the table
    # holds and the form a cookie domain is compared in.
    var checked = 0
    for line in read_corpus("psl/test_psl.txt").split("\n"):
        var trimmed = line.strip()
        if not trimmed.startswith("checkPublicSuffix("):
            continue
        var fields = quoted_fields(trimmed)
        if len(fields) == 0:
            # `checkPublicSuffix(null, null)`, the no input case.
            continue
        var host: String
        try:
            host = encode_host(fields[0])
        except e:
            # The cases that start with a dot, which the list expects to have no
            # registrable domain. A leading empty label is a name no resolver
            # answers, so this layer never sees one, and a rejection is the same
            # answer the corpus is asking for. A case that names an answer is a
            # different matter and still has to produce it.
            if len(fields) > 1:
                raise e
            checked += 1
            continue
        var want = String()
        if len(fields) > 1:
            want = encode_host(fields[1])
        var found = _registrable(host)
        if found != want:
            raise Error(
                String(
                    "registrable domain of ",
                    fields[0],
                    " is ",
                    found,
                    ", expected ",
                    want,
                )
            )
        checked += 1
    # The corpus is around eighty cases. Anything far below that means the
    # parsing above stopped matching the file and the run proved nothing.
    assert_true(checked > 70)


def test_every_rule_in_the_table_is_reachable() raises:
    # The lookup binary searches the blob and walks back to the newline before
    # wherever it lands, so a rule is found through its neighbours rather than
    # through an offset of its own. That makes the first and last lines the ones
    # the walk has to stop at, and neither the corpus nor a case written by hand
    # names either of them. This asks the table about every rule it holds.
    var plain = 0
    var wildcards = 0
    var exceptions = 0
    for rule in String(PSL_RULES).split("\n"):
        if rule.startswith("!"):
            # An exception pulls one name back out of the wildcard above it, so
            # the name is registrable rather than a suffix of its own.
            var body = rule[byte = 1 : rule.byte_length()]
            assert_false(is_public_suffix(body.as_bytes()))
            exceptions += 1
        elif rule.startswith("*."):
            # A wildcard makes every name directly under it a suffix. The label
            # put under it is nonsense on purpose, so that no exception rule in
            # the list can be naming the same one.
            var under = String("zzqqx.", rule[byte = 2 : rule.byte_length()])
            assert_true(is_public_suffix(under.as_bytes()))
            wildcards += 1
        else:
            assert_true(is_public_suffix(rule.as_bytes()))
            plain += 1
    assert_equal(plain + wildcards + exceptions, rule_count())
    assert_true(wildcards > 0)
    assert_true(exceptions > 0)


def test_an_empty_host_has_no_suffix_to_speak_of() raises:
    # Both of these are public and a caller reaches them without going through
    # `registrable_domain`, which is the one that turns an empty name away
    # earlier. The offset has to stay something the caller can slice with, and
    # the answer has to be no, since an empty name is not a suffix.
    var empty = String("")
    assert_equal(public_suffix_start(empty.as_bytes()), 0)
    assert_false(is_public_suffix(empty.as_bytes()))


def test_a_one_byte_host_is_an_unknown_top_level_domain() raises:
    # Nothing in the list is one byte long, so this falls to the implicit `*`
    # and the whole host is the suffix. Worth naming because one byte is the
    # shortest host the walk over the labels ever gets handed.
    assert_true(is_public_suffix("x".as_bytes()))
    assert_equal(public_suffix_start("x".as_bytes()), 0)
    assert_equal(_registrable("a.x"), "a.x")


def test_an_empty_label_matches_no_rule() raises:
    # A trailing dot leaves an empty last label. No rule is empty, so the lookup
    # for one has to come back no rather than match whatever the search last
    # landed on. Matching would make `com.` a public suffix, and then a cookie
    # for it would be dropped for every site under `com`.
    assert_false(is_public_suffix("com.".as_bytes()))
    assert_equal(public_suffix_start("com.".as_bytes()), 4)


def test_a_bare_suffix_has_no_registrable_domain() raises:
    # This is the whole point. A Set-Cookie with one of these as its Domain would
    # otherwise apply to every site registered underneath it.
    for suffix in ["com", "co.uk", "org", "github.io", "s3.amazonaws.com"]:
        assert_true(is_public_suffix(suffix.as_bytes()))
        assert_equal(_registrable(suffix), "")


def test_an_ordinary_name_is_not_a_suffix() raises:
    for host in ["example.com", "example.co.uk", "user.github.io"]:
        assert_false(is_public_suffix(host.as_bytes()))


def test_the_registrable_domain_is_the_suffix_plus_one_label() raises:
    assert_equal(_registrable("www.example.com"), "example.com")
    assert_equal(_registrable("a.b.c.example.co.uk"), "example.co.uk")
    assert_equal(_registrable("user.github.io"), "user.github.io")


def test_a_wildcard_rule_makes_every_name_under_it_a_suffix() raises:
    # `*.ck` is in the list, so `test.ck` is a suffix of its own rather than a
    # registrable name under `ck`.
    assert_true(is_public_suffix("test.ck".as_bytes()))
    assert_equal(_registrable("test.ck"), "")
    assert_equal(_registrable("a.test.ck"), "a.test.ck")


def test_an_exception_rule_pulls_one_name_back_out() raises:
    # `!www.ck` cancels the wildcard for that one name, so `www.ck` is
    # registrable even though every one of its siblings is not.
    assert_false(is_public_suffix("www.ck".as_bytes()))
    assert_equal(_registrable("www.ck"), "www.ck")
    assert_equal(_registrable("a.www.ck"), "www.ck")
    assert_equal(_suffix("www.ck"), "ck")


def test_an_unknown_top_level_domain_is_treated_as_a_suffix() raises:
    # The implicit `*` rule. Without it a made up TLD would look registrable and
    # a cookie could be scoped to all of it.
    assert_true(is_public_suffix("nosuchtld".as_bytes()))
    assert_equal(_registrable("example.nosuchtld"), "example.nosuchtld")
    assert_equal(_registrable("a.b.example.nosuchtld"), "example.nosuchtld")


def test_suffix_lookup_ignores_case() raises:
    # The table is lower case. A host that arrives otherwise has to find its rule
    # rather than miss and be reported as registrable, which is the direction
    # that fails open.
    assert_true(is_public_suffix("CO.UK".as_bytes()))
    assert_equal(_registrable("WWW.EXAMPLE.COM"), "EXAMPLE.COM")


def test_a_malformed_name_has_no_registrable_domain() raises:
    # A leading, trailing or doubled dot is not a hostname. Answering for one
    # would mean deciding that `.com` is registrable.
    for host in [".com", ".example.com", "example.com.", "a..com", ""]:
        assert_equal(_registrable(host), "")


def test_an_internationalized_suffix_is_matched_in_a_label_form() raises:
    # The table holds A-labels, so a Unicode name has to be converted before it
    # is looked up. Comparing the display form would miss every rule that came
    # from a non ASCII entry.
    assert_true(is_public_suffix(encode_host("公司.cn").as_bytes()))
    assert_equal(_registrable(encode_host("食狮.公司.cn")), encode_host("食狮.公司.cn"))
    assert_equal(
        _registrable(encode_host("www.食狮.公司.cn")), encode_host("食狮.公司.cn")
    )


def test_a_deep_name_resolves_to_the_same_site() raises:
    # Two hosts belong to the same site when they share a registrable domain,
    # which is the comparison the cookie jar makes.
    assert_equal(
        _registrable("a.b.c.d.e.example.com"), _registrable("other.example.com")
    )
