"""Keeping connections around, and knowing when not to.

Connection reuse is most of what makes an HTTP client fast. A fresh TCP
connection to a server across the country costs a round trip before a byte of
request goes out, and a TLS handshake on top of that costs one or two more, so
a second request that reuses the first request's connection can easily be three
times quicker than one that does not.

The hard part is not the keeping, it is the discarding. A pooled connection is a
guess that the server has not closed its end, and the guess is wrong often
enough that a pool which never checks produces a client that fails one request
in a few hundred for no reason the user can see. So every connection is checked
for both age and liveness on the way out of the pool, and anything that has been
sitting long enough to be doubtful is closed rather than handed to a request.

Nothing here knows which protocol a connection speaks. That is decided once, by
ALPN, when the connection is made, and after that a `Connection` answers the
same questions whether it is HTTP/1.1 or HTTP/2. Reuse, expiry, limits and
eviction are all the same problem in both, so keeping the pool protocol blind is
what stopped HTTP/2 turning into a second pool beside this one.

The pool runs the exchange itself rather than lending a connection out and
trusting the caller to give it back. A borrowed connection that is dropped on an
error path is a descriptor leak in the best case and a connection returned to the
pool in an unknown state in the worst, and the second one hands somebody else's
response to the wrong caller. Doing the exchange here makes both impossible.

Streaming is the one case that cannot work that way. A response whose body is
still on the wire is a connection that has to stay out of the pool until the
caller has finished with it, so `stream_request` does lend one out, wrapped in a
`PooledSource` that gives it back the moment the body ends and closes it if
anything else happens first, including the caller simply dropping the response.
That is why the pool is held through a shared handle: the source has to be able
to reach it long after the call that made it returned.

A pool is either a direct pool or a proxy pool, decided once when it is built.
That is httpcore's arrangement and it is the one that cannot go wrong: a pool
keys its idle connections by origin, and if the same pool could serve some
requests directly and some through a proxy then a connection to the proxy and a
connection to the server would be filed under different keys for the same host,
or worse, under the same one. Deciding at the pool rather than at the request
means the connection to the proxy is only ever reused by another request that is
also going through it.

A tunnel is the exception that proves it. A `CONNECT` to an https server is filed
under the server rather than under the proxy, because that is what is on the far
end of it: the pipe reaches one host and nothing else, so a request for a
different host cannot use it even though it went through the same proxy.
"""

from std.memory import ArcPointer

from httpx._exceptions import ErrorKind, new_error
from httpx._io.connect import connect_to_host
from httpx._io.deadline import (
    NANOS_PER_SECOND,
    Deadline,
    Deadlines,
    now_ns,
)
from httpx._io.dns import Resolver
from httpx._io.socket import TcpStream
from httpx._models.headers import Headers
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._models.stream import ByteSource, erase_source
from httpx._pool.connection import Connection
from httpx._pool.limits import Limits
from httpx._pool.origin import Origin, origin_for
from httpx._pool.proxy import Hop, Proxy, route_through
from httpx._proto.h1.head import ResponseHead
from httpx._proto.h1.tunnel import open_tunnel
from httpx._proto.h1.writer import TargetForm
from httpx._stream.config import TlsConfig
from httpx._stream.stream import Stream
from httpx._stream.tls import TlsStream
from httpx._ffi.openssl import SslCtx


struct PooledConnection(Movable):
    """One idle connection, with what the pool needs to judge it by."""

    var origin: Origin
    var idle_since_ns: UInt64
    """When it last finished an exchange. Age is measured from here rather than
    from when it was opened, because a connection carrying requests back to back
    is not the one a server is about to close."""

    var _conn: Optional[Connection]
    """An optional so that the connection can be taken back out again.

    Mojo will not move a field whose type has a destructor out of a value that
    still has to be destroyed, and a pooled connection exists precisely to be
    handed back later. The optional is the seam that makes the handing back a
    move rather than a copy of a socket.
    """

    def __init__(out self, var origin: Origin, var conn: Connection):
        self.origin = origin^
        self.idle_since_ns = now_ns()
        self._conn = Optional[Connection](conn^)

    def idle_seconds(self) -> Float64:
        var elapsed = now_ns() - self.idle_since_ns
        return Float64(elapsed) / Float64(NANOS_PER_SECOND)

    def take(mut self) -> Connection:
        return self._conn.take()

    def is_stale(self, expiry: Optional[Float64]) -> Bool:
        """Whether this connection is too doubtful to hand to a request.

        Two checks, and both of them matter. Age is the cheap one: a connection
        idle for longer than the keepalive expiry is one the server has probably
        already closed, and finding that out by sending a request means the
        request fails for a reason the user cannot act on. Liveness is the
        honest one: a peer that closed cleanly leaves the socket readable at end
        of file, and asking about that costs one non blocking call.

        Neither check can be skipped for being unlikely. On a busy client the
        unlikely case happens continuously.
        """
        if expiry and self.idle_seconds() >= expiry.value():
            return True
        if not self._conn:
            return True
        try:
            return not self._conn.value().is_reusable()
        except:
            # A connection we cannot even ask about is one we cannot trust.
            return True


