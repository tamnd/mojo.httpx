"""Mutation testing for the parsers: break the code and expect a red suite.

A passing test suite says the code does what the tests say. It does not say the
tests would notice if the code stopped doing it. This changes one operator, one
boundary or one constant at a time, runs the tests that claim to cover the file
it changed, and asks whether they failed. A mutant the tests kill is behaviour
somebody has actually pinned down. A mutant that survives is a line that runs in
every test and is asserted about in none of them, which is the thing a coverage
percentage cannot tell you and the reason this exists.

The census next door checks the other half of the same question. It says every
public name is mentioned somewhere; this says the mentions bite. Neither is
worth much on its own.

Only the parsers are in the table below, because that is where the M9 gate puts
the bar and because it is where a silent wrong answer is worst: a header parser
that accepts one byte too many is a security bug, and a URL parser off by one is
a request to the wrong host. The client and the pool are mostly plumbing over
these, and their failures are loud.

    pixi run mutate                         a sample of every target
    pixi run mutate --target url            one file
    pixi run mutate --limit 0               every mutant, which takes hours
    pixi run mutate --workers 5             five at once, a tree each
    pixi run mutate --list                  count the sites and run nothing

A full pass is a long run, not something a commit waits for. Each mutant is a
build and a test run, which is a couple of seconds for a small target and most
of a minute for HTTP/2, so this belongs beside the fuzzers: run deliberately,
on the fleet, and read afterwards. The default sample is small enough to try by
hand and is drawn with a fixed seed, so two runs of the same revision do the
same work.

Every target is timed unmutated first. That is a check that the suite is green
before anything is changed, since a red suite kills every mutant and reports a
perfect score, and it is where the timeout comes from. A comparison turned the
wrong way round is a parser that never returns, and a run with no bound on it is
a worker wedged for the rest of the pass.

`ACCEPTED` holds the mutants that survive and should, each with a reason, keyed
by the line they change so an entry goes stale when the line moves under it.
They are equivalent mutants rather than gaps: a loop bound the step never
reaches, a sentinel every caller tests only the sign of, an early return that
gives the same answer as falling through, a retry count for something that
cannot happen. An accepted mutant that starts being killed fails the run, the
same rule the census and the parity suite use.
"""

import argparse
import concurrent.futures
import os
import queue
import random
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "tools" / "mojotest" / "run.py"

# Source file, and the substring that selects the tests for it. The filter goes
# to the test runner, which matches it against both the test name and the module
# path, so `test_h2` is every HTTP/2 module and `cookie` catches the client and
# corpus files as well as the parser's own.
#
# Narrow on purpose. A mutant is a question about the tests written for a file,
# and running the whole suite for each one would take the answer from whichever
# unrelated test happened to notice, at forty times the cost. `--confirm`
# re-runs a survivor against everything before believing it, which is the
# expensive check done only where it matters.
TARGETS = [
    ("httpx/_models/url.mojo", "test_url"),
    ("httpx/_models/headers.mojo", "test_headers"),
    ("httpx/_models/json.mojo", "test_json"),
    ("httpx/_models/cookies.mojo", "cookie"),
    ("httpx/_content/multipart.mojo", "test_multipart"),
    ("httpx/_util/date.mojo", "test_date"),
    ("httpx/_util/links.mojo", "test_links"),
    ("httpx/_util/media.mojo", "test_media"),
    ("httpx/_util/percent.mojo", "test_percent"),
    ("httpx/_util/ip.mojo", "test_ip"),
    ("httpx/_util/psl.mojo", "test_psl"),
    ("httpx/_util/base64.mojo", "test_base64"),
    ("httpx/_util/charset.mojo", "test_charset"),
    ("httpx/_util/idna.mojo", "idna"),
    ("httpx/_proto/h1/head.mojo", "test_h1"),
    ("httpx/_proto/h1/framing.mojo", "test_h1"),
    ("httpx/_proto/h1/body.mojo", "test_h1"),
    ("httpx/_proto/h1/machine.mojo", "test_h1"),
    ("httpx/_proto/h2/frames.mojo", "test_h2"),
    ("httpx/_proto/h2/hpack.mojo", "test_h2"),
    ("httpx/_proto/h2/huffman.mojo", "test_h2"),
    ("httpx/_proto/h2/table.mojo", "test_h2"),
    ("httpx/_proto/h2/primitives.mojo", "test_h2"),
    ("httpx/_proto/h2/blocks.mojo", "test_h2"),
    ("httpx/_proto/h2/settings.mojo", "test_h2"),
    ("httpx/_proto/h2/window.mojo", "test_h2"),
    ("httpx/_proto/h2/validate.mojo", "test_h2"),
]

