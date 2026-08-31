"""What a client has decided about TLS, and the context it turns into.

Two things live here. `SSLVerify` and `ClientCert` are the settings a caller
gives, and `TlsConfig` is the whole set of them plus the one function that
turns them into an OpenSSL context.

The split matters because building a context is expensive and configuring one
is not. Parsing the default trust store means reading about a hundred and fifty
certificates off disk, so it happens once per client and the resulting context
is shared by every connection that client makes. That is safe: OpenSSL contexts
are read mostly once configured, and the per connection state lives in the
`SSL` object rather than here.

The defaults are the ones a client should have to be argued out of rather than
into. Verification on, hostname checked, TLS 1.2 at the lowest, no compression,
no renegotiation, and no session cache.
"""

from httpx._exceptions import ErrorKind, new_error
from httpx._ffi.c import getenv
from httpx._ffi.openssl import (
    SSL_OP_NO_COMPRESSION,
    SSL_OP_NO_RENEGOTIATION,
    SSL_SESS_CACHE_OFF,
    SSL_VERIFY_NONE,
    SSL_VERIFY_PEER,
    SslCtx,
    TLS1_2_VERSION,
    TLS1_3_VERSION,
)
from std.sys import CompilationTarget


struct SSLVerify(ImplicitlyCopyable, Movable):
    """Whether to check the server's certificate, and against which anchors.

    Four cases, matching what `verify=` takes in httpx: on with the system
    trust store, off entirely, on with a bundle file, and on with a directory
    of hashed certificates. They are constructors here rather than a union type
    because Mojo has no untagged unions and because the field layout is the
    same in all four.

    `off` deserves its own sentence. It disables hostname checking as well as
    chain checking, because a hostname check against an unverified chain is
    theatre: an attacker who can present any certificate can present one with
    the right name on it. There is no configuration in which one is on and the
    other is off.
    """

    var enabled: Bool
    var ca_file: Optional[String]
    var ca_path: Optional[String]

    def __init__(out self):
        """Verify, using whatever this machine trusts. The default."""
        self.enabled = True
        self.ca_file = None
        self.ca_path = None

    @staticmethod
    def off() -> Self:
        """Do not verify anything.

        For a development server with a self signed certificate, and for
        nothing else. A client with this set will talk to anybody who answers
        on the address, which on any network the client does not own means
        talking to whoever got there first.
        """
        var out = Self()
        out.enabled = False
        return out^

    @staticmethod
    def from_file(path: String) -> Self:
        """Verify against one PEM bundle instead of the system store."""
        var out = Self()
        out.ca_file = Optional(path.copy())
        return out^

    @staticmethod
    def from_directory(path: String) -> Self:
        """Verify against a directory of certificates hashed OpenSSL style.

        The names in it have to be subject hashes, which is what `c_rehash`
        produces. A directory of ordinary `.pem` files will load without
        complaint and then verify nothing, because OpenSSL looks up an issuer
        by hashed file name and will not find one.
        """
        var out = Self()
        out.ca_path = Optional(path.copy())
        return out^

    def is_custom(self) -> Bool:
        """Whether the caller named the anchors rather than taking the default.
        """
        return self.ca_file.__bool__() or self.ca_path.__bool__()


struct ClientCert(ImplicitlyCopyable, Movable):
    """A certificate and key to present when the server asks for one.

    `keyfile` may be the same path as `certfile`, which is how a combined PEM
    holding both is spelled and is what most tools produce.

    The password is held in plain memory for as long as the config is alive.
    There is nowhere better for it to be: OpenSSL needs the bytes to decrypt
    the key, and a Mojo `String` is not page locked or wiped on free. A
    deployment that cares should use an unencrypted key with file permissions
    doing the work, which is what the password would be protecting anyway.
    """

    var certfile: String
    var keyfile: String
    var password: Optional[String]

    def __init__(
        out self,
        certfile: String,
        keyfile: String = String(),
        password: Optional[String] = None,
    ):
        self.certfile = certfile.copy()
        self.keyfile = keyfile.copy() if keyfile != "" else certfile.copy()
        self.password = password.copy()


def _env_bundle_paths() -> List[String]:
    """The CA bundle that ships beside the Mojo toolchain, if there is one.

    Mojo's distribution is a conda environment and conda environments carry a
    `ssl/cacert.pem` from the `ca-certificates` package. Using it means the
    common case needs nothing installed and gets the same trust anchors that
    every other tool in the environment uses.
    """
    var out = List[String]()
    try:
        var prefix = getenv("CONDA_PREFIX")
        if prefix and prefix.value() != "":
            out.append(String(prefix.value(), "/ssl/cacert.pem"))
    except:
        pass
    return out^