struct ConnectionPool(Movable):
    """Connections to reuse, keyed by origin, with limits kept honestly.

    There is no lock. The library is single threaded today, and a lock that
    nothing contends is a lie about what has been thought through. The place a
    lock will go is where `_leased` is adjusted, and that is deliberately the
    only mutable count in the type, so that adding one later is a small change
    rather than an audit.
    """

    var limits: Limits
    var resolver: Resolver
    var tls: TlsConfig
    """What to do about certificates, kept here rather than at the transport
    because this is where a connection is made and so the only place that can
    apply it."""

    var proxy: Optional[Proxy]
    """The proxy every request from this pool goes through, if there is one.

    Fixed for the life of the pool. See the note at the top of the module about
    why this is not decided per request.
    """

    var _ssl_ctx: Optional[SslCtx]
    """Built on the first https connection, then shared by every later one.

    Lazy on purpose. Building it parses the whole trust store, and a client
    that only ever talks to `http://` should not pay for that, nor should it
    fail to start on a machine with no OpenSSL on it.
    """

    var _idle: List[PooledConnection]
    """Idle connections, oldest first.

    A list rather than a map from origin to connections. The scan is linear in
    the number of idle connections, which the limits cap at a couple of dozen,
    and a linear scan of twenty entries is faster than hashing a string. Oldest
    first is what makes eviction and expiry both a walk from the front.
    """

    var _leased: Int
    """Connections currently carrying an exchange, so not in `_idle`.

    Counted rather than held, because the value has been moved out to whoever is
    using it. This is what makes the total limit cover connections in use as
    well as connections waiting.
    """

    def __init__(
        out self,
        var limits: Limits,
        ttl_seconds: Int = 60,
        var tls: TlsConfig = TlsConfig(),
        var proxy: Optional[Proxy] = None,
    ):
        self.limits = limits^
        self.resolver = Resolver(ttl_seconds)
        self.tls = tls^
        self.proxy = proxy^
        self._ssl_ctx = None
        self._idle = List[PooledConnection]()
        self._leased = 0

    def idle_count(self) -> Int:
        return len(self._idle)

    def leased_count(self) -> Int:
        return self._leased

    def total_count(self) -> Int:
        return len(self._idle) + self._leased

    def close(mut self):
        """Close every idle connection.

        Says nothing about leased ones, because they are not here to close. A
        connection in the middle of an exchange is closed by whoever is running
        it, when it ends.
        """
        while len(self._idle) > 0:
            self._evict_oldest()

    def handle_request(
        mut self,
        var request: Request,
        deadlines: Deadlines,
        form: TargetForm = TargetForm.ORIGIN,
    ) raises -> Response:
        """Send `request` on a pooled or new connection and read the answer.

        The connection is taken out of the pool for the whole exchange and put
        back only if it finished in a state that can carry another request. An
        exchange that raised takes its connection with it, because a connection
        whose framing went wrong cannot be told apart from one whose next byte
        is somebody else's response.

        The request goes out inside the response it produced. That is what lets
        the client above follow a redirect or answer a challenge without having
        kept a copy of every request it has ever sent.
        """
        var route = self._route(request, form)
        var conn = self._acquire(route, deadlines)
        self._leased += 1

        var response: Response
        try:
            response = conn.exchange(
                request, deadlines.write, deadlines.read, route.form
            )
        except e:
            self._leased -= 1
            conn.close()
            raise e

        self._leased -= 1
        self._release(route.origin, conn^)
        response.set_request(request^)
        return response^

    def _route(mut self, mut request: Request, form: TargetForm) raises -> Hop:
        """Where this request goes, once the pool's proxy has had its say."""
        return route_through(self.proxy, request, form)

    def _acquire(
        mut self, route: Hop, deadlines: Deadlines
    ) raises -> Connection:
        """A connection for `route`, reused if there is a sound one to reuse.

        A new connection comes back already knowing which protocol it speaks.
        `Connection` asks the stream what ALPN settled on, which is the only
        place the answer exists and the only moment it can be had, so there is
        no protocol decision anywhere else in the pool.

        Reuse is decided by `route.origin` alone and that is enough, because a
        pool is either a direct pool or a proxy pool for its whole life. Within
        one pool the same origin always means the same way of getting there.
        """
        var origin = route.origin
        var found = self._take_idle(origin)
        if found:
            return found.take()

        self._make_room(origin, deadlines)
        var tcp: TcpStream
        if route.connect_via:
            tcp = self._tunnel_to(origin, route.connect_via.value(), deadlines)
        else:
            tcp = connect_to_host(
                self.resolver, origin.host, origin.port, deadlines.connect
            )

        if not origin.is_secure():
            # Always HTTP/1.1. HTTP/2 without TLS exists but has no negotiation
            # in it: both ends have to have been told beforehand, and a client
            # that assumed it would break every plain HTTP server there is. The
            # way to ask for it is `http2=True` on the client, over https, where
            # ALPN can settle it without guessing.
            return Connection(Stream(tcp^))

        # Built here, on the first https connection, and shared by every one
        # after it. `TlsStream` takes its own reference on the context through
        # `SSL_new`, so the pool holding the only Mojo side handle is what
        # keeps it alive and nothing has to order the two lifetimes by hand.
        if not self._ssl_ctx:
            self._ssl_ctx = Optional(self.tls.build())
        return Connection(
            Stream(
                TlsStream(
                    tcp^,
                    self._ssl_ctx.value(),
                    origin.host,
                    self.tls.verify.enabled,
                    deadlines.connect,
                )
            )
        )

    def _tunnel_to(
        mut self, target: Origin, via: Origin, deadlines: Deadlines
    ) raises -> TcpStream:
        """Open a socket to `via` and CONNECT it through to `target`.

        Comes back before TLS, on purpose. What this returns is a bare TCP
        stream that happens to reach the server rather than the proxy, and
        `_acquire` then hands it to `TlsStream` with the server's name on it,
        so the certificate is checked against the host the caller asked for and
        the proxy is not in a position to present one of its own.

        `via` is an `http://` proxy, which `route_through` has already made sure
        of, so there is no TLS on this socket until `_acquire` puts it there.
        """
        var tcp = connect_to_host(
            self.resolver, via.host, via.port, deadlines.connect
        )
        var headers = Headers()
        if self.proxy:
            headers = self.proxy.value().headers.copy()
        open_tunnel(tcp, target.authority(), headers, deadlines.connect)
        return tcp^

    def _take_idle(mut self, origin: Origin) -> Optional[Connection]:
        """The oldest sound idle connection to `origin`, closing any that are
        not.

        The candidate leaves the list before it is judged. Judging it in place
        and then removing it would mean two passes over the same entry, and the
        entry is a socket rather than a number, so the shorter path is the one
        with fewer chances to leave a descriptor behind.
        """
        var i = 0
        while i < len(self._idle):
            if self._idle[i].origin != origin:
                i += 1
                continue
            var candidate = self._idle.pop(i)
            var stale = candidate.is_stale(self.limits.keepalive_expiry)
            var conn = candidate.take()
            if stale:
                conn.close()
                continue
            return Optional[Connection](conn^)
        return None

    def _make_room(mut self, origin: Origin, deadlines: Deadlines) raises:
        """Get under the total limit, or explain why that is not possible.

        Evicting an idle connection to some other origin is the right trade when
        the pool is full: the connection being evicted is doing nothing, and the
        request being served is real. Only when every connection is leased is
        there nothing to give up, and then the wait is on the program itself
        rather than on the network, which is what `PoolTimeout` says.
        """
        if not self.limits.max_connections:
            return
        var allowed = self.limits.max_connections.value()
        while self.total_count() >= allowed and len(self._idle) > 0:
            self._evict_oldest()
        if self.total_count() >= allowed:
            raise new_error(
                ErrorKind.POOL_TIMEOUT,
                String(
                    "all ",
                    allowed,
                    (
                        " connections are in use and none can be freed, so"
                        " there is"
                    ),
                    " no way to reach ",
                    origin,
                ),
            )
        # Only reached when a slot was found, so the pool wait is over. Checked
        # afterwards rather than before because a deadline that passed while
        # nothing was being waited for is not a pool timeout.
        deadlines.pool.check(String("get a connection to ", origin))

    def _release(mut self, var origin: Origin, var conn: Connection):
        """Put a finished connection back, or close it.

        A connection only goes back if it says it can carry another request. The
        question is asked of the connection rather than answered here, because
        the state machine that ran the exchange is the only thing that knows how
        it ended.
        """
        var reusable: Bool
        try:
            reusable = conn.is_reusable()
        except:
            reusable = False
        if not reusable:
            conn.close()
            return

        var allowance = self.limits.keepalive_allowance()
        if allowance == 0:
            conn.close()
            return

        self._idle.append(PooledConnection(origin^, conn^))
        while allowance > 0 and len(self._idle) > allowance:
            # The oldest idle connection is the one closest to being closed by
            # the server anyway, so it is the one worth the least.
            self._evict_oldest()

    def _evict_oldest(mut self):
        var oldest = self._idle.pop(0)
        var conn = oldest.take()
        conn.close()