# Mutants that survive and are allowed to. The key is the path, the change and
# the line as written, so editing the line retires the entry rather than letting
# it cover whatever the line becomes.
ACCEPTED = {
    "httpx/_util/base64.mojo :: for shift in range(18, -1, -6): ::"
    " for shift in range(18, -2, -6):": (
        "The stop is exclusive and the step is 6, so the sequence is 18, 12, 6,"
        " 0 against either bound. No test can tell these apart because they are"
        " the same loop."
    ),
    "httpx/_content/multipart.mojo :: comptime ATTEMPTS = 8 ::"
    " comptime ATTEMPTS = 9": (
        "How many times to redraw a boundary that collided. The first draw is"
        " 16 random bytes, so the second one never happens and no test can"
        " arrange for it to."
    ),
    "httpx/_content/multipart.mojo :: var dot = -1 :: var dot = -2": (
        "Where the last dot was, before one has been found. It is only ever"
        " compared against zero and only ever used after a dot has overwritten"
        " it, so any negative starting value means the same thing."
    ),
    "httpx/_content/multipart.mojo :: if ext.__len__() == 0: ::"
    " if ext.__len__() == 1:": (
        "An early return for a filename with no extension. It is a shortcut"
        " rather than a decision, since an empty extension matches nothing in"
        " the table below it and falls out to the same default. Nothing in that"
        " table is one character either, so the mutated test returns the same"
        " answer for every input."
    ),
    # Four of a kind in the `Link` parser. Every walk in it stops on `at < n`,
    # so a guard that lets `at` reach n + 1 instead of n changes nothing that
    # any later line looks at. They are what keeps `at` from running past the
    # end of the header, and that is a read nobody can write an assertion about.
    "httpx/_util/links.mojo :: while at < n: :: while at <= n:": (
        "The loop over the links. Entered one more time with `at` at the end of"
        " the header, where the first thing it does is break."
    ),
    "httpx/_util/links.mojo :: if at < n: :: if at <= n:": (
        "Stepping over the closing bracket, the closing quote or the comma."
        " With any of the three missing this leaves `at` one past the end"
        " rather than at it, and every loop after it stops on `at < n`."
    ),
    "httpx/_util/media.mojo :: if at < n: :: if at <= n:": (
        "Stepping over the closing quote of a parameter value. With the quote"
        " missing this moves `at` from n to n + 1 instead of leaving it at n,"
        " and every loop after it stops on `at < n`, so the parse ends in the"
        " same place either way."
    ),
    "httpx/_util/percent.mojo :: return -1 :: return -2": (
        "The sentinel out of `_hex_value`. Both callers ask whether it is"
        " negative and neither one uses the value, so any negative number is"
        " the same answer."
    ),
    # Three of a kind in `Headers`. The index inside `origin_of` in a return
    # type names which value the returned span borrows from, and every entry in
    # the list has the same origin, so the number in it is not read at runtime
    # and is not even required to be a position the list has.
    "httpx/_models/headers.mojo ::"
    " ) -> Optional[Span[UInt8, origin_of(self._list[0].value._data)]]: ::"
    " ) -> Optional[Span[UInt8, origin_of(self._list[1].value._data)]]:": (
        "The origin on the return of `get_span`."
    ),
    "httpx/_models/headers.mojo ::"
    " ) -> Span[UInt8, origin_of(self._list[0].raw_name._data)]: ::"
    " ) -> Span[UInt8, origin_of(self._list[1].raw_name._data)]:": (
        "The origin on the return of `raw_name`."
    ),
    "httpx/_models/headers.mojo ::"
    " ) -> Span[UInt8, origin_of(self._list[0].value._data)]: ::"
    " ) -> Span[UInt8, origin_of(self._list[1].value._data)]:": (
        "The origin on the return of `raw_value`."
    ),
    # Both of these are inside `_count`, which exists only so that `__eq__` can
    # compare its answer for one side against its answer for the other. Adding
    # the same number to both counts, or doubling both, leaves every comparison
    # between them saying what it said.
    "httpx/_models/headers.mojo :: var total = 0 :: var total = 1": (
        "Where the count of matching field lines starts."
    ),
    "httpx/_models/headers.mojo :: total += 1 :: total += 2": (
        "What each matching field line adds to the count."
    ),
    # `_compare_line` hands back an ordering, and the only caller asks whether
    # it is zero and then whether it is negative. So the size of a non zero
    # answer is not read, and neither is the difference between the two ways of
    # writing a comparison that has already ruled equality out.
    "httpx/_util/psl.mojo :: if line[i] < want: :: if line[i] <= want:": (
        "Reached only when the two bytes differ, so equal cannot arise here."
    ),
    "httpx/_util/psl.mojo ::"
    " if line.__len__() < total: :: if line.__len__() <= total:": (
        "Reached only when the two lengths differ, one line above."
    ),
    "httpx/_util/psl.mojo :: return -1 :: return -2": (
        "The sign that says the rule sorts first. Two sites, same reason."
    ),
    "httpx/_util/psl.mojo :: return 1 :: return 2": (
        "The sign that says the rule sorts last. Two sites, same reason."
    ),
    "httpx/_util/psl.mojo :: if order < 0: :: if order <= 0:": (
        "Zero returned one line above, so this cannot see it."
    ),
    "httpx/_util/psl.mojo :: if order < 0: :: if order < 1:": (
        "The same comparison written the other way."
    ),
    # No rule in the list is a single byte, and none of the exception rules is a
    # single label. Both of these guards only ever fire on shapes the table
    # cannot hold, so moving where they fire changes nothing anyone can see.
    "httpx/_util/psl.mojo ::"
    " if body.__len__() == 0: :: if body.__len__() == 1:": (
        "A one byte rule would have to exist for this to matter."
    ),
    "httpx/_util/psl.mojo ::"
    " if host.__len__() == 0: :: if host.__len__() == 1:": (
        "Same, in `public_suffix_start`. A one byte host falls to the implicit"
        " `*` rule and gets the 0 the guard returns anyway."
    ),
    "httpx/_util/psl.mojo :: if i + 1 < count: :: if i - 1 < count:": (
        "Guards the label after an exception match. Reaching it on the last"
        " label needs a single label exception rule, and the list has none."
    ),
    "httpx/_util/psl.mojo :: if i + 1 < count: :: if i + 1 <= count:": (
        "The same guard, off by one the other way."
    ),
    # Two in the walk over the labels of a host, each skipping a position that
    # an earlier check has already made impossible to reach.
    "httpx/_util/psl.mojo ::"
    " for i in range(1, host.__len__()):"
    " :: for i in range(2, host.__len__()):": (
        "The doubled dot scan. The pair it skips starts at a leading dot, which"
        " the check two lines above already turned away."
    ),
    "httpx/_util/psl.mojo ::"
    " if host[i] == _DOT and host[i - 1] == _DOT:"
    " :: if host[i] == _DOT and host[i + 1] == _DOT:": (
        "The same scan looking at the other neighbour. A pair of dots is found"
        " from either end of it, and the one position where that is not true is"
        " a trailing dot, which is turned away above."
    ),
    "httpx/_util/psl.mojo ::"
    " for i in range(start - 1): :: for i in range(start - 2):": (
        "The walk back for the label left of the suffix. The byte it skips is"
        " the last one of that label, and a dot there would be a doubled dot"
        " that `_has_empty_label` already rejected."
    ),
    # Three bounds in the binary search over the rule blob. The search walks
    # back from wherever it lands to the newline before it, so a probe anywhere
    # inside a rule reads that whole rule, and shifting a bound by one byte
    # changes which probes get taken rather than which rules can be reached.
    "httpx/_util/psl.mojo :: var low = 0 :: var low = 1": (
        "Where the search starts. The first rule is longer than a byte, so an"
        " interval that opens at 1 still has room for a probe inside it, and"
        " that probe walks back to 0 and reads the rule whole."
    ),
    "httpx/_util/psl.mojo ::"
    " while start > 0 and data[start - 1] != _NEWLINE:"
    " :: while start > 1 and data[start - 1] != _NEWLINE:": (
        "The walk back, stopping a byte short, and only ever for the first"
        " rule. That rule is `!city.kawasaki.jp`, and `!` is the lowest byte"
        " the table uses, so reading the rule without its first byte can only"
        " make it sort later than it should, which sends the search left. The"
        " probe after that is offset 0, where the walk back has nothing to do"
        " and the rule is read whole."
    ),
    "httpx/_util/psl.mojo :: low = end + 1 :: low = end + 2": (
        "A byte into the next rule rather than at its start. Same recovery,"
        " and no rule is short enough for the shift to empty the interval."
    ),
    # `_has_empty_label` guards its own reads before it answers anything: the
    # two lines under this one index the host, and an empty span has nothing at
    # either end to index. Which answer the guard gives is a separate question,
    # and nobody can tell. `registrable_domain` is the only caller, it hands
    # back a slice that begins at `public_suffix_start`, and that returns 0 for
    # an empty host too, so either answer comes out as the empty name.
    "httpx/_util/psl.mojo :: if host.__len__() == 0:"
    " :: return True :: return False": (
        "The empty host guard, named through the line above it because"
        " `return True` is written four times in this file and the other"
        " three are being killed."
    ),
    # The cookie sentinels. `_EXPIRED` says the docstring beside it out loud,
    # and `_find` hands back a position that every caller tests with `< 0`.
    "httpx/_models/cookies.mojo :: comptime _EXPIRED = -1"
    " :: comptime _EXPIRED = -2": (
        "Any instant in the past does the same job, which is what the docstring"
        " under this line says."
    ),
    "httpx/_models/cookies.mojo :: return i :: return -1 :: return -2": (
        "The miss from `_find`. Named through the line above it because"
        " `return -1` is written more than once in this file."
    ),
    # Boundaries a line above has already ruled out. Each of these is reached
    # only when the two things being compared are known to differ, so the case
    # the mutant moves across the boundary cannot arrive here.
    "httpx/_models/cookies.mojo :: if h.__len__() <= d.__len__():"
    " :: if h.__len__() < d.__len__():": (
        "Equal lengths were settled by the `equal_ascii_ci` two lines above."
        " With the mutant they reach the suffix compare instead, which is that"
        " same comparison again and returns the same no."
    ),
    "httpx/_models/cookies.mojo :: if request.__len__() < cookie.__len__():"
    " :: if request.__len__() <= cookie.__len__():": (
        "Equal lengths returned one line above."
    ),
    "httpx/_models/cookies.mojo :: return l > r :: return l >= r": (
        "Reached only when the two lengths differ, one line above."
    ),
    # `default_path` runs after the caller has established that the path starts
    # with a slash, so the scan always finds one and `last` is always written.
    "httpx/_models/cookies.mojo :: var last = -1 :: var last = -2": (
        "The value `last` never keeps, since a slash is always found."
    ),
    "httpx/_models/cookies.mojo :: if last <= 0: :: if last <= 1:": (
        "A last slash at position 1 gives `bytes[0:1]`, which is the same `/`"
        " the guard returns."
    ),
    # The `Set-Cookie` parser uses -1 for absent throughout, and asks about it
    # with `>= 0` or `< 0`. Position 0 is a separate case from absent, and in
    # each of these the two are already handled the same way or cannot arise.
    "httpx/_models/cookies.mojo :: if split < 0: :: if split <= 0:": (
        "A pair starting with `=` has an empty name, which is rejected four"
        " lines further down for that reason instead."
    ),
    "httpx/_models/cookies.mojo :: if split < 0: :: if split < 1:": (
        "The same comparison written the other way."
    ),
    "httpx/_models/cookies.mojo ::"
    " while i >= 0 and i < bytes.__len__():"
    " :: while i > 0 and i < bytes.__len__():": (
        "The attribute walk starts at the first semicolon and then only ever"
        " takes positions found from `i + 1`, so it is never handed 0. A"
        " semicolon at 0 leaves an empty pair, which was rejected above."
    ),
    "httpx/_models/cookies.mojo ::"
    " while i >= 0 and i < bytes.__len__():"
    " :: while i >= 1 and i < bytes.__len__():": (
        "The same bound written the other way."
    ),
    "httpx/_models/cookies.mojo ::"
    " while i >= 0 and i < bytes.__len__():"
    " :: while i >= 0 and i <= bytes.__len__():": (
        "`i` is a position a semicolon was found at, or -1, so it is never the"
        " length itself and the loop cannot be entered with nothing left."
    ),
    "httpx/_models/cookies.mojo ::"
    " bytes[start:stop] if stop >= 0 else bytes[start : bytes.__len__()]"
    " :: bytes[start:stop] if stop > 0 else bytes[start : bytes.__len__()]": (
        "The next semicolon, searched for from `start`, which is at least 1, so"
        " it is never found at 0."
    ),
    "httpx/_models/cookies.mojo ::"
    " bytes[start:stop] if stop >= 0 else bytes[start : bytes.__len__()]"
    " :: bytes[start:stop] if stop >= 1 else bytes[start : bytes.__len__()]": (
        "The same position written the other way."
    ),
    # Two halves of reading one attribute. An attribute written as `=value` has
    # no name, and a nameless attribute matches none of the names the parser
    # looks for, so it is skipped whichever of these two shapes it takes.
    "httpx/_models/cookies.mojo ::"
    " var key = _trim(attribute[0:mark]) if mark >= 0 else _trim(attribute)"
    " :: var key = _trim(attribute[0:mark]) if mark > 0"
    " else _trim(attribute)": (
        "The name, which comes out as `=value` rather than empty. Neither is an"
        " attribute this parser knows."
    ),
    "httpx/_models/cookies.mojo :: >= 0 else attribute[0:0]"
    " :: > 0 else attribute[0:0]": (
        "The value of that same nameless attribute, which is never read because"
        " the name never matches."
    ),
}

