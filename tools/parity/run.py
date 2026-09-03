"""Run every case through both clients and compare what came out.

    pixi run -e parity parity

The suite is in two halves. The request half compares the bytes each client put
on the wire, which is the half the milestone is graded on: two clients that
agree on every API call and disagree on the socket have not agreed on anything.
The response half compares what each client made of an answer written by hand,
because a request nobody can read the reply to is not much use either.

Differences are not failures on their own. Some are settled deliberately and
written down in `docs/deviations.md`, and those are listed in `ACCEPTED` below
with the reason. A difference that is not in that list fails the run, and so
does an entry in the list that no longer matches anything, because a stale
allowance is how a suite like this stops noticing regressions.

This is not part of `pixi run check` and not in CI. It needs a second HTTP
client installed and it starts real sockets, so it is a deliberate step. See
docs/testing.md.
"""

import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

import cases  # noqa: E402
import server  # noqa: E402
import wire  # noqa: E402


# Differences we have decided to live with. Each entry is a case name or `*`, an
# aspect, and the reason. Every one of these has to match something on every
# run: if a difference goes away, the entry goes with it.
ACCEPTED = [
    (
        "*",
        "header:accept-encoding",
        "We ask for `gzip, deflate` and httpx2 also asks for `zstd`, which we"
        " cannot yet undo. Asking for a coding the client cannot decode would"
        " mean handing the caller compressed bytes and calling them the body."
        " This entry goes away with brotli and zstd.",
    ),
    (
        "*",
        "header-order",
        "Both orders are legal and neither carries meaning. We put the headers"
        " the caller set right after `Host` so they are visible at the top of a"
        " trace, and the framing headers last because the writer is what adds"
        " them. httpx2 puts its own defaults first and the caller's after.",
    ),
]


def _report_line(name, response):
    """The same line `emit.mojo` prints, built from an httpx2 response."""
    text = response.text
    return "\t".join(
        [
            name,
            str(response.status_code),
            response.reason_phrase,
            _encoding_label(response.encoding),
            text.encode("utf-8").hex(),
        ]
    )


def _encoding_label(name):
    """One spelling for one encoding.

    Python's codec registry answers with whichever alias it was asked with, so
    the same encoding can come back as `latin_1` or `iso-8859-1` depending on
    the route in. Neither is more correct and the difference says nothing about
    either client.
    """
    if not name:
        return "<none>"
    return name.lower().replace("_", "-")


def run_httpx2(base):
    import httpx2

    lines = []
    for case in cases.CASES:
        with httpx2.Client() as client:
            response = case["send"](client, base)
        if case["kind"] == "response":
            lines.append(_report_line(case["name"], response))
    return lines


def run_mojo(base):
    env = dict(os.environ, PARITY_BASE=base)
    done = subprocess.run(
        ["mojo", "run", "-I", ".", "tools/parity/emit.mojo"],
        cwd=ROOT,
        env=env,
        capture_output=True,
    )
    if done.returncode != 0:
        sys.stderr.write(done.stderr.decode("utf-8", "replace"))
        raise SystemExit("the Mojo side did not finish")
    return [
        line
        for line in done.stdout.decode("utf-8", "replace").splitlines()
        if line.strip()
    ]


def by_case(records):
    out = {}
    for name, raw in records:
        out.setdefault(name, []).append(raw)
    return out


def accepted_for(differences):
    """Split differences into the ones we allow and the ones we do not.

    Also reports which allowances fired, so the caller can complain about the
    ones that did not.
    """
    allowed = []
    unexpected = []
    fired = set()
    for difference in differences:
        match = None
        for index, (case, aspect, _reason) in enumerate(ACCEPTED):
            if aspect != difference.aspect:
                continue
            if case != "*" and case != difference.case:
                continue
            match = index
            break
        if match is None:
            unexpected.append(difference)
        else:
            fired.add(match)
            allowed.append(difference)
    return allowed, unexpected, fired