comptime SharedPool = ArcPointer[ConnectionPool]
"""A pool that more than one thing can hold.

A streaming response outlives the call that produced it, and the connection it
is reading from has to go back to the pool when the body ends. So the source
carries a handle rather than a reference: the pool stays alive as long as
anything is still reading from one of its connections, which is exactly the
lifetime that matters and is not one a borrow could express.
"""


struct PooledSource(ByteSource, Movable):
    """A response body still on a connection, with the connection to give back.

    Owns the connection for as long as the body is being read, and does one of
    two things when that stops: hands it back to the pool if the body ended the
    way it said it would, or closes it if anything else happened. Both paths
    also give the lease back, which is what keeps the pool's limit honest when a
    caller walks away from a response halfway through.
    """

    var _pool: SharedPool
    var _origin: Origin
    var _conn: Optional[Connection]
    """Nothing once the connection has gone back or been closed.

    Which is also how `read_chunk` knows there is no more body: an empty chunk
    and a missing connection are the same answer, so a caller that keeps reading
    past the end gets the ending again rather than an error.
    """

    var _deadline: Deadline
    """The read deadline, applied to each read rather than to the whole body.

    Which is what lets a download that keeps making progress run as long as it
    likes while a server that goes quiet mid body still fails.
    """

    var _trailers: Headers

    def __init__(
        out self,
        var pool: SharedPool,
        origin: Origin,
        var conn: Connection,
        deadline: Deadline,
    ):
        self._pool = pool^
        self._origin = origin
        self._conn = Optional[Connection](conn^)
        self._deadline = deadline
        self._trailers = Headers()

    def read_chunk(mut self) raises -> List[UInt8]:
        if not self._conn:
            return List[UInt8]()
        var chunk: List[UInt8]
        try:
            chunk = self._conn.value().read_chunk(self._deadline)
        except e:
            # The connection closed itself on the way out of `read_chunk`, so
            # all that is left here is to stop holding it and give the lease
            # back. Re-raised because a truncated body is the caller's problem.
            self._drop()
            raise e
        if len(chunk) == 0:
            self._give_back()
        return chunk^

    def close(mut self):
        """Give up whatever is left of the body and release the connection.

        Always a close rather than a return to the pool, even on a connection
        that would have been reusable. Whatever is left of the body is still on
        the wire, and a connection whose next byte is the middle of somebody
        else's response is not one to hand to the next request.

        HTTP/2 does not have to lose the connection for this. An abandoned
        stream can be reset and the connection kept, because the frames say
        which stream they belong to and the leftovers of one are not in anybody
        else's way. Not done yet, so an abandoned HTTP/2 body costs a
        connection the same as an HTTP/1.1 one does.
        """
        self._drop()

    def trailers(self) -> Headers:
        return self._trailers.copy()

    def __deinit__(deinit self):
        """A response dropped without being read still gives its lease back.

        Without this the connection would be closed by its own destructor but
        the pool would go on counting it as in use, and a program that abandoned
        a few streaming responses would eventually be told its pool is full when
        it is empty.
        """
        if self._conn:
            var conn = self._conn.take()
            conn.close()
            self._pool[]._leased -= 1

    def _give_back(mut self):
        var conn = self._conn.take()
        self._trailers = conn.take_trailers()
        self._pool[]._leased -= 1
        self._pool[]._release(self._origin, conn^)

    def _drop(mut self):
        if not self._conn:
            return
        var conn = self._conn.take()
        conn.close()
        self._pool[]._leased -= 1


def stream_request(
    var pool: SharedPool,
    var request: Request,
    deadlines: Deadlines,
    form: TargetForm = TargetForm.ORIGIN,
) raises -> Response:
    """Send `request` and return as soon as the head has been read.

    The body stays on the connection and comes out through the response's
    iterators, which is the point: a caller downloading a large file or reading
    an event stream should not have to hold the whole thing in memory, and a
    caller who only wanted the status line should not have to wait for a body
    they are about to throw away.

    The connection is not back in the pool when this returns. It goes back when
    the body ends, or is closed when the response is closed or dropped, and
    either way the caller does not have to do anything for that to happen.
    """
    var route = pool[]._route(request, form)
    var conn = pool[]._acquire(route, deadlines)
    pool[]._leased += 1

    var head: ResponseHead
    try:
        conn.send_request(request, deadlines.write, route.form)
        head = conn.start_response(deadlines.read)
    except e:
        pool[]._leased -= 1
        conn.close()
        raise e

    var source = PooledSource(pool^, route.origin, conn^, deadlines.read)
    var response = Response.streaming(
        head.status_code,
        erase_source(source^),
        head.reason_phrase.copy(),
        head.http_version.copy(),
        head.take_headers(),
    )
    response.set_request(request^)
    return response^