# How many mutants per target when no limit is given. Small enough that a run
# over every target is minutes rather than hours, and the sample is drawn with
# a fixed seed so it is the same sample every time.
DEFAULT_LIMIT = 12


def masked(text):
    """`text` with every string and comment blanked out, same length.

    Mutating inside a string literal changes a message rather than a decision,
    and mutating inside a comment changes nothing at all, but both would still
    build and both would then be reported as survivors forever. Blanking them
    first means the search never sees them, and keeping the length lets an
    offset found in the mask be applied to the original.
    """
    out = list(text)
    at = 0
    end = len(text)
    while at < end:
        char = text[at]
        if char == "#":
            while at < end and text[at] != "\n":
                out[at] = " "
                at += 1
            continue
        if char in "\"'":
            quote = text[at : at + 3]
            if quote in ('"""', "'''"):
                closing, width = quote, 3
            else:
                closing, width = char, 1
            for i in range(at, at + width):
                out[i] = " "
            at += width
            while at < end:
                if text[at] == "\\":
                    # An escaped quote does not close the literal, and neither
                    # does whatever follows a backslash, so both are skipped.
                    for i in range(at, min(at + 2, end)):
                        if text[i] != "\n":
                            out[i] = " "
                    at += 2
                    continue
                if text.startswith(closing, at):
                    for i in range(at, at + width):
                        out[i] = " "
                    at += width
                    break
                if text[at] != "\n":
                    out[at] = " "
                at += 1
            continue
        at += 1
    return "".join(out)


