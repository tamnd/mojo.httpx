"""A TCP stream with TLS on top of it.

`TlsStream` reads and writes like `TcpStream` and is used the same way, which
is the whole point: the HTTP layer above it does not know or care which one it
has.

The socket underneath is non blocking, and that is what makes this work.
OpenSSL asks for more data by returning `SSL_ERROR_WANT_READ` instead of
blocking, so every operation here is a loop that calls OpenSSL, and when
OpenSSL says it needs the socket, waits on the socket with the caller's
deadline and goes round again. A blocking socket would hand the waiting to
OpenSSL, which has no deadline and would sit there forever.

Note that a TLS read can want to write and a TLS write can want to read.
Renegotiation and post handshake authentication both send records in the
direction opposite to the data, so `read` waits for writability when told to
and `write` waits for readability. Getting this wrong produces a client that
works until the day a server asks for a new key, which is a bad day to find
out.

The error messages are longer than they usually are in this codebase. A TLS
failure is the one a user is least equipped to diagnose from a code, so each
one says what was being checked, what the certificate actually said, and what
would make it work.
"""

from httpx._exceptions import ErrorKind, new_error
from httpx._ffi.netdb import is_ip_literal
from httpx._ffi.openssl import (
    SSL_ERROR_SSL,
    SSL_ERROR_SYSCALL,
    SSL_ERROR_WANT_READ,
    SSL_ERROR_WANT_WRITE,
    SSL_ERROR_ZERO_RETURN,
    Ssl,
    SslCtx,
    X509_V_ERR_CERT_HAS_EXPIRED,
    X509_V_ERR_CERT_NOT_YET_VALID,
    X509_V_ERR_CERT_REVOKED,
    X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT,
    X509_V_ERR_HOSTNAME_MISMATCH,
    X509_V_ERR_IP_ADDRESS_MISMATCH,
    X509_V_ERR_SELF_SIGNED_CERT_IN_CHAIN,
    X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY,
    X509_V_OK,
    clear_errors,
    error_text,
    verify_error_text,
)
from httpx._io.deadline import Deadline
from httpx._io.socket import TcpStream
from std.ffi import c_int


def _certificate_advice(code: Int, hostname: StringSpan) -> String:
    """What to actually do about a verification failure, where we know.

    Only the handful of results a user hits in practice get an extra sentence.
    Everything else falls through to OpenSSL's own description, which is
    accurate and terse and better than a guess.
    """
    if code == X509_V_ERR_HOSTNAME_MISMATCH:
        return String(
            " The certificate is valid but was not issued for '",
            hostname,
            "'. Check the address, or connect by the name on the certificate.",
        )
    if code == X509_V_ERR_IP_ADDRESS_MISMATCH:
        return String(
            " The certificate does not list ",
            hostname,
            (
                " as an address. Certificates for addresses are rare, so this"
                " is usually a sign the request should use a host name."
            ),
        )
    if code == X509_V_ERR_CERT_HAS_EXPIRED:
        return String(
            " The certificate has expired. If it looks current, check this"
            " machine's clock, because a clock set forward has the same"
            " symptom."
        )
    if code == X509_V_ERR_CERT_NOT_YET_VALID:
        return String(
            " The certificate is not valid yet, which almost always means this"
            " machine's clock is behind."
        )
    if (
        code == X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT
        or code == X509_V_ERR_SELF_SIGNED_CERT_IN_CHAIN
    ):
        return String(
            " The certificate signs itself, so nothing vouches for it. Pass"
            " the signing certificate as the CA bundle if this is a server you"
            " run."
        )
    if code == X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY:
        return String(
            " Nothing on this machine signed it. A server that is missing its"
            " intermediate certificates fails this way even when the"
            " certificate itself is fine."
        )
    if code == X509_V_ERR_CERT_REVOKED:
        return String(" The certificate was revoked by whoever issued it.")
    return String()


