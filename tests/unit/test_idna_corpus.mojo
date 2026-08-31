"""The Unicode IdnaTestV2 corpus, run against `encode_host`.

The cases are compiled into a Mojo fixture by tools/gen_idna_cases.py. See that
file for which columns are used and which status codes are ignored, and why.
"""

from std.testing import assert_true

from httpx._util.idna import encode_host
from tests.fixtures.idna_cases import IdnaCase, idna_cases


def test_the_unicode_idna_corpus_passes() raises:
    var cases = idna_cases()
    var report = String()
    var failed = 0
    for i in range(len(cases)):
        ref item = cases[i]
        var found = String()
        var raised = False
        try:
            found = encode_host(item.source)
        except:
            raised = True
        if item.fails:
            if not raised:
                failed += 1
                report += String(
                    "\n  ",
                    item.source,
                    ": expected a rejection, got ",
                    found,
                )
            continue
        if raised:
            failed += 1
            report += String(
                "\n  ", item.source, ": expected ", item.expected, ", rejected"
            )
        elif found != item.expected:
            failed += 1
            report += String(
                "\n  ",
                item.source,
                ": expected ",
                item.expected,
                ", got ",
                found,
            )
    if failed:
        raise Error(String(failed, " of ", len(cases), " idna cases:", report))
    assert_true(len(cases) > 6000)
