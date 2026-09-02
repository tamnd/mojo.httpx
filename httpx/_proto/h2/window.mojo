"""Flow control windows.

RFC 9113 section 5.2. Every connection and every stream has two windows, one in
each direction, and they are not symmetrical in anything but arithmetic. The
send window is a permission the peer granted us and the only thing to do with it
is respect it. The receive window is a promise we made, and the interesting
decisions are all on that side: how much to promise, and when to promise more.

The two are separate types here rather than one type used twice. They share a
counter and nothing else. A send window that runs out means waiting; a receive
window that runs out means the peer broke its word, which is an error. Writing
them as one type would mean a single `consume` that has to be told which of
those two things it is doing every time it is called.

Flow control is only ever applied to `DATA` frames, per section 5.2.1, and to
their padding as well as their contents. That is deliberate in the RFC and it
matters: padding is chosen by the sender, so a receiver that did not count it
would be letting the sender decide how much of the window its own padding cost.

There is no timeout in this file. A send window that never opens is a stall, and
a stall is exactly what a deadline is for, but the waiting happens in the
connection where the deadline already lives.
"""

from httpx._exceptions import ErrorKind, new_error
from httpx._proto.h2.frames import DEFAULT_WINDOW_SIZE, MAX_WINDOW

comptime MIN_WINDOW = -0x80000000
"""How negative a send window may legally get.

A window goes negative when the peer lowers `SETTINGS_INITIAL_WINDOW_SIZE` after
having already granted more than the new value. RFC 9113 section 6.9.2 says that
is not an error and the sender simply owes the difference before it may send
again, so the type has to be able to hold it.
"""


def _remote(message: String) -> Error:
    return new_error(ErrorKind.REMOTE_PROTOCOL_ERROR, message)


def _local(message: String) -> Error:
    return new_error(ErrorKind.LOCAL_PROTOCOL_ERROR, message)


struct SendWindow(ImplicitlyCopyable, Movable):
    """How much the peer has said we may send. Read, never assumed."""

    var available: Int
    """May be negative, and that is not a failure. See `MIN_WINDOW`."""

    def __init__(out self, initial: Int = DEFAULT_WINDOW_SIZE):
        self.available = initial

    def allows(self, wanted: Int) -> Int:
        """How much of `wanted` may go out now, which is often none.

        Returning a number rather than a yes or a no is what lets a large body
        move through a small window: the caller sends what fits, waits for a
        window update, and asks again.
        """
        if self.available <= 0:
            return 0
        return min(wanted, self.available)

    def consume(mut self, amount: Int) raises:
        """Record `amount` octets sent, padding included.

        Sending more than the window allows is our own mistake and not the
        peer's, hence the local error. By the time this could raise the octets
        would already be on the wire, so it is a guard on a caller that ignored
        `allows` rather than something to recover from.
        """
        if amount > self.available:
            raise _local(
                String(
                    "tried to send ",
                    amount,
                    " bytes into a flow control window of ",
                    self.available,
                )
            )
        self.available -= amount

    def increase(mut self, amount: Int) raises:
        """Take a `WINDOW_UPDATE`.

        `FLOW_CONTROL_ERROR`. RFC 9113 section 6.9.1 puts the ceiling at
        2^31 - 1 and says going over it is an error rather than a saturation,
        which is the right way round: a peer that granted more than a window can
        hold is a peer whose accounting has diverged from ours, and every byte
        after that is sent against a number only one of us believes.
        """
        if self.available + amount > MAX_WINDOW:
            raise _remote(
                String(
                    "the server opened the window to ",
                    self.available + amount,
                    ", over the ",
                    MAX_WINDOW,
                    " a window can hold",
                )
            )
        self.available += amount

    def resize(mut self, delta: Int) raises:
        """Apply a change to `SETTINGS_INITIAL_WINDOW_SIZE`.

        RFC 9113 section 6.9.2. A new initial size does not set the window, it
        shifts it by the difference, because the octets already granted and not
        yet spent have to survive the change. Shifting down past zero is legal
        and leaves us owing the difference.

        Only stream windows move. The connection window is not affected by this
        setting at all, which is easy to get wrong and produces a client that
        stalls or oversends only on connections where the server changes the
        setting mid stream.
        """
        var moved = self.available + delta
        if moved > MAX_WINDOW:
            raise _remote(
                String(
                    (
                        "the server raised SETTINGS_INITIAL_WINDOW_SIZE far"
                        " enough to push a window to "
                    ),
                    moved,
                    ", over the ",
                    MAX_WINDOW,
                    " a window can hold",
                )
            )
        if moved < MIN_WINDOW:
            raise _remote(
                "the server lowered SETTINGS_INITIAL_WINDOW_SIZE far enough to"
                " push a window below what one can hold"
            )
        self.available = moved


struct ReceiveWindow(ImplicitlyCopyable, Movable):
    """How much we have told the peer it may send, and what we owe it back.

    The peer is not asked to guess. Every octet it sends comes out of `_allowed`,
    and the only way that goes back up is a `WINDOW_UPDATE` we send, so a window
    we forget to return is a transfer that stops and never resumes. That failure
    is silent and looks exactly like a slow server, which is the reason
    `restore` returns the number to send rather than leaving the caller to work
    out when one is due.
    """

    var _capacity: Int
    """What a full window is. Also the size we advertised."""

    var _allowed: Int
    """How much the peer may still send before it has to wait."""

    var _pending: Int
    """Consumed by the caller and not yet given back."""

    def __init__(out self, capacity: Int = DEFAULT_WINDOW_SIZE):
        self._capacity = capacity
        self._allowed = capacity
        self._pending = 0

    def capacity(self) -> Int:
        return self._capacity

    def allowed(self) -> Int:
        return self._allowed

    def record(mut self, amount: Int) raises:
        """Account for `amount` octets the peer sent, padding included.

        `FLOW_CONTROL_ERROR`. This is the check that makes the window mean
        anything. Without it the window is a suggestion, and a peer that ignores
        it can push as much as it likes into a client that keeps buffering
        because it never looked.
        """
        if amount > self._allowed:
            raise _remote(
                String(
                    "the server sent ",
                    amount,
                    " bytes into a flow control window of ",
                    self._allowed,
                )
            )
        self._allowed -= amount

    def restore(mut self, amount: Int) -> Int:
        """Note that the caller consumed `amount`, and say what to give back.

        Zero means nothing is due yet. Returning every octet the moment it is
        read would put a `WINDOW_UPDATE` on the wire for every `DATA` frame,
        which is a frame of overhead per frame of payload. Waiting until the
        window is empty would stall, because the peer stops the instant it runs
        out and cannot start again until the update arrives. Half is the usual
        compromise and it is what nghttp2 and the Go implementation both use:
        the peer always has at least half a window in hand while an update is in
        flight.
        """
        self._pending += amount
        if self._pending * 2 < self._capacity:
            return 0

        var giving = self._pending
        self._pending = 0
        self._allowed += giving
        return giving

    def outstanding(self) -> Int:
        """Consumed but not yet returned. What `restore` is sitting on."""
        return self._pending