struct TlsStream(Movable):
    """One TLS connection, and the socket it runs over.

    Owns the socket. The `SSL` holds the descriptor but does not close it, so
    there is still exactly one owner, and it is this struct through its
    `TcpStream` field.

    Non copyable, because two copies would mean two objects believing they can
    close the same descriptor and send `close_notify` on the same session.
    """

    var _tcp: TcpStream
    var _ssl: Ssl
    var _hostname: String
    var _closed: Bool

    def __init__(
        out self,
        var tcp: TcpStream,
        ctx: SslCtx,
        hostname: String,
        verify: Bool,
        deadline: Deadline,
    ) raises:
        """Wrap a connected socket and complete the handshake before returning.

        The handshake is part of construction rather than a separate step
        because a `TlsStream` that has not handshaked is a thing that can only
        be misused, and the type not existing is a stronger guarantee than a
        flag saying it is not ready yet.

        `verify` comes in separately from the context even though the context
        already knows, because verification has a per connection half: the
        context decides whether the chain is checked, and this decides whether
        the name is. They are always set together, and the caller that has the
        config is the one place that can be sure of it.
        """
        self._tcp = tcp^
        self._ssl = Ssl(ctx)
        self._hostname = hostname.copy()
        self._closed = False
        self._ssl.set_fd(self._tcp.fd())

        # RFC 6066 section 3 says SNI carries a host name, not an address, so a
        # request to a literal sends no SNI at all. Servers behind a name based
        # front end will answer with a default certificate, which then fails
        # the address check below, and that is the correct outcome rather than
        # a limitation.
        if not is_ip_literal(hostname):
            self._ssl.set_sni_hostname(hostname)

        if verify:
            self._ssl.set_verify_hostname(hostname)

        self._handshake(deadline)

    def __deinit__(deinit self):
        pass

    def _handshake(mut self, deadline: Deadline) raises:
        """Drive `SSL_connect` to completion, or explain why it stopped."""
        while True:
            deadline.check(String("TLS handshake with ", self._hostname))
            clear_errors()
            var rc = self._ssl.connect()
            if rc == 1:
                return
            var code = self._ssl.last_error(rc)
            if code == SSL_ERROR_WANT_READ:
                _ = self._tcp.wait_readable(deadline)
                continue
            if code == SSL_ERROR_WANT_WRITE:
                _ = self._tcp.wait_writable(deadline)
                continue
            var failure = self._handshake_error(code)
            raise failure^

    def _handshake_error(self, code: Int) raises -> Error:
        """Turn a failed handshake into something worth reading.

        The certificate check is first because it is by far the most common
        reason a handshake fails and because OpenSSL's own message for it,
        "certificate verify failed", says nothing about which certificate or
        what was wrong with it.
        """
        var verdict = self._ssl.verify_result()
        if verdict != X509_V_OK:
            return new_error(
                ErrorKind.CONNECT_ERROR,
                String(
                    "the TLS certificate from ",
                    self._hostname,
                    " was rejected: ",
                    verify_error_text(verdict),
                    ".",
                    _certificate_advice(verdict, self._hostname),
                ),
            )
        if code == SSL_ERROR_SYSCALL or code == SSL_ERROR_ZERO_RETURN:
            return new_error(
                ErrorKind.CONNECT_ERROR,
                String(
                    "the connection to ",
                    self._hostname,
                    (
                        " closed during the TLS handshake. A server that only"
                        " speaks plain HTTP on this port does exactly this."
                    ),
                ),
            )
        return new_error(
            ErrorKind.CONNECT_ERROR,
            String(
                "the TLS handshake with ",
                self._hostname,
                " failed: ",
                error_text(),
            ),
        )

    def fd(self) -> c_int:
        """The descriptor underneath, for the pool's idle checks."""
        return self._tcp.fd()

    def peer(self) -> String:
        return self._tcp.peer()

    def is_open(self) -> Bool:
        return self._tcp.is_open()

    def hostname(self) -> String:
        """The name this connection was verified against."""
        return self._hostname.copy()

    def protocol_version(self) raises -> String:
        """`TLSv1.3` or `TLSv1.2`, for `response.extensions`."""
        return self._ssl.protocol_version()

    def cipher_name(self) raises -> String:
        return self._ssl.cipher_name()

    def alpn_protocol(self) raises -> String:
        """What the server chose, or empty if it did not choose.

        Empty means HTTP/1.1, because a server that ignores ALPN is a server
        that predates HTTP/2 or does not want it, and both of those speak
        HTTP/1.1.
        """
        return self._ssl.alpn_protocol()

    def read[
        o: MutOrigin
    ](mut self, buf: Span[UInt8, o], deadline: Deadline) raises -> Int:
        """Read decrypted bytes. Zero means the peer said it was finished.

        Zero only ever comes back after a `close_notify`. A connection that
        simply stops raises instead, because those two look identical to the
        HTTP layer above and are not the same thing at all: one is a server
        that finished, the other is somebody cutting the wire in the middle of
        a body whose length nothing declared.
        """
        while True:
            deadline.check(String("TLS read from ", self._hostname))
            clear_errors()
            var n = self._ssl.read(buf)
            if n > 0:
                return Int(n)
            var code = self._ssl.last_error(n)
            if code == SSL_ERROR_WANT_READ:
                _ = self._tcp.wait_readable(deadline)
                continue
            if code == SSL_ERROR_WANT_WRITE:
                _ = self._tcp.wait_writable(deadline)
                continue
            if code == SSL_ERROR_ZERO_RETURN:
                return 0
            if code == SSL_ERROR_SYSCALL:
                if self._ssl.peer_sent_close_notify():
                    return 0
                raise new_error(
                    ErrorKind.READ_ERROR,
                    String(
                        "the connection to ",
                        self._hostname,
                        (
                            " ended without a TLS close notify, so the response"
                            " may have been cut short by something other than"
                            " the server."
                        ),
                    ),
                )
            raise new_error(
                ErrorKind.READ_ERROR,
                String(
                    "TLS read from ", self._hostname, " failed: ", error_text()
                ),
            )

    def write[
        o: ImmOrigin
    ](mut self, data: Span[UInt8, o], deadline: Deadline) raises:
        """Write all of `data` as TLS records.

        `SSL_write` is all or nothing unless partial writes are turned on, and
        they are not, so a successful call has written everything it was given.
        The loop is still written against a byte count because a retry after a
        WANT has to present the same bytes at the same address, and a loop that
        tracks progress is the shape that keeps that true.
        """
        var sent = 0
        while sent < data.__len__():
            deadline.check(String("TLS write to ", self._hostname))
            clear_errors()
            var n = self._ssl.write(data[sent:])
            if n > 0:
                sent += Int(n)
                continue
            var code = self._ssl.last_error(n)
            if code == SSL_ERROR_WANT_READ:
                _ = self._tcp.wait_readable(deadline)
                continue
            if code == SSL_ERROR_WANT_WRITE:
                _ = self._tcp.wait_writable(deadline)
                continue
            raise new_error(
                ErrorKind.WRITE_ERROR,
                String(
                    "TLS write to ", self._hostname, " failed: ", error_text()
                ),
            )

    def has_data_waiting(self) raises -> Bool:
        """Whether a read right now would return something.

        Answered from the socket, not from OpenSSL, and that makes it
        approximate in one direction: bytes may be sitting in the socket buffer
        that turn out to be a record OpenSSL has nothing to hand back from, and
        OpenSSL may already hold decrypted bytes with the socket empty. Both
        callers are the pool deciding whether an idle connection is still good,
        where either answer means the same thing, which is that this connection
        is not idle and clean.
        """
        return self._tcp.has_data_waiting()

    def is_closed_by_peer(self) raises -> Bool:
        return self._tcp.is_closed_by_peer()

    def shutdown_write(mut self):
        """Send `close_notify`, then a FIN.

        Once, without waiting for the peer's answer. Waiting is only useful to
        an application that has to know its data was received before the
        session ended, and HTTP already knows that from the response.
        """
        if self._closed or not self._tcp.is_open():
            return
        try:
            _ = self._ssl.shutdown()
        except:
            # Failing to say goodbye politely does not stop us hanging up.
            pass
        self._tcp.shutdown_write()

    def close(mut self):
        """End the session and release the socket. Safe to call twice."""
        if not self._closed and self._tcp.is_open():
            try:
                _ = self._ssl.shutdown()
            except:
                pass
        self._closed = True
        self._tcp.close()
