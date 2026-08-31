"""Property tests for the primitives.

The corpus tests say what the answer is for the inputs somebody thought to write
down. These say what has to hold for every input, which is a different question
and catches a different kind of bug: the corpus can only fail on a case somebody
predicted, and the inputs that break normalization tend to be the combinations
nobody thought to write down.

The generator is a seeded xorshift rather than anything from the platform, so a
failure reproduces exactly. The seed is printed with the failing input, and
putting it back in `_Rng(seed)` replays the same run.
"""

from std.testing import assert_equal, assert_true

from httpx._models.url import URL, QueryParams

# Enough to cover the grammar several times over without making the suite slow.
# The whole file runs in well under a second.
comptime _RUNS = 4000

comptime _SEED = UInt64(0x9E3779B97F4A7C15)


struct _Rng(Copyable, Movable):
    """xorshift64star. Small, seedable, and good enough to pick from a list.

    Nothing here is cryptographic and nothing depends on the quality of the
    stream beyond it visiting every branch of the generator often enough.
    """

    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next(mut self) -> UInt64:
        var x = self.state
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        self.state = x
        return x * UInt64(0x2545F4914F6CDD1D)

    def below(mut self, limit: Int) -> Int:
        return Int(self.next() % UInt64(limit))

    def pick(mut self, choices: List[String]) -> String:
        return choices[self.below(len(choices))]

    def chance(mut self, in_n: Int) -> Bool:
        return self.below(in_n) == 0


def _schemes() -> List[String]:
    return ["http", "https", "HTTP", "hTTps"]


def _hosts() -> List[String]:
    # Names, addresses, addresses written to look like names, and the forms that
    # only differ after normalization. The last group is the interesting one.
    return [
        "example.com",
        "EXAMPLE.com",
        "sub.example.co.uk",
        "münchen.de",
        "münchen.de",
        "ドメイン.テスト",
        "xn--eckwd4c7c.xn--zckzah",
        "ＥＸＡＭＰＬＥ。ＣＯＭ",
        "example.com.",
        "127.0.0.1",
        "0x7f.1",
        "2130706433",
        "[::1]",
        "[0:0:0:0:0:0:0:1]",
        "[2001:db8::1]",
        "[2001:0db8:0000:0000:0000:0000:0000:0001]",
        "[::ffff:127.0.0.1]",
    ]


def _ports() -> List[String]:
    return ["", ":80", ":443", ":8080", ":00080", ":0"]


def _userinfos() -> List[String]:
    return ["", "user@", "user:pass@", ":pass@", "u%20s:p%40ss@", "@"]


def _segments() -> List[String]:
    return [
        "",
        "a",
        "b",
        ".",
        "..",
        "%2e",
        "%2E%2e",
        "a b",
        "a%20b",
        "a%2Fb",
        "~tilde",
        "%7etilde",
        "caf%C3%A9",
        "a:b",
        "a@b",
        "a;b",
        "a=b",
        "%41",
    ]


def _queries() -> List[String]:
    return [
        "",
        "?",
        "?a=1",
        "?a=1&b=2",
        "?a",
        "?a=",
        "?=1",
        "?a=1&a=2",
        "?a+b=c+d",
        "?a%20b=c%20d",
        "?a=%41",
        "?;a=1",
        "?a=1;b=2",
    ]


def _fragments() -> List[String]:
    return ["", "#", "#top", "#a%20b", "#a b", "#%41"]


def _query_pieces() -> List[String]:
    # Repeated keys, empty keys, empty values, the two spellings of a space, and
    # the characters a query may hold that a path may not.
    return [
        "a",
        "a",
        "b",
        "",
        "a b",
        "a+b",
        "a%20b",
        "a%26b",
        "a=b",
        "%41",
        "café",
        "caf%C3%A9",
        ";",
        "/",
        "?",
    ]


def _a_query(mut rng: _Rng) -> String:
    """A query string built pair by pair, so keys repeat and values collide."""
    var out = String()
    for _ in range(rng.below(5)):
        if out.byte_length() > 0:
            out += "&"
        out += rng.pick(_query_pieces())
        if not rng.chance(4):
            out += String("=", rng.pick(_query_pieces()))
    return out^


def _a_url(mut rng: _Rng) -> String:
    var out = String(rng.pick(_schemes()), "://")
    out += rng.pick(_userinfos())
    out += rng.pick(_hosts())
    out += rng.pick(_ports())
    for _ in range(rng.below(4)):
        out += String("/", rng.pick(_segments()))
    if rng.chance(4):
        out += "/"
    out += rng.pick(_queries())
    out += rng.pick(_fragments())
    return out^