def bumped(match):
    """One more than the integer written, and 1 for a 0.

    Off by one is the mistake this is looking for, so the change is the smallest
    one that is still a change. Hexadecimal and binary literals are left alone
    by the pattern, since a byte mask written in hex reads as a shape rather
    than as a number and the useful mutation of it is a different one.
    """
    return str(int(match.group(0)) + 1)


# Each entry is a label, the pattern to find in the masked source, and what to
# put in its place. The comparison swaps come in both directions because a
# boundary can be wrong either way, and the pair of them is what distinguishes a
# test that checks the edge from one that only checks the middle.
MUTATIONS = [
    ("== to !=", re.compile(r"=="), "!="),
    ("!= to ==", re.compile(r"!="), "=="),
    ("<= to <", re.compile(r"<="), "<"),
    (">= to >", re.compile(r">="), ">"),
    ("< to <=", re.compile(r"(?<![<=!>])<(?![<=])"), "<="),
    ("> to >=", re.compile(r"(?<![<=!>-])>(?![>=])"), ">="),
    ("and to or", re.compile(r"(?<=[ (])and(?= )"), "or"),
    ("or to and", re.compile(r"(?<=[ (])or(?= )"), "and"),
    ("True to False", re.compile(r"\bTrue\b"), "False"),
    ("False to True", re.compile(r"\bFalse\b"), "True"),
    ("plus to minus", re.compile(r"(?<=[\w) ]) \+ (?=[\w(])"), " - "),
    ("minus to plus", re.compile(r"(?<=[\w) ]) - (?=[\w(])"), " + "),
    ("number bumped", re.compile(r"(?<![\w.xb])\d+(?![\w.])"), bumped),
]


