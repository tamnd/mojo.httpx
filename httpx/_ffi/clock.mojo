"""The wall clock.

`std.time` gives a monotonic counter, which is the right thing for measuring how
long something took and the wrong thing for deciding whether a cookie has
expired. Expiry is stated in Unix seconds by a server on the other side of the
world, so comparing it needs the same scale, and that only comes from the system
clock.

This sits in the FFI layer rather than beside the cookie code because it is a
syscall, and the layering lint keeps syscalls here. Everything above takes the
current time as an argument instead of reading it, which is also what makes an
expiry test possible to write: a test that has to wait a second to see a cookie
expire is a test nobody runs.
"""

from std.ffi import c_long, external_call


def unix_now() -> Int:
    """Seconds since the Unix epoch, from the system clock.

    Not monotonic. The clock can step backwards when it is corrected, so this is
    only ever compared against other wall clock times, never subtracted from
    itself to measure an interval.
    """
    # `time` takes an optional out parameter and returns the same value. Mojo's
    # `Pointer` is non-nullable, so rather than manufacture a null there is a
    # real slot to point at and the return value is what gets read.
    var slot = c_long(0)
    return Int(external_call["time", c_long](Pointer(to=slot)))
