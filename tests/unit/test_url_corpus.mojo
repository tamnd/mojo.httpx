"""The WHATWG URL corpus, run against `URL`.

The cases are compiled into a Mojo fixture by tools/gen_url_cases.py. See that
file for which ones are here and why the ones that are expected to disagree are
expected to disagree.
"""

from std.testing import assert_true

from httpx._models.url import URL
from tests.fixtures.url_cases import UrlCase, url_cases


def _resolve(item: UrlCase) raises -> String:
    if item.base.byte_length() == 0:
        return String(URL(item.input))
    return String(URL(item.base).join(item.input))


def test_the_whatwg_url_corpus_passes() raises:
    var cases = url_cases()
    var report = String()
    var failed = 0
    for i in range(len(cases)):
        ref item = cases[i]
        var found = String()
        var raised = False
        try:
            found = _resolve(item)
        except:
            raised = True
        var agrees: Bool
        if item.failure:
            agrees = raised
        else:
            agrees = not raised and found == item.href
        if item.divergence.byte_length() > 0:
            # A divergence that stopped diverging is a note describing something
            # that is no longer true, which is worse than no note at all.
            if agrees:
                failed += 1
                report += String(
                    "\n  ",
                    item.input,
                    ": listed as a divergence but now matches, drop the note",
                )
            continue
        if not agrees:
            failed += 1
            report += String("\n  input ", item.input)
            if item.base.byte_length() > 0:
                report += String("\n    base     ", item.base)
            if item.failure:
                report += "\n    expected a rejection"
            else:
                report += String("\n    expected ", item.href)
            if raised:
                report += "\n    found    a rejection"
            else:
                report += String("\n    found    ", found)
    if failed:
        raise Error(String(failed, " of ", len(cases), " url cases:", report))
    assert_true(len(cases) > 400)
