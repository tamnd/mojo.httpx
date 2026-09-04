"""Happy Eyeballs: connect to the address that answers, not the one listed first.

RFC 8305. A host with both an A and an AAAA record on a network where IPv6 does
not actually work is the most common way for an HTTP client to feel broken.
Trying the addresses one at a time means every request to that host waits out a
full connect timeout before it gets anywhere, and the user sees a client that
takes thirty seconds to fetch a page their browser fetches instantly, because
their browser does this.

The shape is a staggered race. Start connecting to the first address. If it has
not finished after a short delay, start the second as well, without giving up on
the first. Keep adding attempts on that cadence until one connects, then close
the rest. The delay is what keeps this from being a connection storm: on a
network where the first address works, the second attempt is never started.

Everything here rests on the connect being non blocking, which is why
`start_connect` and `PendingConnect.finished` are separate from each other in
socket.mojo. A blocking connect cannot be raced with anything.
"""

from std.ffi import c_int, c_uint

from httpx._exceptions import ErrorKind, message_of, new_error
from httpx._ffi.netdb import SockAddr
from httpx._ffi.socket import PollFd, poll
from httpx._io.deadline import NANOS_PER_MS, Deadline, now_ns
from httpx._io.dns import Resolver
from httpx._io.socket import PendingConnect, TcpStream, start_connect

comptime ATTEMPT_DELAY_MS = 250
"""How long to wait before starting the next attempt.

RFC 8305 section 5 calls this the Connection Attempt Delay and recommends 250
milliseconds, with a floor of 10 and a ceiling of 2000. It is chosen to be
longer than a round trip on a working path and much shorter than a connect
timeout, so a working first address wins outright and a broken one costs a
quarter of a second instead of the whole budget.
"""

comptime MAX_ATTEMPTS = 6
"""How many attempts may be in flight at once.

A resolver can return a long list, and starting a socket for every entry turns
one request into a burst that looks like a scan. Six covers three of each
family, which is more than enough for the race to find a working path.
"""

comptime WAIT_SLICE_MS = 1
"""How long the loop parks between checks of the attempts in flight.

Short enough that the winning connect is noticed as soon as it completes, long
enough that the loop is not a spin. A connect that resolves in under a
millisecond is a connect to loopback, and one extra millisecond there costs
nothing that anybody can measure.
"""


def connect_to_host(
    mut resolver: Resolver,
    host: StringSpan,
    port: UInt16,
    deadline: Deadline,
) raises -> TcpStream:
    """Resolve `host` and connect to whichever address answers first.

    The deadline covers resolution and every attempt together, because from the
    caller's point of view this is one operation with one budget. Handing each
    attempt its own copy would let a host with six addresses take six times the
    configured connect timeout.
    """
    var addresses = resolver.lookup(host, port)
    var peer = String(host, ":", port)
    try:
        return connect_to_addresses(Span(addresses), peer, deadline)
    except e:
        # Every address failed. The most likely reason for that on a host that
        # worked before is an answer that has gone stale, so the next attempt
        # gets a fresh lookup rather than the same list back.
        resolver.forget(host, port)
        raise e


