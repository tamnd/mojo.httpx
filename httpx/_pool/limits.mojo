"""How many connections the pool may hold, and for how long.

Three numbers, all of them about resources rather than about correctness. A pool
with no limits works fine until the day a service it talks to gets slow, at
which point the client opens a connection per outstanding request and takes down
the thing it was talking to along with itself. The defaults match httpx, because
they are well worn and because a user moving between the two libraries should
not have to relearn them.

Defined here rather than with the rest of the configuration so that the pool can
see them. Configuration sits above the pool and re-exports this type.
"""

from httpx._exceptions import ErrorKind, new_error

comptime DEFAULT_MAX_CONNECTIONS = 100
"""Total connections across every origin.

High enough that no ordinary program notices it and low enough that a program
which has started leaking connections hits it rather than the file descriptor
limit, where the failure is much harder to read.
"""

comptime DEFAULT_MAX_KEEPALIVE_CONNECTIONS = 20
"""Idle connections kept for reuse.

Separate from the total because an idle connection costs the server as much as a
busy one. Keeping a hundred of them open against a server that allows a hundred
in total would mean one client holding the whole thing while doing nothing.
"""

comptime DEFAULT_KEEPALIVE_EXPIRY_SECONDS = 5.0
"""How long an idle connection may be reused for.

Servers close idle connections on their own schedule and rarely say what it is.
Five seconds is short enough to lose the race with almost every server timeout
and long enough to cover the burst of requests that reuse is actually for.
"""


struct Limits(ImplicitlyCopyable, Movable, Writable):
    """The pool's resource bounds.

    Each limit is optional, and `None` means no bound rather than zero. That
    distinction matters: a `max_connections` of zero is a pool that can never
    connect, which is a mistake somebody would rather find at construction than
    at the first request, so it is rejected here.
    """

    var max_connections: Optional[Int]
    var max_keepalive_connections: Optional[Int]
    var keepalive_expiry: Optional[Float64]
    """Seconds. `None` keeps idle connections until the server closes them."""

    def __init__(
        out self,
        max_connections: Optional[Int] = DEFAULT_MAX_CONNECTIONS,
        max_keepalive_connections: Optional[
            Int
        ] = DEFAULT_MAX_KEEPALIVE_CONNECTIONS,
        keepalive_expiry: Optional[Float64] = DEFAULT_KEEPALIVE_EXPIRY_SECONDS,
    ) raises:
        if max_connections and max_connections.value() < 1:
            raise new_error(
                ErrorKind.INVALID_ARGUMENT,
                "max_connections has to be at least one, or None for no limit",
            )
        if max_keepalive_connections and max_keepalive_connections.value() < 0:
            raise new_error(
                ErrorKind.INVALID_ARGUMENT,
                "max_keepalive_connections cannot be negative",
            )
        if keepalive_expiry and keepalive_expiry.value() < 0.0:
            raise new_error(
                ErrorKind.INVALID_ARGUMENT,
                "keepalive_expiry cannot be negative",
            )
        self.max_connections = max_connections
        self.max_keepalive_connections = max_keepalive_connections
        self.keepalive_expiry = keepalive_expiry

    @staticmethod
    def unlimited() raises -> Self:
        """No bounds at all, which is a benchmark setting and not a default."""
        return Self(None, None, None)

    def keepalive_allowance(self) -> Int:
        """How many idle connections may be retained, with `None` as unbounded.

        Bounded by the total as well, because a keepalive allowance larger than
        the pool is a configuration that says two different things and the
        smaller one is the one that can actually be honoured.
        """
        var allowed = -1
        if self.max_keepalive_connections:
            allowed = self.max_keepalive_connections.value()
        if self.max_connections:
            var total = self.max_connections.value()
            if allowed < 0 or allowed > total:
                allowed = total
        return allowed

    def write_to[W: Writer](self, mut writer: W):
        writer.write("Limits(max_connections=")
        _write_optional_int(writer, self.max_connections)
        writer.write(", max_keepalive_connections=")
        _write_optional_int(writer, self.max_keepalive_connections)
        writer.write(", keepalive_expiry=")
        if self.keepalive_expiry:
            writer.write(self.keepalive_expiry.value())
        else:
            writer.write("None")
        writer.write(")")


def _write_optional_int[W: Writer](mut writer: W, value: Optional[Int]):
    if value:
        writer.write(value.value())
    else:
        writer.write("None")
