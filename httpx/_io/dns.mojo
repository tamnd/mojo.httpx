"""Name resolution, and the address ordering Happy Eyeballs needs.

`getaddrinfo` is the only resolver available to us and it has one property that
shapes everything here: it blocks and cannot be interrupted. A connect deadline
cannot stop a stalled lookup, so a resolution that hangs hangs the request. That
is a real limitation rather than an oversight, and the answer is to do fewer
lookups rather than to pretend the one we do is cancellable.

Two things reduce the number. A host written as an address is recognised and
never looked up at all, which is the common case for a client talking to a fixed
IP. Everything else goes through a small cache with a time to live, which takes
the lookup off the steady state path entirely: a client making a thousand
requests to one host resolves it once a minute rather than a thousand times.

The ordering is the other half. RFC 8305 says to interleave the families
starting with IPv6, which is what makes the staggered connect in connect.mojo
worth doing: if the first two addresses are both IPv6 and IPv6 is broken on this
network, staggering just delays the same failure twice.
"""

from std.ffi import c_int

from httpx._exceptions import ErrorKind, new_error
from httpx._ffi.clock import unix_now
from httpx._ffi.netdb import AF_UNSPEC, SockAddr, is_ip_literal, resolve
from httpx._ffi.socket import AF_INET, AF_INET6

comptime DEFAULT_TTL_SECONDS = 60
"""How long a resolved answer is reused.

Short enough that a DNS change takes effect within a minute, which is the
resolution most operational changes are planned at, and long enough that a busy
client is not resolving on every request. Matching the record's own TTL would be
better and `getaddrinfo` does not report it.
"""

comptime MAX_CACHE_ENTRIES = 256
"""A bound, so a client walking a list of hostnames cannot grow this without
limit. Small: a process talks to a handful of hosts, and the one that talks to
thousands is better served by turning the cache off."""


struct Resolved(Movable):
    """The addresses for one host and port, and when they stop being usable."""

    var addresses: List[SockAddr]
    var expires_at: Int
    """Unix seconds. Wall clock rather than monotonic, because this is compared
    against nothing but itself and a wall clock jump costs at most one extra
    lookup, whereas a monotonic value could not be reasoned about in a log."""

    def __init__(out self, var addresses: List[SockAddr], expires_at: Int):
        self.addresses = addresses^
        self.expires_at = expires_at

    def copy(self) -> Self:
        return Self(self.addresses.copy(), self.expires_at)


struct Resolver(Movable):
    """`getaddrinfo` with a cache in front of it.

    Not thread safe, and does not need to be: Mojo 1.0 has no threads, and when
    it does this will be behind the same lock as the pool it lives in.
    """

    var _keys: List[String]
    var _values: List[Resolved]
    var _ttl: Int
    """Zero turns the cache off, which is what a caller who wants every request
    to see a fresh answer asks for."""

    def __init__(out self, ttl_seconds: Int = DEFAULT_TTL_SECONDS):
        self._keys = List[String]()
        self._values = List[Resolved]()
        self._ttl = ttl_seconds

    def lookup(
        mut self, host: StringSpan, port: UInt16
    ) raises -> List[SockAddr]:
        """The addresses to try for `host` and `port`, best first.

        Takes no deadline, and that is not an oversight the lint missed: there
        is no deadline that would be enforced. `getaddrinfo` blocks in libc with
        no way to interrupt it, so a deadline here would be a promise the
        function cannot keep. Saying so in the name would be worse, because the
        caller would then have to remember which of two spellings it was.
        """
        if host.byte_length() == 0:
            raise new_error(
                ErrorKind.CONNECT_ERROR, String("no host to connect to")
            )

        # A literal is not a name and never becomes one. Caching it would be
        # caching a parse.
        if is_ip_literal(host):
            return sort_for_happy_eyeballs(resolve(host, port, AF_UNSPEC))

        var key = String(host, ":", port)
        var hit = self._cached(key)
        if hit:
            return hit.take()

        var addresses = sort_for_happy_eyeballs(resolve(host, port, AF_UNSPEC))
        self._store(key, addresses)
        return addresses^

    def forget(mut self, host: StringSpan, port: UInt16):
        """Drop one entry.

        Called when every address for a host failed to connect, since the most
        likely explanation for that is an answer that has gone stale, and the
        retry should not be given the same list back.
        """
        var key = String(host, ":", port)
        for i in range(len(self._keys)):
            if self._keys[i] == key:
                _ = self._keys.pop(i)
                _ = self._values.pop(i)
                return

    def clear(mut self):
        self._keys.clear()
        self._values.clear()

    def cached_count(self) -> Int:
        """How many hosts are currently remembered.

        Named rather than spelled `len`, because the size of a cache is not the
        size of the thing it is a cache for, and a reader seeing `len(resolver)`
        would have to guess which was meant.
        """
        return len(self._keys)

    def _cached(mut self, key: String) -> Optional[List[SockAddr]]:
        var at = unix_now()
        for i in range(len(self._keys)):
            if self._keys[i] != key:
                continue
            if self._values[i].expires_at <= at:
                _ = self._keys.pop(i)
                _ = self._values.pop(i)
                return None
            return self._values[i].addresses.copy()
        return None

    def _store(mut self, var key: String, addresses: List[SockAddr]):
        if self._ttl <= 0:
            return
        # Oldest out first. A true LRU would need the access order tracked and
        # would buy nothing at this size, where the whole table fits in a cache
        # line's worth of pointers.
        while len(self._keys) >= MAX_CACHE_ENTRIES:
            _ = self._keys.pop(0)
            _ = self._values.pop(0)
        self._keys.append(key^)
        self._values.append(Resolved(addresses.copy(), unix_now() + self._ttl))


def sort_for_happy_eyeballs(var addresses: List[SockAddr]) -> List[SockAddr]:
    """Interleave the families, IPv6 first, keeping each family's own order.

    RFC 8305 section 4. The resolver's order within a family already reflects
    the destination address selection rules in RFC 6724, so it is preserved. All
    that changes is that the two families alternate, which is what gives the
    staggered connect something to stagger: a list that starts with two IPv6
    addresses on a host with no working IPv6 route spends two delays learning
    the same thing.

    IPv6 goes first because a dual stack host that has working IPv6 should use
    it, and because the whole point of the race is that being wrong about that
    costs 250 milliseconds rather than a connect timeout.
    """
    var sixes = List[SockAddr]()
    var fours = List[SockAddr]()
    var others = List[SockAddr]()
    for i in range(len(addresses)):
        if addresses[i].family == AF_INET6:
            sixes.append(addresses[i])
        elif addresses[i].family == AF_INET:
            fours.append(addresses[i])
        else:
            others.append(addresses[i])

    var out = List[SockAddr]()
    var at = 0
    while at < len(sixes) or at < len(fours):
        if at < len(sixes):
            out.append(sixes[at])
        if at < len(fours):
            out.append(fours[at])
        at += 1
    # A family we do not know about goes last rather than being dropped. It
    # cannot be interleaved sensibly and refusing it outright would turn a
    # resolver returning something unexpected into a failure.
    for i in range(len(others)):
        out.append(others[i])
    return out^