def main():
    recorder = server.Recorder(
        lambda name: cases.BY_NAME[name]["replies"]
        if name in cases.BY_NAME
        else None
    )
    try:
        theirs_lines = run_httpx2(recorder.base)
        # The server is threaded and the last reply may still be in flight when
        # the client has already returned, so give the recorder a moment before
        # taking the records away from it.
        time.sleep(0.2)
        theirs = by_case(recorder.records)
        theirs_problems = list(recorder.problems)

        recorder.reset()
        ours_lines = run_mojo(recorder.base)
        time.sleep(0.2)
        ours = by_case(recorder.records)
        ours_problems = list(recorder.problems)
    finally:
        recorder.stop()

    failures = []
    for problem in theirs_problems:
        failures.append("httpx2: " + problem)
    for problem in ours_problems:
        failures.append("mojo.httpx: " + problem)

    differences = []
    for case in cases.CASES:
        name = case["name"]
        mine = ours.get(name, [])
        yours = theirs.get(name, [])
        if not mine:
            failures.append("%s: mojo.httpx sent nothing" % name)
            continue
        if not yours:
            failures.append("%s: httpx2 sent nothing" % name)
            continue
        if len(mine) != len(yours):
            failures.append(
                "%s: mojo.httpx sent %d request(s), httpx2 sent %d"
                % (name, len(mine), len(yours))
            )
            continue
        for index in range(len(mine)):
            label = name if len(mine) == 1 else "%s [%d]" % (name, index + 1)
            differences.extend(wire.compare(label, mine[index], yours[index]))

    allowed, unexpected, fired = accepted_for(differences)

    read_mismatches = []
    ours_by_name = {line.split("\t")[0]: line for line in ours_lines}
    theirs_by_name = {line.split("\t")[0]: line for line in theirs_lines}
    for case in cases.CASES:
        if case["kind"] != "response":
            continue
        name = case["name"]
        mine = ours_by_name.get(name)
        yours = theirs_by_name.get(name)
        if mine is None or yours is None:
            # Not folded into the comparison below, because two missing lines
            # are equal to each other and a silent pass is the one outcome this
            # suite must never produce.
            failures.append(
                "%s: no report line from %s"
                % (name, "mojo.httpx" if mine is None else "httpx2")
            )
        elif mine != yours:
            read_mismatches.append((name, mine, yours))

    stale = [
        ACCEPTED[i] for i in range(len(ACCEPTED)) if i not in fired
    ]

    request_cases = sum(1 for c in cases.CASES if c["kind"] == "request")
    response_cases = sum(1 for c in cases.CASES if c["kind"] == "response")
    print(
        "%d request case(s), %d response case(s), %d request(s) compared"
        % (request_cases, response_cases, sum(len(v) for v in ours.values()))
    )
    print(
        "%d difference(s), %d accepted"
        % (len(differences), len(allowed))
    )
    print()

    for name, reason in [(a, r) for _c, a, r in ACCEPTED]:
        print("accepted: %s" % name)
        print("    %s" % reason)
    print()
    for name, reason in wire.NORMALIZED:
        print("normalized: %s" % name)
        print("    %s" % reason)
    print()

    if "--show-all" in sys.argv:
        # Every difference, accepted ones included. Worth reading when an
        # allowance is being added or removed, because that is when it matters
        # whether an entry is matching more than it was written for.
        for difference in differences:
            print(str(difference))
        print()

    ok = True
    if failures:
        ok = False
        print("FAIL: the two sides did not run the same cases")
        for line in failures:
            print("    " + line)
        print()
    if unexpected:
        ok = False
        print("FAIL: %d difference(s) nobody signed off on" % len(unexpected))
        for difference in unexpected:
            print(str(difference))
        print()
    if read_mismatches:
        ok = False
        print(
            "FAIL: %d response(s) the two clients read differently"
            % len(read_mismatches)
        )
        for name, mine, yours in read_mismatches:
            print("  " + name)
            print("    mojo.httpx: %s" % mine)
            print("    httpx2:     %s" % yours)
        print()
    if stale:
        ok = False
        print("FAIL: %d accepted difference(s) no longer happen" % len(stale))
        for case, aspect, _reason in stale:
            print("    %s / %s" % (case, aspect))
        print("Delete the entry, and the deviation it documents.")
        print()

    if ok:
        print("parity: ok")
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