class Mutant:
    def __init__(self, path, label, start, stop, replacement, text):
        self.path = path
        self.label = label
        self.start = start
        self.stop = stop
        self.replacement = replacement
        self.line = text.count("\n", 0, start) + 1
        begins = text.rfind("\n", 0, start) + 1
        ends = text.find("\n", start)
        ends = ends if ends >= 0 else len(text)
        whole = text[begins:ends]
        self.source = whole.strip()
        self.after = (
            whole[: start - begins] + replacement + whole[stop - begins :]
        ).strip()
        self.before = ""
        at = begins
        while at > 0:
            head = text.rfind("\n", 0, at - 1) + 1
            above = text[head : at - 1].strip()
            if above:
                self.before = above
                break
            at = head

    def applied(self, text):
        return text[: self.start] + self.replacement + text[self.stop :]

    def keys(self):
        """What an entry in `ACCEPTED` can be written against, narrowest first.

        The line before and the line after, rather than the line and the name of
        the change, because one line often has two mutants of the same kind on
        it and an entry has to mean one of them. Editing the line retires the
        entry, which is the point: an allowance survives only as long as the
        code it was written about.

        That still leaves `return True` in a file with four of them, where one
        entry would speak for all four and three of them are being killed right
        now. So there is a longer form as well, with the nearest line above the
        change in front of the pair, which is what tells those four apart. Use
        the short form unless the file has the same line in it twice.
        """
        return (
            "%s :: %s :: %s :: %s"
            % (self.path, self.before, self.source, self.after),
            "%s :: %s :: %s" % (self.path, self.source, self.after),
        )

    def where(self):
        return "%s:%d" % (self.path, self.line)


