"""The benchmark driver: run every case, compare it to the baseline, gate on it.

`pixi run bench`. The cases themselves are Mojo and live in
`tools/bench/main.mojo`; this is the part that builds them, gives them a server
to talk to, and decides whether the numbers that came back are acceptable.

A regression of more than five percent on any number fails the run. That is the
gate M9 asks for, and it is only meaningful against a number measured on the
same machine, so the baseline is per machine and a machine with no entry is
reported rather than failed. `--update` writes an entry for this machine.

Every case runs in its own process, and each of those runs the case a few times
and reports its best. Two layers of repetition for two different reasons: the
inner one is about the case warming up, the outer one is about the process
warming up, and neither would catch the other.

The one thing measured here rather than in Mojo is cold start, because it is the
cost of a process rather than the cost of a call. It is the wall clock of a
process that makes one request, minus the wall clock of the same binary asked to
do nothing, so what is left is the client starting up rather than the language
runtime starting up.

Benchmarks are not part of `pixi run check` and are not in CI. A hosted runner
shares a machine with whoever else is on it, and a five percent gate on a shared
machine is a coin toss. They run on the fleet, where server3 has the bench role.
See docs/testing.md and docs/benchmarks.md.
"""

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import time
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "tools" / "bench" / "main.mojo"
BINARY = ROOT / "build" / "bench"
BASELINE = ROOT / "tools" / "bench" / "baseline.json"
SERVER = ROOT / "tests" / "server" / "server.py"

# Which way is better, by unit. A benchmark suite that got this backwards would
# pass every regression and fail every improvement, and it would look right, so
# the table is here in one place rather than spelled per case.
HIGHER_IS_BETTER = {"req/s", "MiB/s", "stream/s"}
LOWER_IS_BETTER = {"ns", "us", "ms", "s"}

# Every case, in the order they run. `server` says whether the case needs the
# test server, which only matters in that a case that does not need one is
# still worth running when the server failed to start.
CASES = [
    ("h1-keepalive", True),
    ("h1-concurrent-100", True),
    ("upload-10mb", True),
    ("download-10mb", True),
    ("h2-streams-1000", False),
    ("parse-headers", False),
    ("parse-hpack", False),
    ("parse-url", False),
]

# The ones the driver times from outside rather than reading numbers from.
# `nothing` is the subtrahend for both of the other two.
COLD_CASES = ["cold-start", "cold-start-tls", "nothing"]


def find_mojo():
    mojo = os.environ.get("MOJO") or shutil.which("mojo")
    if mojo:
        return mojo
    launcher = Path.home() / ".pixi" / "bin" / "mojo"
    if launcher.exists():
        return str(launcher)
    print("mojo not found. Run this through pixi.", file=sys.stderr)
    raise SystemExit(2)


def build():
    mojo = find_mojo()
    BINARY.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        [mojo, "build", "-I", str(ROOT), "-o", str(BINARY), str(SOURCE)],
        cwd=ROOT,
    )
    if result.returncode != 0:
        print("the benchmarks did not build", file=sys.stderr)
        raise SystemExit(2)


def mojo_version():
    try:
        out = subprocess.run(
            [find_mojo(), "--version"], capture_output=True, text=True
        )
        return out.stdout.strip().splitlines()[0]
    except (OSError, IndexError):
        return "unknown"


