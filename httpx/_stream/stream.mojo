"""One type for the two kinds of connection the protocol layer can have.

`Stream` is either a plain `TcpStream` or a `TlsStream`, and it forwards every
call to whichever one it holds. The HTTP layer above uses it without ever
asking which, which is what lets `http://` and `https://` share one code path.

This is a tagged union spelled with two `Optional` fields, exactly one of which
is filled. Mojo 1.0 has no trait objects, so the alternatives are this, a
pointer plus a manually written vtable, or making every type above this one
generic over the stream. The vtable is what `_util/erase.mojo` does for
transports, and it is worth its cost there because the set of transports is
open: a user can write one. The set of streams is not open, it has two members
and will have at most three, so a union that the compiler can see through is
both simpler and faster than a call through a pointer.

The cost is one wasted `Optional` per connection and a branch per read. The
branch predicts perfectly, because a connection is one kind or the other for
its whole life.
"""

from httpx._io.deadline import Deadline
from httpx._io.socket import TcpStream
from httpx._stream.tls import TlsStream
from std.ffi import c_int


struct Stream(Movable):
    """A connection, encrypted or not.

    Non copyable, like both of the things it can hold. Constructing one from a
    `TcpStream` is implicit so that plain HTTP code and the tests read the same
    as they did before TLS existed.
    """

    var _plain: Optional[TcpStream]
    var _tls: Optional[TlsStream]

    @implicit
    def __init__(out self, var tcp: TcpStream):
        self._plain = Optional(tcp^)
        self._tls = None

    @implicit
    def __init__(out self, var tls: TlsStream):
        self._plain = None
        self._tls = Optional(tls^)

    def is_secure(self) -> Bool:
        """Whether there is TLS on this connection.

        The pool asks, so that it never hands a plain connection to a request
        for an https origin. That would be an unencrypted request to a URL that
        promised otherwise, which is the one confusion here that is a security
        bug rather than an inconvenience.
        """
        return self._tls.__bool__()

    def fd(self) -> c_int:
        if self._tls:
            return self._tls.value().fd()
        return self._plain.value().fd()

    def peer(self) -> String:
        if self._tls:
            return self._tls.value().peer()
        return self._plain.value().peer()

    def is_open(self) -> Bool:
        if self._tls:
            return self._tls.value().is_open()
        return self._plain.value().is_open()

    def read[
        o: MutOrigin
    ](mut self, buf: Span[UInt8, o], deadline: Deadline) raises -> Int:
        if self._tls:
            return self._tls.value().read(buf, deadline)
        return self._plain.value().read(buf, deadline)

    def write[
        o: ImmOrigin
    ](mut self, data: Span[UInt8, o], deadline: Deadline) raises:
        if self._tls:
            self._tls.value().write(data, deadline)
            return
        self._plain.value().write(data, deadline)

    def has_data_waiting(self) raises -> Bool:
        if self._tls:
            return self._tls.value().has_data_waiting()
        return self._plain.value().has_data_waiting()

    def is_closed_by_peer(self) raises -> Bool:
        if self._tls:
            return self._tls.value().is_closed_by_peer()
        return self._plain.value().is_closed_by_peer()

    def shutdown_write(mut self):
        if self._tls:
            self._tls.value().shutdown_write()
            return
        self._plain.value().shutdown_write()

    def close(mut self):
        if self._tls:
            self._tls.value().close()
            return
        self._plain.value().close()

    def alpn_protocol(self) raises -> String:
        """What TLS negotiated, or empty on a plain connection.

        Empty for both a plain connection and a TLS one where the server
        ignored ALPN, which is deliberate: in both cases the answer to what
        protocol to speak is HTTP/1.1.
        """
        if self._tls:
            return self._tls.value().alpn_protocol()
        return String()

    def tls_version(self) raises -> String:
        """`TLSv1.3` and friends, or empty on a plain connection."""
        if self._tls:
            return self._tls.value().protocol_version()
        return String()

    def tls_cipher(self) raises -> String:
        if self._tls:
            return self._tls.value().cipher_name()
        return String()
