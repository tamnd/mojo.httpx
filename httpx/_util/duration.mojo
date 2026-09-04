"""How long something took.

```mojo
var r = httpx.get("https://example.com/")
print(r.elapsed().milliseconds())
```

A count of nanoseconds with accessors that convert, rather than a bare integer,
because a bare integer is the kind of thing that gets compared against a number
in milliseconds two files away and nobody notices until the timeout is a
thousand times wrong.

httpx2 gives back a `datetime.timedelta` here, which Python already had. Mojo
has no equivalent in the standard library, so this is it. It is deliberately
small: measuring an interval is the only thing it is for, and calendar
arithmetic is a different problem with different edge cases.
"""


comptime _NANOS_PER_MICRO = 1_000
comptime _NANOS_PER_MILLI = 1_000_000
comptime _NANOS_PER_SECOND = 1_000_000_000


struct Duration(Comparable, ImplicitlyCopyable, Movable, Writable):
    """An elapsed time, held as nanoseconds.

    ```mojo
    from httpx import Client


    def main() raises:
        with Client() as client:
            var r = client.get("https://example.com/")
            print(r.elapsed().milliseconds(), r.elapsed().seconds())
    ```
    """

    var nanoseconds: UInt64

    def __init__(out self, nanoseconds: UInt64 = 0):
        self.nanoseconds = nanoseconds

    @staticmethod
    def between(start_ns: UInt64, end_ns: UInt64) -> Self:
        """The gap between two readings of the monotonic clock.

        Clamped at zero rather than wrapping. The clock these come from does not
        run backwards, so this should never fire, but the two values are
        unsigned and a subtraction that went the wrong way would produce roughly
        five hundred years instead of a negative number. A zero is a wrong
        answer somebody can spot.
        """
        if end_ns <= start_ns:
            return Self(0)
        return Self(end_ns - start_ns)

    def seconds(self) -> Float64:
        return Float64(self.nanoseconds) / Float64(_NANOS_PER_SECOND)

    def milliseconds(self) -> Float64:
        return Float64(self.nanoseconds) / Float64(_NANOS_PER_MILLI)

    def microseconds(self) -> Float64:
        return Float64(self.nanoseconds) / Float64(_NANOS_PER_MICRO)

    def __eq__(self, other: Self) -> Bool:
        return self.nanoseconds == other.nanoseconds

    def __ne__(self, other: Self) -> Bool:
        return self.nanoseconds != other.nanoseconds

    def __lt__(self, other: Self) -> Bool:
        return self.nanoseconds < other.nanoseconds

    def __le__(self, other: Self) -> Bool:
        return self.nanoseconds <= other.nanoseconds

    def __gt__(self, other: Self) -> Bool:
        return self.nanoseconds > other.nanoseconds

    def __ge__(self, other: Self) -> Bool:
        return self.nanoseconds >= other.nanoseconds

    def write_to[W: Writer](self, mut writer: W):
        """Seconds to six places, which is what a `timedelta` resolves to.

        Built from integer arithmetic rather than by formatting a float, so the
        digits are the ones actually held and not whatever rounding a float
        formatter would have picked.
        """
        var whole = self.nanoseconds // _NANOS_PER_SECOND
        var micros = (self.nanoseconds % _NANOS_PER_SECOND) // _NANOS_PER_MICRO
        writer.write(whole, ".")
        var scale = UInt64(100_000)
        while scale > 0:
            writer.write(micros // scale % 10)
            scale //= 10
        writer.write("s")