def _system_bundle_paths() -> List[String]:
    """Where the distributions put their trust stores, most common first.

    Only consulted when OpenSSL's own compiled in paths came up empty, which
    happens when the loaded library was built for a different prefix than the
    one it ended up installed under. That is the normal state of a relocatable
    conda build, so this list is not the exotic case it looks like.
    """
    var out = List[String]()
    if CompilationTarget.is_macos():
        out.append(String("/etc/ssl/cert.pem"))
        out.append(String("/opt/homebrew/etc/openssl@3/cert.pem"))
        out.append(String("/usr/local/etc/openssl@3/cert.pem"))
    else:
        out.append(String("/etc/ssl/certs/ca-certificates.crt"))
        out.append(String("/etc/pki/tls/certs/ca-bundle.crt"))
        out.append(String("/etc/ssl/ca-bundle.pem"))
        out.append(String("/etc/ssl/cert.pem"))
    return out^


def alpn_wire(http2: Bool) -> List[UInt8]:
    """The ALPN offer, in the length prefixed form OpenSSL wants.

    Each entry is one length byte then that many bytes of name, with no
    separator and no terminator. `h2` first when HTTP/2 is allowed, because
    ALPN gives the server the list in preference order and a server that
    supports both should pick the better one.
    """
    var out = List[UInt8]()
    if http2:
        out.append(2)
        out.extend("h2".as_bytes())
    out.append(8)
    out.extend("http/1.1".as_bytes())
    return out^


struct TlsConfig(ImplicitlyCopyable, Movable):
    """Everything a client decided about TLS, before any connection exists.

    Copyable and cheap, so a client can hold one and hand copies to the pool
    and the transport without either of them owning the other's settings. The
    expensive thing, the context, is built once by `build` and shared.
    """

    var verify: SSLVerify
    var cert: Optional[ClientCert]
    var trust_env: Bool
    var http2: Bool
    var min_version: Int
    var max_version: Int

    def __init__(out self):
        self.verify = SSLVerify()
        self.cert = None
        self.trust_env = True
        self.http2 = False
        self.min_version = TLS1_2_VERSION
        self.max_version = TLS1_3_VERSION

    def build(self) raises -> SslCtx:
        """One configured `SSL_CTX`, ready for connections to be cut from it.

        Everything that can fail does so here rather than mid handshake, so a
        bad CA path or a mismatched key pair is reported when the client is
        built and names the file, instead of turning up later attached to a
        request that had nothing to do with it.
        """
        var ctx = SslCtx()
        ctx.set_min_version(self.min_version)
        ctx.set_max_version(self.max_version)

        # No compression, because CRIME recovered secrets from the length of a
        # compressed record that mixed attacker text with a cookie. No
        # renegotiation, because a client has no reason to want one and
        # accepting them has been an attack surface twice. No session cache,
        # because sessions are not shared between connections yet and a cache
        # nobody reads is only somewhere for secrets to sit.
        ctx.set_options(SSL_OP_NO_COMPRESSION | SSL_OP_NO_RENEGOTIATION)
        ctx.set_session_cache(SSL_SESS_CACHE_OFF)

        ctx.set_alpn_protocols(Span(alpn_wire(self.http2)))

        if self.verify.enabled:
            ctx.set_verify(SSL_VERIFY_PEER)
            self._load_trust(ctx)
        else:
            ctx.set_verify(SSL_VERIFY_NONE)

        if self.cert:
            ref cert = self.cert.value()
            ctx.use_client_certificate(
                cert.certfile, cert.keyfile, cert.password
            )
        return ctx^

    def _load_trust(self, ctx: SslCtx) raises:
        """Give the context something to verify against, or say why it cannot.

        The order is from most specific to least: what the caller named, then
        what the environment names, then the bundle beside the toolchain, then
        whatever OpenSSL was built to look at, then the usual system paths.
        Each step is tried only if the ones before it produced nothing, so a
        caller who names a bundle gets that bundle and not that bundle plus the
        system store.

        Running out of steps is an error. A verifying context with no anchors
        rejects every certificate on earth, and the failure it produces says
        the server's certificate is untrusted, which sends whoever is reading
        it to look at the server.
        """
        if self.verify.is_custom():
            ctx.load_verify_locations(self.verify.ca_file, self.verify.ca_path)
            return

        if self.trust_env:
            var file = getenv("SSL_CERT_FILE")
            var directory = getenv("SSL_CERT_DIR")
            var has_file = file and file.value() != ""
            var has_dir = directory and directory.value() != ""
            if has_file or has_dir:
                ctx.load_verify_locations(
                    file if has_file else None,
                    directory if has_dir else None,
                )
                return

        var beside = _env_bundle_paths()
        for i in range(len(beside)):
            try:
                ctx.load_verify_locations(Optional(beside[i].copy()), None)
                return
            except:
                # Not there, or not readable. The next source gets a turn, and
                # if none of them work the message at the end lists them all.
                pass

        if ctx.set_default_verify_paths():
            return

        var system = _system_bundle_paths()
        for i in range(len(system)):
            try:
                ctx.load_verify_locations(Optional(system[i].copy()), None)
                return
            except:
                pass

        raise new_error(
            ErrorKind.CONNECT_ERROR,
            String(
                "no CA certificates were found, so no server certificate can"
                " be verified. Set SSL_CERT_FILE to a PEM bundle, or pass"
                " verify with an explicit path."
            ),
        )