def connect_to_addresses[
    o: ImmOrigin
](
    addresses: Span[SockAddr, o], peer: String, deadline: Deadline
) raises -> TcpStream:
    """Race the addresses in order and return the first connection to complete.

    Split out from `connect_to_host` so a caller that already has addresses, a
    proxy or a pinned host, does not have to go through the resolver to use the
    race.
    """
    if len(addresses) == 0:
        raise new_error(
            ErrorKind.CONNECT_ERROR, String("no addresses to try for ", peer)
        )

    var pending = List[PendingConnect]()
    var failures = List[String]()
    var next_address = 0
    var next_start_ns = now_ns()

    while True:
        # Checked before anything is started, so that a deadline which has
        # already passed reports a timeout rather than racing it. A caller
        # asking for a connect with no time left is asking for the answer, not
        # for one attempt to be squeezed in first.
        deadline.check(String("connect to ", peer))

        # Start the next attempt when its turn comes round, which on the first
        # pass is immediately. Starting is cheap and does not wait.
        if (
            next_address < len(addresses)
            and len(pending) < MAX_ATTEMPTS
            and now_ns() >= next_start_ns
        ):
            try:
                pending.append(start_connect(addresses[next_address], peer))
            except e:
                failures.append(message_of(e))
            next_address += 1
            next_start_ns = now_ns() + UInt64(ATTEMPT_DELAY_MS * NANOS_PER_MS)

        var lost = len(failures)
        var winner = winner_index(pending, failures)
        if winner >= 0:
            var won = pending.pop(winner)
            # The losers are dropped here rather than left to fall out of scope
            # at the end of the function, so the half open connections a race
            # necessarily creates stop occupying the server's accept queue as
            # soon as they are known to be surplus.
            pending.clear()
            return won.take_stream()

        if len(failures) > lost:
            # RFC 8305 section 5: an attempt that failed does not have to be
            # waited out. Without this a host whose first address is refused
            # still costs the full delay before the second address is tried,
            # which is the delay doing harm rather than good.
            next_start_ns = now_ns()

        if len(pending) == 0 and next_address >= len(addresses):
            raise all_failed(peer, failures)

        park_briefly(deadline, WAIT_SLICE_MS)


def winner_index(
    mut pending: List[PendingConnect], mut failures: List[String]
) raises -> Int:
    """Check every attempt in flight and report the first that connected.

    Returns an index rather than the stream itself so that the caller owns the
    move out of the list, which is the only place that can also decide what to
    do with the attempts that lost.

    A failed attempt is dropped and its reason kept rather than raised, because
    one address failing says nothing about the others and the caller only cares
    once they have all gone. Walking backwards so removing an entry does not
    shift the ones not yet looked at.

    Shared with the async race in `httpx._io.aio_connect` rather than copied.
    The loop around the attempts is what differs between the two clients; how an
    attempt is judged is not, and the two giving different answers would be a
    bug nobody would look for.
    """
    var found = -1
    var i = len(pending) - 1
    while i >= 0:
        var done: Bool
        try:
            done = pending[i].finished()
        except e:
            failures.append(message_of(e))
            _ = pending.pop(i)
            i -= 1
            continue
        if done:
            found = i
        i -= 1
    return found


def all_failed(peer: String, failures: List[String]) -> Error:
    """One error naming every attempt, rather than whichever failed last.

    A host whose IPv6 address is refused and whose IPv4 address times out is a
    different problem from one where both are refused, and the only way for a
    user to tell them apart is to be shown both.

    Every entry in `failures` is a message with its kind name already stripped,
    because this puts one back on. Collecting the whole `String(e)` instead
    produced `ConnectError: ConnectError: connect ... refused`, which is what a
    user saw at a command line before this was noticed.

    Shared with the async race, for the reason on `winner_index`.
    """
    if len(failures) == 1:
        return new_error(ErrorKind.CONNECT_ERROR, failures[0])
    var message = String("could not connect to ", peer)
    for i in range(len(failures)):
        message += String("\n  ", failures[i])
    return new_error(ErrorKind.CONNECT_ERROR, message)


def park_briefly(deadline: Deadline, slice_ms: Int):
    """Park for at most `slice_ms`, never past the deadline, while the attempts
    make progress.

    `poll` with no descriptors at all is the portable way to wait for a fixed
    time without a sleep call. Waiting on the sockets themselves would be the
    textbook answer and needs an array of `pollfd` rebuilt on every pass beside
    the list that owns the streams. At six descriptors and a millisecond the
    difference is unmeasurable, and the version without the array is the one
    that is obviously correct.

    The deadline is what bounds the wait rather than decorating it: a request
    with three milliseconds left does not park for longer than that.

    The slice is an argument because the async race wants a zero length one for
    its first rounds. A coroutine that parks before it has given way once is a
    coroutine that made every other task wait for a syscall it did not need.
    """
    var slice = deadline.remaining_ms()
    if slice > slice_ms:
        slice = slice_ms
    # Ignored, because `nfds` is zero. `poll` still wants an address.
    var unused = PollFd(c_int(-1), Int16(0), Int16(0))
    _ = poll(Pointer(to=unused), c_uint(0), c_int(slice))
