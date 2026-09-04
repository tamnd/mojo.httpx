"""The download progress bar.

It goes on stderr and only when stderr is a terminal. Both halves of that are
load bearing. On stdout it would end up inside the file when somebody wrote
`httpx URL --download - > file`, and down a pipe it would be a stream of
carriage returns in the middle of somebody's log.

The width is fixed rather than read from the terminal. Asking would mean an
ioctl for the window size, and a bar that is thirty cells wide in an eighty
column window is fine, while a client that carries a terminal size query in
order to draw one is not.

Redraws are throttled, so a fast download does not spend its time writing
escape sequences. That also makes the output of a download that finishes
instantly deterministic, which is what the golden tests compare.
"""

from httpx._io.deadline import now_ns
from httpx._io.stdio import STDERR, is_terminal, write_text

comptime WIDTH = 30
"""Cells in the bar itself, not counting the label or the numbers."""

comptime REDRAW_NS = UInt64(100_000_000)
"""A tenth of a second between redraws. Fast enough to look continuous and slow
enough that the drawing is never the reason a download is slow."""

comptime _KIB = 1024
comptime _MIB = 1024 * 1024


def human_size(n: Int) -> String:
    """A byte count as somebody would say it out loud.

    One decimal place above a kilobyte, none below, because `1.0 B` reads like
    a bug and `1048576 B` is not a number anybody parses at a glance.
    """
    if n < _KIB:
        return String(n, " B")
    if n < _MIB:
        return String(_tenths(n, _KIB), " KiB")
    return String(_tenths(n, _MIB), " MiB")


def _tenths(n: Int, unit: Int) -> String:
    """`n / unit` to one decimal place, without floating point.

    Integer arithmetic because this is the only division in the program and
    doing it in `Float64` would mean thinking about how it rounds and prints on
    three platforms in order to draw a progress bar.
    """
    var scaled = (n * 10 + unit // 2) // unit
    return String(scaled // 10, ".", scaled % 10)


struct Progress(Movable):
    """How much of a download has arrived, drawn on stderr.

    Holds the decision about whether to draw at all, so that a caller that has
    no bar to draw and a caller that has one look the same at the call site.
    """

    var _on: Bool
    var _label: String
    var _total: Int
    var _done: Int
    var _last_ns: UInt64

    def __init__(out self, label: String, total: Int):
        """`total` is the expected size, or a negative number when the server
        did not say. Without it there is a count and no bar, because a bar with
        no end is a lie about how far along this is."""
        self._on = is_terminal(STDERR)
        self._label = label.copy()
        self._total = total
        self._done = 0
        self._last_ns = 0

    def start(mut self):
        """Draw the empty bar, so that a download which stalls at the first byte
        still shows that it started."""
        if not self._on:
            return
        self._last_ns = now_ns()
        self._draw()

    def advance(mut self, n: Int):
        if not self._on:
            return
        self._done += n
        var at = now_ns()
        if at - self._last_ns < REDRAW_NS:
            return
        self._last_ns = at
        self._draw()

    def finish(mut self):
        """Draw the finished state and end the line.

        The last draw is unconditional, because the throttle will usually have
        skipped the one that would have shown the download complete, and a bar
        left at ninety four percent on a download that worked is worse than no
        bar at all.
        """
        if not self._on:
            return
        self._draw()
        try:
            _ = write_text(STDERR, "\n")
        except:
            pass

    def _draw(self):
        """One line, rewritten in place.

        A carriage return and no newline, so the next draw lands on top of this
        one. A failure to write is dropped: a program that cannot draw a
        progress bar has no business reporting that as the thing that went
        wrong when the download itself is going fine.
        """
        var line = String("\r", self._label, "  ", human_size(self._done))
        if self._total >= 0:
            var filled = WIDTH
            var percent = 100
            if self._total > 0:
                filled = self._done * WIDTH // self._total
                percent = self._done * 100 // self._total
            if filled > WIDTH:
                filled = WIDTH
            if percent > 100:
                percent = 100
            line += String(" / ", human_size(self._total), "  [")
            for _ in range(filled):
                line += "#"
            for _ in range(WIDTH - filled):
                line += "-"
            line += String("] ", percent, "%")
        # Trailing spaces, because a line that gets shorter would otherwise
        # leave the tail of the longer one it was drawn over still on screen.
        line += "   "
        try:
            _ = write_text(STDERR, line)
        except:
            pass
