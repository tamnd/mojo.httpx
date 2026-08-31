"""Compiler behaviour this library had to be designed around.

Not tests of anything in `httpx/`. Each one pins something Mojo 1.0 does that
shaped a design decision, so that if a later compiler changes its mind we find
out from a failing test rather than from a bug report years later.

Every test here has a comment saying what it forced and where.
"""

from std.testing import assert_equal, assert_true


struct CountingSource(Copyable, Movable, Sized):
    """Counts to five and fails on the third step."""

    var at: Int

    def __init__(out self):
        self.at = 0

    def __iter__(self) -> Self:
        return self.copy()

    def __has_next__(self) -> Bool:
        return self.at < 5

    def __len__(self) -> Int:
        return 5 - self.at

    def __next__(mut self) raises -> Int:
        if self.at == 2:
            raise Error("the connection died")
        self.at += 1
        return self.at - 1


def test_a_for_loop_swallows_an_error_raised_out_of_next() raises:
    # This is why the iterators in httpx/_models/iterators.mojo are `has_next`
    # and `next` rather than the real iterator protocol. A `for` loop over a
    # source whose `__next__` raises stops as if the source had run out, and the
    # error never reaches the caller. For a response body that means a read that
    # failed halfway through looks exactly like a body that ended, which is the
    # one failure an HTTP client must never have.
    #
    # This test function raises, so an error escaping the loop would fail it.
    # Nothing escapes. Two of the five values arrive and the loop just ends.
    var seen = List[Int]()
    for value in CountingSource():
        seen.append(value)
    assert_equal(len(seen), 2)
    assert_equal(seen[0], 0)
    assert_equal(seen[1], 1)


def test_calling_next_directly_does_raise() raises:
    # The other half of the finding, and the reason the workaround works: there
    # is nothing wrong with the raise itself. It is the `for` loop that drops it.
    # Called as an ordinary method the error comes out where it should.
    var source = CountingSource()
    assert_equal(source.__next__(), 0)
    assert_equal(source.__next__(), 1)

    var raised = False
    try:
        _ = source.__next__()
    except e:
        raised = True
        assert_equal(String(e), "the connection died")
    assert_true(raised)