def sites(path):
    """Every mutant that can be made in one file, in source order."""
    text = (ROOT / path).read_text()
    hidden = masked(text)
    found = []
    for label, pattern, into in MUTATIONS:
        for match in pattern.finditer(hidden):
            replacement = into(match) if callable(into) else into
            if replacement == match.group(0):
                continue
            found.append(
                Mutant(
                    path, label, match.start(), match.end(), replacement, text
                )
            )
    found.sort(key=lambda one: (one.start, one.label))
    return text, found


def sampled(found, limit, seed):
    if limit <= 0 or limit >= len(found):
        return found
    picked = random.Random(seed).sample(range(len(found)), limit)
    return [found[i] for i in sorted(picked)]


def verdict(answer):
    """What the test run says about a mutant.

    A mutant that does not compile is neither killed nor alive: it is not a
    program, so nothing can be concluded about the tests from it. Told apart by
    what the runner printed rather than by the exit status, because a build
    failure and a failed assertion both come back as one. A mutant that runs out
    of time is counted as killed, since a parser that never returns is a parser
    the tests noticed, however unpleasantly.
    """
    if answer is None:
        return "hung"
    code, output = answer
    if code == 0 and "passed" in output:
        return "survived"
    if "FAIL " in output or "failed" in output:
        return "killed"
    return "no build"


