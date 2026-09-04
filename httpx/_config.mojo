"""What a caller configures, in the terms a caller thinks in.

Everything below this file works in deadlines, which are absolute instants on
the monotonic clock. That is the right shape for enforcement and the wrong
shape for configuration: nobody wants to say "stop reading at 14:32:07.331", so
this is where a duration in seconds turns into the four deadlines a request
carries.

The conversion happens once per request, on purpose. Four deadlines made at
four different moments would each start their clock when that part of the code
happened to run, so a request that spent a second waiting for a free connection
would silently get a second longer to connect.
"""

from httpx._exceptions import ErrorKind, new_error
from httpx._io.deadline import Deadlines

comptime DEFAULT_TIMEOUT_SECONDS = 5.0
"""The default for every phase, matching httpx.

Short enough that a wedged server does not hang a program that forgot to think
about timeouts, and long enough that an ordinary request over a slow link is
not cut off. It applies to each phase separately rather than to the request as
a whole, so a large download does not run out of time for being large.
"""


struct Timeout(ImplicitlyCopyable, Movable, Writable):
    """The four phase timeouts, in seconds, with `None` meaning no limit.

    Four rather than one because the four fail for different reasons and want
    different answers. A connect that times out means the host is unreachable
    and there is nothing to retry against; a read that times out means the
    server took the request and went quiet; a pool timeout means the wait was
    on this program rather than on the network. One number cannot say which.

    ```mojo
    from httpx import Client, Timeout


    def main() raises:
        with Client(timeout=Timeout.uniform(10.0)) as quick:
            print(quick.get("https://example.com/").status_code)

        var patient = Timeout(
            connect_seconds=5.0,
            read_seconds=60.0,
            write_seconds=5.0,
            pool_seconds=5.0,
        )
        with Client(timeout=patient) as slow:
            print(slow.get("https://example.com/big").status_code)
    ```
    """

    var connect: Optional[Float64]
    var read: Optional[Float64]
    var write: Optional[Float64]
    var pool: Optional[Float64]

    def __init__(out self) raises:
        """The default, which is `DEFAULT_TIMEOUT_SECONDS` for every phase."""
        self = Self.uniform(Optional[Float64](Float64(DEFAULT_TIMEOUT_SECONDS)))

    def __init__(
        out self,
        connect_seconds: Optional[Float64],
        read_seconds: Optional[Float64],
        write_seconds: Optional[Float64],
        pool_seconds: Optional[Float64],
    ) raises:
        # Named for the unit rather than for the field, because `read` is a
        # reserved argument convention in Mojo and cannot be an argument name.
        # The same spelling as `Deadlines.after`, which this feeds.
        _check("connect", connect_seconds)
        _check("read", read_seconds)
        _check("write", write_seconds)
        _check("pool", pool_seconds)
        self.connect = connect_seconds
        self.read = read_seconds
        self.write = write_seconds
        self.pool = pool_seconds

    @staticmethod
    def uniform(seconds: Optional[Float64]) raises -> Self:
        """One number for every phase, which is what most callers mean."""
        return Self(seconds, seconds, seconds, seconds)

    @staticmethod
    def disabled() raises -> Self:
        """No limits anywhere.

        A real setting for a program that does its own supervision, and a trap
        for everyone else: a request with no timeout can wait for as long as
        the operating system is willing to hold the socket open.

        Marked raising because it goes through the checked constructor, not
        because there is anything here that can fail. Four absent values are
        exactly what the check lets through.
        """
        return Self(None, None, None, None)

    def deadlines(self) -> Deadlines:
        """Start all four clocks, now.

        Called once per request, by the client, just before the request goes to
        a transport.
        """
        return Deadlines.after(self.connect, self.read, self.write, self.pool)

    def write_to[W: Writer](self, mut writer: W):
        writer.write("Timeout(connect=")
        _write_optional(writer, self.connect)
        writer.write(", read=")
        _write_optional(writer, self.read)
        writer.write(", write=")
        _write_optional(writer, self.write)
        writer.write(", pool=")
        _write_optional(writer, self.pool)
        writer.write(")")


def _check(phase: StringSpan, seconds: Optional[Float64]) raises:
    """Reject a negative timeout.

    Zero is allowed, because it is how a caller asks for a non blocking
    attempt. Negative is not, because there is no reading of it that differs
    from zero and accepting it would hide a sign error in the caller's
    arithmetic.
    """
    if seconds and seconds.value() < 0.0:
        raise new_error(
            ErrorKind.INVALID_ARGUMENT,
            String(
                "the ",
                phase,
                " timeout cannot be negative, got ",
                seconds.value(),
            ),
        )


def _write_optional[W: Writer](mut writer: W, value: Optional[Float64]):
    if value:
        writer.write(value.value())
    else:
        writer.write("None")