class Server:
    """The test server, for as long as the benchmarks are running.

    Started here rather than from Mojo so that no benchmark process has a Python
    interpreter inside it. The port comes from the server's first line of
    output, which it writes once it is listening, so there is no sleeping and no
    agreed port number.
    """

    def __init__(self, tls=False):
        # `localhost` for the https one, because that is the name on the test
        # certificate and a certificate checked against a name nobody put on it
        # is the check not happening.
        host = "localhost" if tls else "127.0.0.1"
        argv = [sys.executable, str(SERVER), "--host", host, "--port", "0"]
        if tls:
            argv.append("--tls")
        self.proc = subprocess.Popen(
            argv,
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        line = self.proc.stdout.readline().strip()
        if not line.startswith("PORT "):
            self.stop()
            raise SystemExit("the test server did not start: %r" % line)
        scheme = "https" if tls else "http"
        self.url = "%s://%s:%s" % (scheme, host, line.split()[1])

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def run_case(name, url, reps):
    """One case in one process. Returns its lines and how long it took."""
    argv = [str(BINARY), "--case", name, "--reps", str(reps)]
    if url:
        argv += ["--url", url]
    started = time.perf_counter()
    result = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True)
    spent = time.perf_counter() - started
    if result.returncode != 0:
        print(result.stdout, file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        raise SystemExit("the %s case did not finish" % name)
    return result.stdout.splitlines(), spent


def parse_results(lines):
    """The `RESULT case metric unit value` lines, as a dict."""
    out = {}
    for line in lines:
        parts = line.split()
        if len(parts) != 5 or parts[0] != "RESULT":
            continue
        key = "%s.%s" % (parts[1], parts[2])
        out[key] = (parts[3], float(parts[4]))
    return out


def better(unit, left, right):
    """Whichever of two readings is the better one for this unit."""
    if unit not in HIGHER_IS_BETTER and unit not in LOWER_IS_BETTER:
        raise SystemExit(
            "%s is not a unit this knows which way round to read. Add it to "
            "one of the two tables at the top of tools/bench/run.py." % unit
        )
    if unit in HIGHER_IS_BETTER:
        return max(left, right)
    return min(left, right)


def check_cases_match():
    """The Mojo side and the table above, kept from drifting apart.

    Cheap, and it catches the failure mode that would otherwise be silent: a
    case added to the benchmarks and never run because nothing here names it.
    """
    listed, _ = run_case_list()
    known = set(name for name, _ in CASES) | set(COLD_CASES)
    if listed != known:
        missing = sorted(listed - known)
        extra = sorted(known - listed)
        raise SystemExit(
            "tools/bench/run.py and tools/bench/main.mojo disagree about the "
            "cases. Only in main.mojo: %s. Only in run.py: %s"
            % (missing or "none", extra or "none")
        )


def run_case_list():
    result = subprocess.run(
        [str(BINARY), "--list"], cwd=ROOT, capture_output=True, text=True
    )
    if result.returncode != 0:
        raise SystemExit("the benchmarks could not list their cases")
    return set(result.stdout.split()), result.stdout


def measure(url, tls_url, reps, rounds, wanted):
    """Every case that was asked for, as a dict of key to (unit, value)."""
    measured = {}
    for name, needs_server in CASES:
        if wanted and wanted not in name:
            continue
        print("  %-20s" % name, end="", flush=True)
        for _ in range(rounds):
            lines, _ = run_case(name, url if needs_server else None, reps)
            for key, (unit, value) in parse_results(lines).items():
                if key in measured:
                    before = measured[key][1]
                    measured[key] = (unit, better(unit, before, value))
                else:
                    measured[key] = (unit, better(unit, value, value))
            print(".", end="", flush=True)
        print()

    for name, where in (("cold-start", url), ("cold-start-tls", tls_url)):
        if wanted and wanted not in name:
            continue
        print("  %-20s" % name, end="", flush=True)
        measured[name + ".wall_ms"] = ("ms", cold_start(name, where, rounds))
        print()
    return measured


def cold_start(name, url, rounds):
    """A process that makes one request, less a process that makes none.

    Both are the same binary, so everything they share cancels: the dynamic
    loader, the runtime coming up, and the exit. What is left is the client
    being built, the connect and one exchange, plus for the https one the trust
    store being read, OpenSSL being opened and a handshake.

    The smallest reading of each is what is subtracted. Anything slower than the
    smallest is the machine being busy, and subtracting one busy reading from
    another gives a number that is mostly noise.
    """
    empty = []
    full = []
    for _ in range(max(rounds, 3)):
        _, spent = run_case("nothing", None, 1)
        empty.append(spent)
        print(".", end="", flush=True)
        _, spent = run_case(name, url, 1)
        full.append(spent)
        print(".", end="", flush=True)
    return max((min(full) - min(empty)) * 1000.0, 0.0)


def machine_name():
    """Which baseline entry this run belongs to.

    The hostname, because the fleet's machines are named and a number measured
    on one of them means nothing on another. `HTTPX_BENCH_MACHINE` overrides it,
    which is what a laptop wants: hostnames there are personal and a baseline is
    committed to a public repository.
    """
    named = os.environ.get("HTTPX_BENCH_MACHINE")
    if named:
        return named
    return platform.node().split(".")[0]


def load_baseline():
    if not BASELINE.exists():
        return {}
    return json.loads(BASELINE.read_text())


def entry_for(measured):
    return {
        "recorded": date.today().isoformat(),
        "platform": "%s-%s" % (platform.system(), platform.machine()),
        "mojo": mojo_version(),
        "metrics": {
            key: {"unit": unit, "value": round(value, 4)}
            for key, (unit, value) in sorted(measured.items())
        },
    }


def compare(measured, baseline, tolerance):
    """Print the table and say how many numbers regressed.

    The change column is signed so that positive is better whichever way the
    unit runs, because a table where minus means faster in one row and slower in
    the next is one people misread.
    """
    print()
    print(
        "%-32s %-8s %14s %14s %9s  %s"
        % ("metric", "unit", "measured", "baseline", "change", "")
    )
    regressed = []
    for key in sorted(measured):
        unit, value = measured[key]
        known = baseline.get("metrics", {}).get(key)
        if known is None:
            print(
                "%-32s %-8s %14.2f %14s %9s  %s"
                % (key, unit, value, "none", "", "new")
            )
            continue
        base = known["value"]
        if known["unit"] != unit:
            raise SystemExit(
                "%s is measured in %s now and %s in the baseline"
                % (key, unit, known["unit"])
            )
        if base <= 0:
            change = 0.0
        elif unit in HIGHER_IS_BETTER:
            change = (value / base - 1.0) * 100.0
        else:
            change = (base / value - 1.0) * 100.0
        verdict = "ok"
        if change < -tolerance:
            verdict = "REGRESSED"
            regressed.append(key)
        print(
            "%-32s %-8s %14.2f %14.2f %8.1f%%  %s"
            % (key, unit, value, base, change, verdict)
        )
    return regressed


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--case", default="", help="only cases matching this")
    ap.add_argument(
        "--reps", type=int, default=3, help="runs of a case inside one process"
    )
    ap.add_argument(
        "--rounds", type=int, default=3, help="processes per case"
    )
    ap.add_argument(
        "--tolerance",
        type=float,
        default=5.0,
        help="percent a number may fall by before the run fails",
    )
    ap.add_argument(
        "--update",
        action="store_true",
        help="write what was measured into the baseline for this machine",
    )
    ap.add_argument(
        "--json",
        action="store_true",
        help="print this machine's entry, for copying a fleet result back",
    )
    ap.add_argument(
        "--no-build", action="store_true", help="use build/bench as it is"
    )
    args = ap.parse_args()

    if not args.no_build:
        build()
    elif not BINARY.exists():
        raise SystemExit("build/bench is not there and --no-build was given")
    check_cases_match()

    who = machine_name()
    print("machine %s, %s" % (who, mojo_version()))

    plain = Server()
    secure = Server(tls=True)
    try:
        measured = measure(
            plain.url, secure.url, args.reps, args.rounds, args.case
        )
    finally:
        plain.stop()
        secure.stop()

    everything = load_baseline()
    regressed = compare(measured, everything.get(who, {}), args.tolerance)

    entry = entry_for(measured)
    if args.json:
        print()
        print(json.dumps({who: entry}, indent=2, sort_keys=True))

    if args.update:
        everything[who] = entry
        written = json.dumps(everything, indent=2, sort_keys=True)
        BASELINE.write_text(written + "\n")
        print()
        print("wrote the baseline for %s" % who)
        return 0

    print()
    if who not in everything:
        print(
            "no baseline for %s, so nothing was gated. Record one with"
            " --update once the machine is quiet." % who
        )
        return 0
    if regressed:
        print(
            "%d number(s) fell by more than %g percent: %s"
            % (len(regressed), args.tolerance, ", ".join(regressed))
        )
        return 1
    print("every number is within %g percent of the baseline" % args.tolerance)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