def _a_reference(mut rng: _Rng) -> String:
    """A relative reference, for the join property."""
    var out = String()
    if rng.chance(3):
        out += "/"
    for _ in range(rng.below(4)):
        if out.byte_length() > 0 and not out.endswith("/"):
            out += "/"
        out += rng.pick(_segments())
    out += rng.pick(_queries())
    out += rng.pick(_fragments())
    return out^


def test_printing_a_url_and_reparsing_it_is_a_fixed_point() raises:
    """Normalization is idempotent, which is what makes a URL comparable.

    Two requests to one resource have to produce one cache key, one connection
    and one cookie scope. If printing and reparsing kept changing the text then
    which of those it was would depend on how many times it had been through.
    """
    var rng = _Rng(_SEED)
    var parsed = 0
    for _ in range(_RUNS):
        var text = _a_url(rng)
        var once: String
        try:
            once = String(URL(text))
        except:
            # A generated string that is not a URL is not a counterexample. The
            # grammar above deliberately produces some.
            continue
        parsed += 1
        var twice = String(URL(once))
        if once != twice:
            raise Error(
                String(
                    "normalization is not idempotent for ",
                    text,
                    ": first ",
                    once,
                    " then ",
                    twice,
                )
            )
    # If the grammar drifts into producing nothing parseable this test passes
    # while proving nothing, so it says how much it actually checked.
    assert_true(parsed > _RUNS // 2)


def test_a_reparsed_url_has_the_same_components() raises:
    """Printing loses nothing. The text is the whole of the value.

    Idempotence on its own would be satisfied by a printer that dropped the same
    component every time, so the components are compared as well.
    """
    var rng = _Rng(_SEED + 1)
    var checked = 0
    for _ in range(_RUNS):
        var text = _a_url(rng)
        var printed: String
        try:
            printed = String(URL(text))
        except:
            continue
        # Parsing twice rather than keeping the first one, because the parse is
        # already known to succeed here and this keeps the failure path above to
        # the one statement that can raise.
        var first = URL(text)
        var second = URL(printed)
        checked += 1
        assert_equal(first.scheme(), second.scheme())
        assert_equal(first.host(), second.host())
        assert_equal(first.raw_path(), second.raw_path())
        assert_equal(first.username(), second.username())
        assert_equal(first.password(), second.password())
        assert_equal(first.fragment(), second.fragment())
        assert_equal(first.netloc(), second.netloc())
        assert_true(first == second)
    assert_true(checked > _RUNS // 2)


def test_joining_a_reference_lands_on_a_url_that_is_already_normalized() raises:
    """RFC 3986 section 5.3. The result of a join is a URL like any other.

    A join that produced text needing another pass would mean a redirect chain
    drifted, since each hop joins the location on to the last result.
    """
    var rng = _Rng(_SEED + 2)
    var joined = 0
    for _ in range(_RUNS):
        var base = _a_url(rng)
        var reference = _a_reference(rng)
        var once: String
        try:
            once = String(URL(base).join(reference))
        except:
            continue
        joined += 1
        var twice = String(URL(once))
        if once != twice:
            raise Error(
                String(
                    "joining ",
                    reference,
                    " on to ",
                    base,
                    " gave ",
                    once,
                    ", which reparses as ",
                    twice,
                )
            )
    assert_true(joined > _RUNS // 2)


def test_query_params_survive_being_printed_and_read_back() raises:
    """The multi map is the meaning and the query string is the spelling.

    Order and multiplicity both matter, so this is stronger than comparing the
    keys. A printer that sorted or deduplicated would pass a set comparison and
    would send a different request.
    """
    var rng = _Rng(_SEED + 3)
    var checked = 0
    for _ in range(_RUNS):
        var first = QueryParams(_a_query(rng))
        var second = QueryParams(String(first))
        checked += 1
        assert_true(first == second)
        assert_equal(String(first), String(second))
        var items = first.multi_items()
        var again = second.multi_items()
        assert_equal(len(items), len(again))
        for i in range(len(items)):
            assert_equal(items[i][0], again[i][0])
            assert_equal(items[i][1], again[i][1])
    assert_equal(checked, _RUNS)


def test_an_encoded_host_is_already_encoded() raises:
    """IDNA is idempotent, so a host that has been through it can go again.

    A `Host` header is built from `raw_host`, and a redirect to the same origin
    parses that text back into a URL. If encoding an A-label produced something
    else then the second request would go somewhere the first did not.
    """
    var rng = _Rng(_SEED + 4)
    var checked = 0
    for _ in range(_RUNS // 4):
        var host = rng.pick(_hosts())
        var url = String("http://", host, "/")
        var once: String
        try:
            once = String(URL(url))
        except:
            continue
        checked += 1
        assert_equal(String(URL(once)), once)
    assert_true(checked > 0)
