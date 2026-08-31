"""The test entry point.

Mojo 1.0 has no `mojo test` subcommand, only the assertions in `std.testing`,
so the project owns its runner. This file is the seed of it. For now it calls
each test function directly; M0 replaces the hand written list with discovery,
and when Mojo ships a native runner this file goes away and the test functions
stay exactly as they are.
"""

from tests.unit.test_version import test_version_is_set


def main() raises:
    var failed = 0

    failed += _run["test_version_is_set"](test_version_is_set)

    if failed != 0:
        print("FAILED:", failed, "test(s)")
        raise Error("test run failed")
    print("ok")


def _run[name: StaticString](t: def() raises thin) -> Int:
    try:
        t()
        print("PASS", name)
        return 0
    except e:
        print("FAIL", name, "-", String(e))
        return 1
