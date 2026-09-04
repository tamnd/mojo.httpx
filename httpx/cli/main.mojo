"""The `httpx` program.

Nothing but the two things a `main` is for: taking the arguments off the
process and putting the exit code back on it. Everything that could be tested
is in `run`, which takes a list and returns an integer, so the test suite never
has to start a process.

    pixi run mojo build -I . -o httpx httpx/cli/main.mojo
"""

from std.sys import argv, exit

from httpx.cli.run import run


def main():
    """Drop the program name, run the rest, exit with what it says."""
    var raw = argv()
    var rest = List[String]()
    for i in range(1, len(raw)):
        rest.append(String(raw[i]))
    exit(run(rest))
