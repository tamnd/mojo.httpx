"""The http-state cookie corpus, run against the jar.

This is the conformance suite the browsers are checked against, so it is the
closest thing to an answer key that exists for the parts of RFC 6265 that are
underspecified. It is worth far more than hand written cases here, because the
awkward inputs it covers, unterminated quotes, attributes with no value, paths
that differ from the request by one character, are exactly the ones nobody
thinks to write down.

The cases are compiled into a Mojo fixture by tools/gen_cookie_cases.py rather
than parsed here. See that file for why.
"""

from std.testing import assert_equal, assert_true

from httpx._models.cookies import CookieJar
from httpx._models.url import URL
from tests.fixtures.cookie_cases import CookieCase, cookie_cases

comptime CORPUS_NOW = 1434326400
"""15 June 2015, the instant every case in the corpus is run at.

The corpus contains cookies that expire in 1980, 2007, 2019 and 2027 and expects
the first two to be gone and the last two to survive, so it only has one correct
answer at a time somewhere in between. A real clock would make this suite start
failing on its own in 2019, which it now has.
"""


def test_the_http_state_corpus_passes() raises:
    var cases = cookie_cases()
    var failures = String()
    var failed = 0
    for i in range(len(cases)):
        ref item = cases[i]
        var jar = CookieJar()
        var url = URL(item.url)
        for j in range(len(item.received)):
            _ = jar.set_cookie(url, item.received[j], CORPUS_NOW)
        var target = url.join(item.target)
        var found = jar.header_for(target, CORPUS_NOW)
        if found != item.expected:
            failed += 1
            if failed <= 20:
                failures += String(
                    "\n  ",
                    item.name,
                    ": expected '",
                    item.expected,
                    "', found '",
                    found,
                    "'",
                )
    if failed:
        raise Error(
            String(
                failed, " of ", len(cases), " corpus cases failed:", failures
            )
        )
    # A fixture that failed to generate would pass every case in it, so the size
    # is asserted too.
    assert_true(len(cases) > 200)
