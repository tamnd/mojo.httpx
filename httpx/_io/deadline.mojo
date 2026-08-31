"""Deadlines, the thing every blocking call in this library carries.

httpx's headline promise is that timeouts are real, and the only way to keep
that promise is to make the deadline an argument rather than a policy. A
function that takes a `Deadline` cannot forget to enforce one, and the lint in
tools/lint/run.py fails the build for any I/O function that does not take one.

A deadline is an absolute point on the monotonic clock, not a duration. That
matters once an operation is made of several waits: a connect that resolves,
tries one address, fails, and tries the next has to share one budget across all
of it, and a duration handed to each step would give each step the whole budget.
Absolute also means a wall clock correction cannot lengthen or collapse a
timeout, which is why this reads `perf_counter_ns` rather than the clock in
`_ffi/clock.mojo`.

Each deadline knows what to raise when it passes. The phase is decided where the
deadline is made, which is the only place that knows whether this wait is a
connect, a read, a write or a wait for a free connection, and carrying it means
the raise site does not have to be told again.

An unlimited deadline still produces a bounded wait. `remaining_ms` never
returns a value that means wait forever, because a caller that loops until the
deadline expires stays responsive and a caller that blocks in the kernel with no
timeout cannot be stopped by anything.
"""

from std.time import perf_counter_ns

from httpx._exceptions import ErrorKind, new_error

comptime MAX_SLICE_MS = 50
"""The longest single wait, in milliseconds.

An unlimited deadline waits in slices of this rather than forever, so a caller
comes back around its loop often enough to notice a cancellation and so no call
in the library can park in the kernel with nothing to wake it. Fifty
milliseconds is short enough to feel immediate and long enough that the wakeups
do not show up in a profile.
"""

comptime NANOS_PER_MS = 1_000_000
comptime NANOS_PER_SECOND = 1_000_000_000


def now_ns() -> UInt64:
    """The monotonic clock, in nanoseconds.

    Wrapped rather than called directly so that a test can reason about one
    source of time, and so the choice of clock is written down in one place.
    """
    return UInt64(perf_counter_ns())