# How long a run gets when the clean one is quick, and what the clean one is
# multiplied by when it is not. A mutant that turns a loop bound the wrong way
# round runs forever, and without a bound that is a worker wedged for the rest
# of the pass rather than one line reported.
FLOOR_SECONDS = 60
SLACK = 5


def run_tests(tree, filter_, seconds):
    """The tests matching `filter_`, or `None` if they ran out of time.

    The runner gets a session of its own so that a timeout can take the whole
    group. It starts `mojo` as a child, and killing only the runner would leave
    the compiler behind, which with several workers is how a machine ends up
    with more builds running than it has cores.
    """
    started = subprocess.Popen(
        [
            sys.executable,
            str(tree / "tools" / "mojotest" / "run.py"),
            "--filter",
            filter_,
            "--fail-fast",
        ],
        cwd=tree,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        out, err = started.communicate(timeout=seconds)
    except subprocess.TimeoutExpired:
        os.killpg(os.getpgid(started.pid), signal.SIGKILL)
        started.communicate()
        return None
    return started.returncode, out + err


def budget(tree, filter_):
    """How long a mutant of this target gets, and a check on the clean tree.

    The tests have to pass before anything is changed. If they do not, every
    mutant looks killed and the run reports a perfect score for a suite that was
    already red. The time the clean run takes is also the only honest basis for
    the timeout, since the targets here range from under two seconds to most of
    a minute.
    """
    started = time.monotonic()
    answer = run_tests(tree, filter_, FLOOR_SECONDS * 30)
    took = time.monotonic() - started
    if verdict(answer) != "survived":
        raise SystemExit(
            "mutate: the tests matching %r do not pass on the clean tree"
            % filter_
        )
    return max(FLOOR_SECONDS, took * SLACK)


def try_one(tree, mutant, original, filter_, seconds):
    """Build and run one mutant, and put the file back whatever happens."""
    target = tree / mutant.path
    target.write_text(mutant.applied(original))
    try:
        return verdict(run_tests(tree, filter_, seconds))
    finally:
        target.write_text(original)


def answers_for(trees, picked, original, filter_, seconds):
    """Every mutant in one target, in order, however many trees there are.

    A worker is a tree of its own rather than a shard of one, because a mutant
    is a file written and then put back and two of them in one directory would
    be testing each other's changes.
    """
    if len(trees) == 1:
        return [
            try_one(trees[0], one, original, filter_, seconds) for one in picked
        ]

    free = queue.Queue()
    for tree in trees:
        free.put(tree)

    def work(one):
        tree = free.get()
        try:
            return try_one(tree, one, original, filter_, seconds)
        finally:
            free.put(tree)

    with concurrent.futures.ThreadPoolExecutor(len(trees)) as pool:
        return list(pool.map(work, picked))


def copied(where):
    """The tree in a temporary directory, so the real one is never edited.

    Mutation means writing broken code into a source file, and doing that in
    place would leave the working tree broken if the run is interrupted, which
    on this project means an interrupted run looks like a bad commit. The copy
    is a few megabytes and the test runner works out its own root from where it
    is, so a copy runs exactly as the original does.
    """
    where.mkdir()
    for part in ("httpx", "tests", "tools"):
        shutil.copytree(ROOT / part, where / part)
    return where


def report(rows, title):
    if not rows:
        return
    print("\n%s" % title)
    for mutant, reason in rows:
        print("  %-34s %s" % (mutant.where(), mutant.label))
        print("    was  %s" % mutant.source)
        print("    now  %s" % mutant.after)
        if reason:
            print("    why  %s" % reason)


def stale_entries(chosen, whole, alive):
    """`ACCEPTED` entries that no longer allow anything.

    An allowance nobody has to justify again is how a gate quietly stops gating,
    so an entry the tests have caught up with is a failure rather than a note.
    Only judged on a full run of the file it belongs to, since a sample almost
    never draws the one line an entry was written about.

    Written as `no survivor has this key` rather than `something with this key
    was killed`, because one file often has the same line in it twice. Both
    copies get the same key, and asking the first question is how an entry that
    is still doing its job gets reported for the copy next to it.
    """
    if not whole:
        return []
    paths = {path for path, _ in chosen}
    return [
        (key, reason)
        for key, reason in ACCEPTED.items()
        if key.split(" :: ")[0] in paths and key not in alive
    ]


def report_stale(rows):
    if not rows:
        return
    print("\nallowed to survive, and nothing does any more")
    for key, reason in rows:
        parts = key.split(" :: ")
        print("  %s" % parts[0])
        if len(parts) > 3:
            print("    under %s" % parts[1])
        print("    was  %s" % parts[-2])
        print("    now  %s" % parts[-1])
        print("    why  %s" % reason)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument(
        "--target",
        help="only targets whose path contains this",
    )
    ap.add_argument(
        "--limit",
        type=int,
        default=DEFAULT_LIMIT,
        metavar="N",
        help="mutants per target, 0 for all of them",
    )
    ap.add_argument(
        "--seed",
        type=int,
        default=0,
        help="which sample to draw, so a run can be repeated",
    )
    ap.add_argument(
        "--workers",
        type=int,
        default=1,
        metavar="N",
        help=(
            "mutants tried at the same time, each in a tree of its own. One by"
            " default, since a Mojo build already uses several cores and the"
            " gain is in the slow targets rather than the quick ones"
        ),
    )
    ap.add_argument(
        "--confirm",
        action="store_true",
        help="re-run each survivor against the whole suite before reporting it",
    )
    ap.add_argument(
        "--list",
        action="store_true",
        help="count the mutants in each target and run nothing",
    )
    args = ap.parse_args()

    chosen = [
        (path, filter_)
        for path, filter_ in TARGETS
        if not args.target or args.target in path
    ]
    if not chosen:
        raise SystemExit("mutate: no target matches %r" % args.target)

    if args.list:
        total = 0
        for path, _ in chosen:
            _, found = sites(path)
            total += len(found)
            print("%6d  %s" % (len(found), path))
        print("\n%d mutation site(s) in %d file(s)" % (total, len(chosen)))
        return

    holder = Path(tempfile.mkdtemp(prefix="mutate-"))
    killed = 0
    hung = 0
    unbuilt = 0
    survivors = []
    accepted = []
    alive = set()
    try:
        trees = [
            copied(holder / ("tree%d" % i))
            for i in range(max(1, args.workers))
        ]
        for path, filter_ in chosen:
            original, found = sites(path)
            picked = sampled(found, args.limit, args.seed)
            seconds = budget(trees[0], filter_)
            print(
                "%s: %d of %d mutant(s), tests matching %r, %ds each at most"
                % (path, len(picked), len(found), filter_, seconds),
                flush=True,
            )
            answers = answers_for(trees, picked, original, filter_, seconds)
            for mutant, answer in zip(picked, answers):
                if answer in ("killed", "hung"):
                    killed += 1
                    hung += answer == "hung"
                    continue
                if answer == "no build":
                    unbuilt += 1
                    continue
                # A survivor of the narrow run is worth the whole suite once,
                # since the filter is a guess about which tests cover the file
                # and being wrong about it would report a mutant the suite does
                # in fact kill.
                if args.confirm:
                    whole = try_one(
                        trees[0], mutant, original, "test_", seconds * 40
                    )
                    if whole in ("killed", "hung"):
                        killed += 1
                        continue
                alive.update(mutant.keys())
                reason = None
                for form in mutant.keys():
                    if form in ACCEPTED:
                        reason = ACCEPTED[form]
                        break
                if reason:
                    accepted.append((mutant, reason))
                else:
                    survivors.append((mutant, ""))
    finally:
        shutil.rmtree(holder, ignore_errors=True)

    stale = stale_entries(chosen, args.limit <= 0, alive)
    report(accepted, "survived, and allowed to")
    report(survivors, "survived")
    report_stale(stale)
    print(
        "\nmutate: %d killed, %d survived, %d allowed, %d did not build"
        % (killed, len(survivors), len(accepted), unbuilt)
    )
    if hung:
        print(
            "%d of the killed ones ran out of time rather than failing" % hung
        )
    if survivors or stale:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