struct Deadline(ImplicitlyCopyable, Movable, Writable):
    """A point in time to stop waiting at, and what to raise when it arrives."""

    var at_ns: UInt64
    """Ignored when `limited` is False."""

    var limited: Bool
    """False means no limit, which is a legitimate configuration and not a bug.

    A separate flag rather than a sentinel value of `at_ns`, because every
    sentinel here would either be a time that could genuinely occur or would
    need a comment explaining why it cannot.
    """

    var kind: ErrorKind
    """What `check` raises. One of the four timeout kinds."""

    def __init__(out self, at_ns: UInt64, limited: Bool, kind: ErrorKind):
        self.at_ns = at_ns
        self.limited = limited
        self.kind = kind

    @staticmethod
    def never(kind: ErrorKind = ErrorKind.TIMEOUT) -> Self:
        """No limit. Waits still happen in slices, they just never give up."""
        return Self(UInt64(0), False, kind)

    @staticmethod
    def after(seconds: Float64, kind: ErrorKind = ErrorKind.TIMEOUT) -> Self:
        """A deadline `seconds` from now.

        A negative or zero value produces a deadline that has already passed
        rather than an error, because `timeout=0` is how a caller asks for a non
        blocking attempt and refusing it would mean a second way to say the same
        thing.
        """
        if seconds <= 0.0:
            return Self(now_ns(), True, kind)
        return Self(
            now_ns() + UInt64(seconds * Float64(NANOS_PER_SECOND)), True, kind
        )

    @staticmethod
    def after_ms(ms: Int, kind: ErrorKind = ErrorKind.TIMEOUT) -> Self:
        """A deadline `ms` from now, for callers that already think in
        milliseconds."""
        if ms <= 0:
            return Self(now_ns(), True, kind)
        return Self(now_ns() + UInt64(ms * NANOS_PER_MS), True, kind)

    def with_kind(self, kind: ErrorKind) -> Self:
        """The same instant, reported as a different phase.

        A connect deadline continues through the TLS handshake and through each
        address Happy Eyeballs tries, and each of those wants its own error
        name, so the instant travels and the label changes.
        """
        return Self(self.at_ns, self.limited, kind)

    def earlier_of(self, other: Self) -> Self:
        """Whichever of the two runs out first, keeping that one's kind.

        Used where a per operation timeout sits inside a total budget. The one
        that fires is the one whose name the caller should see.
        """
        if not self.limited:
            return other
        if not other.limited:
            return self
        return self if self.at_ns <= other.at_ns else other

    def expired(self) -> Bool:
        return self.limited and now_ns() >= self.at_ns

    def remaining_ns(self) -> UInt64:
        """Nanoseconds left, or zero once passed.

        Meaningless when unlimited, which is why the only caller is
        `remaining_ms` and it checks first.
        """
        if not self.limited:
            return UInt64(0)
        var at = now_ns()
        return UInt64(0) if at >= self.at_ns else self.at_ns - at

    def remaining_ms(self) -> Int:
        """How long the next single wait may last, in milliseconds.

        Never negative and never larger than `MAX_SLICE_MS`, so the value can go
        straight to `poll` without the caller having to remember that a negative
        timeout there means wait forever.

        Rounds up, so a deadline with half a millisecond left waits one
        millisecond rather than spinning. Sleeping fractionally too long is a
        timeout that fires fractionally late. Not sleeping at all is a busy loop
        that burns a core until the deadline passes.
        """
        if not self.limited:
            return MAX_SLICE_MS
        var left = self.remaining_ns()
        if left == 0:
            return 0
        var ms = Int((left + UInt64(NANOS_PER_MS - 1)) // UInt64(NANOS_PER_MS))
        return ms if ms < MAX_SLICE_MS else MAX_SLICE_MS

    def check(self, what: StringSpan) raises:
        """Raise if the deadline has passed, naming what was being waited for.

        `what` is the operation in the user's terms, like `connect to
        example.com:443`, because a timeout with no subject is the least useful
        error an HTTP client can produce.
        """
        if self.expired():
            raise new_error(self.kind, String("timed out trying to ", what))

    def write_to[W: Writer](self, mut writer: W):
        if not self.limited:
            writer.write("no deadline")
        elif self.expired():
            writer.write("deadline passed")
        else:
            writer.write(
                "deadline in ",
                self.remaining_ns() // UInt64(NANOS_PER_MS),
                "ms",
            )


def connect_deadline(seconds: Optional[Float64]) -> Deadline:
    """The deadline covering DNS, TCP connect and the TLS handshake."""
    return _phase(seconds, ErrorKind.CONNECT_TIMEOUT)


def read_deadline(seconds: Optional[Float64]) -> Deadline:
    """The deadline for one read.

    Per operation rather than per response, matching httpx. A download that
    keeps making progress does not time out however long it takes, and a server
    that stops talking mid body still does.
    """
    return _phase(seconds, ErrorKind.READ_TIMEOUT)


def write_deadline(seconds: Optional[Float64]) -> Deadline:
    """The deadline for one write, on the same per operation basis as reads."""
    return _phase(seconds, ErrorKind.WRITE_TIMEOUT)


def pool_deadline(seconds: Optional[Float64]) -> Deadline:
    """The deadline for waiting on a free connection slot.

    Separate from connect because the wait is on this process rather than on the
    network, and telling the two apart is what says whether to raise the pool
    limits or look at the server.
    """
    return _phase(seconds, ErrorKind.POOL_TIMEOUT)


def _phase(seconds: Optional[Float64], kind: ErrorKind) -> Deadline:
    if not seconds:
        return Deadline.never(kind)
    return Deadline.after(seconds.value(), kind)


struct Deadlines(ImplicitlyCopyable, Movable):
    """The four phase deadlines for one request, started together.

    They are made in one place because they have to start at the same instant.
    Four separate calls spread across the transport would each start their clock
    whenever that part of the code happened to run, so a request that spent a
    second in the pool would silently get a second longer to connect.

    Layered here rather than with the rest of the configuration because the pool
    and the transport need it and neither can see the configuration layer.
    """

    var connect: Deadline
    var read: Deadline
    var write: Deadline
    var pool: Deadline

    def __init__(
        out self,
        connect_at: Deadline,
        read_at: Deadline,
        write_at: Deadline,
        pool_at: Deadline,
    ):
        self.connect = connect_at
        self.read = read_at
        self.write = write_at
        self.pool = pool_at

    @staticmethod
    def never() -> Self:
        """No limits at all, which is only ever right in a test."""
        return Self(
            Deadline.never(ErrorKind.CONNECT_TIMEOUT),
            Deadline.never(ErrorKind.READ_TIMEOUT),
            Deadline.never(ErrorKind.WRITE_TIMEOUT),
            Deadline.never(ErrorKind.POOL_TIMEOUT),
        )

    @staticmethod
    def after(
        connect_seconds: Optional[Float64],
        read_seconds: Optional[Float64],
        write_seconds: Optional[Float64],
        pool_seconds: Optional[Float64],
    ) -> Self:
        """Start all four now, from a timeout given in seconds per phase."""
        return Self(
            connect_deadline(connect_seconds),
            read_deadline(read_seconds),
            write_deadline(write_seconds),
            pool_deadline(pool_seconds),
        )

    @staticmethod
    def uniform(seconds: Optional[Float64]) -> Self:
        """The same budget for every phase, which is what one number means."""
        return Self.after(seconds, seconds, seconds, seconds)
