"""OpenSSL, loaded at run time and wrapped just far enough to be safe.

Mojo has no TLS. What it does have is an OpenSSL 3.x that ships inside the
distribution, at `<env>/lib/libssl.3.dylib` on macOS and `libssl.so.3` on
Linux, along with a CA bundle at `<env>/ssl/cacert.pem`. So the common case
needs nothing installed, and this module is binding work rather than vendoring
work.

The library is opened with `dlopen` rather than linked, because linking would
make a Mojo program that never makes an HTTPS request fail to start on a
machine without OpenSSL, and because the version that gets loaded then becomes
a property of the build rather than of the machine. The search order is in
`_candidates` below and every path tried appears in the failure message, since
"TLS unavailable" with no detail is a miserable thing to debug.

Symbols are resolved per call rather than into a table. That costs about 235
nanoseconds a call, measured on this machine against a resolved callable at
about 1 nanosecond, and a request makes a few dozen calls, so the cost is
somewhere around ten microseconds per request against a network round trip. It
buys one place per symbol instead of three, which on a file that is nothing but
foreign declarations is worth more than the time. If a profile ever disagrees,
the resolution can be hoisted into a table without touching a single call site.

Two things about this file are load bearing.

The pointers are all `void *`. OpenSSL's types are opaque and their layouts
change between releases, so the only honest declaration for an `SSL *` is an
address, and the only place that address is ever dereferenced is inside
OpenSSL. What that costs is the compiler's help in telling an `SSL *` from an
`SSL_CTX *`, and what pays it back is `Ssl` and `SslCtx` below, which hold
those addresses privately and hand out methods rather than pointers.

An `SSL` outliving its `SSL_CTX` would be a use after free, and it cannot
happen here: `SSL_new` takes a reference on the context and `SSL_free` gives it
back, so a context stays alive for as long as any connection made from it. That
is OpenSSL's guarantee rather than ours, which is why it is written down.
"""

from std.ffi import (
    CStringSlice,
    OwnedDLHandle,
    _Global,
    c_char,
    c_int,
    c_long,
    c_uint,
)
from std.os import abort
from std.sys import CompilationTarget

from httpx._exceptions import ErrorKind, new_error
from httpx._ffi.c import CStr, Ptr, c_string, cstr_to_string, getenv
from httpx._ffi.socket import ignore_sigpipe_for_the_process

comptime MIN_VERSION_NUM = 0x30000000
"""OpenSSL 3.0.0, as `OPENSSL_VERSION_NUMBER` encodes it.

Older versions are refused rather than worked around. 1.1.1 went out of support
in September 2023, and the 3.0 API is what every declaration below is written
against, so accepting an older library would mean either dead compatibility
code or a handshake that fails somewhere less obvious than startup.
"""

comptime OPENSSL_PATH_ENV = "HTTPX_OPENSSL_PATH"
"""Where to load libssl from, when the search order below finds the wrong one.

Takes a full path to the library. Set it and nothing else is tried, so a
mistake here is an error rather than a silent fall through to some other copy.
"""

# The protocol version numbers, from `openssl/prov_ssl.h`. Two bytes, major
# then minor, and TLS 1.3 is 0x0304 rather than 0x0400 because the record layer
# still says 1.2 for compatibility with middleboxes.
comptime TLS1_2_VERSION = 0x0303
comptime TLS1_3_VERSION = 0x0304

# `SSL_CTX_ctrl` and `SSL_ctrl` command numbers, from `openssl/ssl.h`. These
# four are spelled as macros over ctrl in the headers rather than as functions,
# so there is no symbol to resolve and the number has to be written down.
comptime SSL_CTRL_SET_SESS_CACHE_MODE = 44
comptime SSL_CTRL_SET_TLSEXT_HOSTNAME = 55
comptime SSL_CTRL_SET_MIN_PROTO_VERSION = 123
comptime SSL_CTRL_SET_MAX_PROTO_VERSION = 124

comptime TLSEXT_NAMETYPE_host_name = 0
"""The SNI name type. There has only ever been one."""

comptime SSL_VERIFY_NONE = 0
comptime SSL_VERIFY_PEER = 1

comptime SSL_SESS_CACHE_OFF = 0x0000
comptime SSL_SESS_CACHE_CLIENT = 0x0001

comptime SSL_FILETYPE_PEM = 1

# `SSL_get_error` results. Only the ones this library acts on are named; the
# rest are server side or asynchronous engine states that a blocking client
# never sees, and lumping them together is what `_unexpected` is for.
comptime SSL_ERROR_NONE = 0
comptime SSL_ERROR_SSL = 1
comptime SSL_ERROR_WANT_READ = 2
comptime SSL_ERROR_WANT_WRITE = 3
comptime SSL_ERROR_SYSCALL = 5
comptime SSL_ERROR_ZERO_RETURN = 6

comptime SSL_RECEIVED_SHUTDOWN = 2
"""Set in `SSL_get_shutdown` once the peer's `close_notify` has been read."""

# `SSL_OP_*`, which are single bits of a 64 bit mask in OpenSSL 3.x.
comptime SSL_OP_NO_COMPRESSION = UInt64(1) << 17
comptime SSL_OP_NO_RENEGOTIATION = UInt64(1) << 30

comptime X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS = 0x4
"""Refuse `w*.example.com`, accept `*.example.com`.

RFC 6125 section 6.4.3 allows a wildcard as a whole label and nothing finer.
Partial wildcards are what let a certificate for `*.example.com` be stretched
into one that matches a name it was never issued for, and OpenSSL only refuses
them when asked.
"""

comptime X509_V_OK = 0
comptime X509_V_ERR_CERT_NOT_YET_VALID = 9
comptime X509_V_ERR_CERT_HAS_EXPIRED = 10
comptime X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT = 18
comptime X509_V_ERR_SELF_SIGNED_CERT_IN_CHAIN = 19
comptime X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY = 20
comptime X509_V_ERR_CERT_REVOKED = 23
comptime X509_V_ERR_HOSTNAME_MISMATCH = 62
comptime X509_V_ERR_IP_ADDRESS_MISMATCH = 64


def _library_names() -> List[String]:
    """The file names libssl goes by on this platform, best first."""
    var names = List[String]()
    if CompilationTarget.is_macos():
        names.append(String("libssl.3.dylib"))
        names.append(String("libssl.dylib"))
    else:
        names.append(String("libssl.so.3"))
        names.append(String("libssl.so"))
    return names^


def _directories() -> List[String]:
    """Where to look for libssl, in the order the answers get less certain.

    The Mojo environment comes first because that copy is the one this project
    is tested against and the one whose CA bundle the default trust store
    points at. Then the loader's own search path, spelled as a bare file name,
    which is what picks up a system OpenSSL on Linux. Homebrew comes last
    because a macOS system without the Mojo copy is unusual enough that being
    slow about it costs nothing.
    """
    var dirs = List[String]()
    try:
        var prefix = getenv("CONDA_PREFIX")
        if prefix and prefix.value() != "":
            dirs.append(String(prefix.value(), "/lib/"))
    except:
        # An environment we cannot read is an environment with nothing in it.
        pass
    dirs.append(String())
    if CompilationTarget.is_macos():
        dirs.append(String("/opt/homebrew/opt/openssl@3/lib/"))
        dirs.append(String("/usr/local/opt/openssl@3/lib/"))
    else:
        dirs.append(String("/usr/lib/"))
        dirs.append(String("/usr/lib/x86_64-linux-gnu/"))
        dirs.append(String("/usr/lib/aarch64-linux-gnu/"))
    return dirs^


def _candidates() -> List[String]:
    """Every path to try, in order, first one that opens wins."""
    var out = List[String]()
    try:
        var override = getenv(OPENSSL_PATH_ENV)
        if override and override.value() != "":
            out.append(override.value())
            return out^
    except:
        pass
    var dirs = _directories()
    var names = _library_names()
    for d in range(len(dirs)):
        for n in range(len(names)):
            out.append(String(dirs[d], names[n]))
    return out^


def _crypto_path(ssl_path: String) -> String:
    """The libcrypto that sits beside a given libssl.

    Derived from the name rather than searched for, because the two halves of
    OpenSSL have to be the same build. `dlopen` of libssl already pulled its
    own libcrypto in, so this is opening a library that is in the process
    either way; the handle exists because the error and certificate functions
    live on that side and asking for them through the libssl handle would rely
    on the loader searching dependencies, which is a detail that differs
    between platforms.
    """
    var at = ssl_path.rfind("libssl")
    if at < 0:
        return ssl_path.copy()
    return String(
        ssl_path[byte=0:at],
        "libcrypto",
        ssl_path[byte = at + 6 : ssl_path.byte_length()],
    )


struct _Loaded(Movable):
    """The two handles, or the reason there are none.

    Failure is recorded rather than raised because this is built inside a
    process global, which is initialized once by code that cannot raise. Every
    accessor checks `problem` first, so the diagnostic reaches the caller who
    asked for TLS rather than the caller who happened to run first.
    """

    var ssl: Optional[OwnedDLHandle]
    var crypto: Optional[OwnedDLHandle]
    var path: String
    var problem: String

    def __init__(out self):
        self.ssl = None
        self.crypto = None
        self.path = String()
        self.problem = String()
        var tried = String()
        var candidates = _candidates()
        for i in range(len(candidates)):
            ref candidate = candidates[i]
            try:
                var ssl = OwnedDLHandle(candidate)
                var crypto = OwnedDLHandle(_crypto_path(candidate))
                self.ssl = Optional(ssl^)
                self.crypto = Optional(crypto^)
                self.path = candidate.copy()
                self._check_version()
                # Here rather than anywhere else because this runs exactly once
                # and only for a program that is actually going to speak TLS.
                # `ignore_sigpipe_for_the_process` says why it has to happen at
                # all and what it refuses to do.
                _ = ignore_sigpipe_for_the_process()
                return
            except e:
                self.ssl = None
                self.crypto = None
                if tried != "":
                    tried += ", "
                tried += "'" + candidate + "'"
        self.problem = String(
            "no usable OpenSSL 3 was found, so https is not available. Tried ",
            tried,
            ". Set ",
            OPENSSL_PATH_ENV,
            " to the full path of libssl if it lives somewhere else.",
        )

    def _check_version(mut self) raises:
        """Refuse a library that is too old, before anything depends on it.

        An OpenSSL 1.1.1 exports most of the same names, so without this the
        first thing to go wrong would be a call whose signature changed, which
        surfaces as a crash rather than as a version complaint.
        """
        var version = self.ssl.value().get_function[UInt64](
            "OpenSSL_version_num"
        )()
        if version < MIN_VERSION_NUM:
            raise Error(
                String(
                    "OpenSSL at '",
                    self.path,
                    "' is version ",
                    hex(version),
                    ", and this client needs 3.0.0 or newer",
                )
            )


def _load() -> _Loaded:
    return _Loaded()


comptime _LOADED = _Global["httpx_openssl", _load]


def _libssl() raises -> ref[ImmStaticOrigin] OwnedDLHandle:
    """The libssl handle, opened on first use and kept for the process.

    One handle for the whole program, because unloading a TLS library while a
    connection made from it is still open would be a use after free, and there
    is no point at which a library can know that no such connection exists.
    """
    ref loaded = _LOADED.get_or_create_ptr()[]
    if loaded.problem != "":
        raise new_error(ErrorKind.UNSUPPORTED_PROTOCOL, loaded.problem)
    return loaded.ssl.value()


def _libcrypto() raises -> ref[ImmStaticOrigin] OwnedDLHandle:
    ref loaded = _LOADED.get_or_create_ptr()[]
    if loaded.problem != "":
        raise new_error(ErrorKind.UNSUPPORTED_PROTOCOL, loaded.problem)
    return loaded.crypto.value()


def library_path() raises -> String:
    """Which libssl got loaded, for diagnostics and for the CLI to print."""
    ref loaded = _LOADED.get_or_create_ptr()[]
    if loaded.problem != "":
        raise new_error(ErrorKind.UNSUPPORTED_PROTOCOL, loaded.problem)
    return loaded.path.copy()


def version_text() raises -> String:
    """`OpenSSL 3.6.0 ...`, straight from the library."""
    var f = _libssl().get_function[CStr]("OpenSSL_version")
    # 0 is OPENSSL_VERSION, the human readable string. The pointer is into
    # static storage that OpenSSL owns for the life of the process, and it is
    # copied here rather than held.
    return cstr_to_string(f(c_int(0)))


def is_available() -> Bool:
    """Whether https can work at all in this process.

    Used by tests and by the CLI. Everything else should just make the request
    and let the failure carry the explanation.
    """
    try:
        _ = _libssl()
        return True
    except:
        return False


def error_text() raises -> String:
    """Everything on OpenSSL's error queue, drained, oldest first.

    Drained rather than peeked at, because the queue is per thread and shared
    by every call: an error left on it turns up attached to some later
    operation that had nothing to do with it. Reading is the only way to clear
    it, so reading is not optional even when the text is not wanted.
    """
    var get_error = _libcrypto().get_function[UInt64]("ERR_get_error")
    var to_text = _libcrypto().get_function[NoneType]("ERR_error_string_n")
    var out = String()
    while True:
        var code = get_error()
        if code == 0:
            return out^
        var buf = List[UInt8](length=256, fill=0)
        # 256 bytes is what OpenSSL's own documentation says is enough, and the
        # call always writes a terminator inside the length it is given.
        to_text(code, Pointer(to=buf[0]), UInt64(256))
        # Cut at the terminator rather than handing the whole buffer over. The
        # tail is the zero fill, and a `CStringSlice` over a span holding those
        # is rejected for having an interior nul, which turns a description of
        # a TLS failure into a complaint about a nul byte.
        var end = 0
        while end < 256 and buf[end] != 0:
            end += 1
        if out != "":
            out += "; "
        out += String(StringSpan(unsafe_from_utf8=Span(buf)[:end]))


def clear_errors() raises:
    """Empty the error queue without reading it.

    Called before an operation whose result is judged by `SSL_get_error`, since
    that reads the queue and a stale entry from an earlier call would be
    attributed to this one.
    """
    _ = _libcrypto().get_function[NoneType]("ERR_clear_error")()


def verify_error_text(code: Int) raises -> String:
    """OpenSSL's own words for a certificate verification result.

    Its words rather than ours because there are over seventy of these and a
    table copied here would drift. The ones worth saying something extra about
    are handled by name in the TLS layer.
    """
    var f = _libcrypto().get_function[CStr]("X509_verify_cert_error_string")
    return cstr_to_string(f(c_long(code)))


struct SslCtx(Movable):
    """An `SSL_CTX`, which is the configuration every connection is cut from.

    One per client rather than one per connection. Building it parses the trust
    store, which for the default bundle is a hundred and fifty certificates,
    and doing that per request would be the most expensive thing in the client
    by a wide margin.
    """

    var _ptr: Ptr[NoneType]

    def __init__(out self) raises:
        """A client context with nothing configured on it yet.

        `TLS_client_method` is the version flexible client method. The minimum
        and maximum versions are set separately, by the TLS layer, because the
        method itself no longer carries them in OpenSSL 3.
        """
        var method = _libssl().get_function[Optional[Ptr[NoneType]]](
            "TLS_client_method"
        )()
        if not method:
            raise new_error(
                ErrorKind.UNSUPPORTED_PROTOCOL,
                String("OpenSSL has no TLS client method: ", error_text()),
            )
        var ctx = _libssl().get_function[Optional[Ptr[NoneType]]](
            "SSL_CTX_new"
        )(method.value())
        if not ctx:
            raise new_error(
                ErrorKind.UNSUPPORTED_PROTOCOL,
                String("could not create a TLS context: ", error_text()),
            )
        self._ptr = ctx.value()

    def __deinit__(deinit self):
        try:
            # `SSL_CTX_free` decrements a reference count, so this only frees
            # the context once the last connection made from it has gone.
            _ = _libssl().get_function[NoneType]("SSL_CTX_free")(self._ptr)
        except:
            # Unreachable: the handle that produced this pointer is still open,
            # because it is never closed. A destructor cannot raise anyway.
            pass

    def ptr(self) -> Ptr[NoneType]:
        """The raw `SSL_CTX *`, for `SSL_new` and nothing else.

        Reading it does not transfer ownership, and the only caller is `Ssl`
        below, in this same module.
        """
        return self._ptr

    def set_min_version(self, version: Int) raises:
        """The lowest protocol version to accept. Spelled through ctrl."""
        self._ctrl(SSL_CTRL_SET_MIN_PROTO_VERSION, version, "minimum version")

    def set_max_version(self, version: Int) raises:
        self._ctrl(SSL_CTRL_SET_MAX_PROTO_VERSION, version, "maximum version")

    def set_session_cache(self, mode: Int) raises:
        """Turn the session cache on or off.

        Unchecked, unlike the version setters, because this one returns the
        mode that was in effect before rather than a success flag. Zero, which
        is the value everything else in this file treats as failure, is what a
        context that already had caching off returns on success.
        """
        _ = self._ctrl_raw(SSL_CTRL_SET_SESS_CACHE_MODE, mode)

    def set_options(self, options: UInt64) raises:
        """Turn on protocol options. The mask is cumulative, never replaced."""
        var f = _libssl().get_function[UInt64]("SSL_CTX_set_options")
        _ = f(self._ptr, options)

    def set_verify(self, mode: Int) raises:
        """Whether to check the peer's certificate at all.

        No callback. A verification callback exists to override OpenSSL's
        verdict, and a client that overrides it is a client whose users cannot
        tell whether verification happened.
        """
        var f = _libssl().get_function[NoneType]("SSL_CTX_set_verify")
        var no_callback: Optional[Ptr[NoneType]] = None
        _ = f(self._ptr, c_int(mode), no_callback)

    def set_cipher_list(self, ciphers: StringSpan) raises:
        """The TLS 1.2 and below cipher list. Has no effect on TLS 1.3."""
        var text = c_string(ciphers)
        var f = _libssl().get_function[c_int]("SSL_CTX_set_cipher_list")
        if f(self._ptr, CStringSlice(text)) != 1:
            raise new_error(
                ErrorKind.CONNECT_ERROR,
                String(
                    "OpenSSL rejected the cipher list '",
                    ciphers,
                    "': ",
                    error_text(),
                ),
            )

    def load_verify_locations(
        self, file: Optional[String], directory: Optional[String]
    ) raises:
        """Add a CA bundle file, a hashed CA directory, or both.

        Adds rather than replaces: OpenSSL accumulates trust anchors, so
        calling this twice trusts both sets. Every caller here builds a fresh
        context, so that is a property to know about rather than to rely on.
        """
        var file_text = c_string(file.value()) if file else String()
        var dir_text = c_string(directory.value()) if directory else String()
        var no_file: Optional[Ptr[c_char]] = None
        var no_dir: Optional[Ptr[c_char]] = None
        var f = _libssl().get_function[c_int]("SSL_CTX_load_verify_locations")
        var rc: c_int
        if file and directory:
            rc = f(self._ptr, CStringSlice(file_text), CStringSlice(dir_text))
        elif file:
            rc = f(self._ptr, CStringSlice(file_text), no_dir)
        elif directory:
            rc = f(self._ptr, no_file, CStringSlice(dir_text))
        else:
            return
        if rc != 1:
            var what = file.value() if file else directory.value()
            raise new_error(
                ErrorKind.CONNECT_ERROR,
                String(
                    "could not load the certificates at '",
                    what,
                    "': ",
                    error_text(),
                    ". Check the path exists and is a PEM bundle.",
                ),
            )

    def set_default_verify_paths(self) raises -> Bool:
        """Add whatever OpenSSL was compiled to trust.

        Returns whether it worked rather than raising, because this is one of
        several sources of trust anchors and having none of them is the error,
        not having one of them fail.
        """
        var f = _libssl().get_function[c_int](
            "SSL_CTX_set_default_verify_paths"
        )
        return f(self._ptr) == 1

    def use_client_certificate(
        self,
        certfile: String,
        keyfile: String,
        password: Optional[String],
    ) raises:
        """Present a client certificate when the server asks for one.

        The password goes in as the default callback's user data rather than
        through a callback of our own. OpenSSL's built in `PEM_def_callback`
        reads exactly that string when no callback is set, which avoids handing
        a Mojo function to C as a C function pointer for the sake of copying a
        few bytes.

        The user data is set even when there is no password, to an empty
        string. That is not a formality. With nothing set, `PEM_def_callback`
        falls back to prompting on the terminal, so a program with an encrypted
        key and no password stops dead waiting for somebody to type, and a
        program with no terminal gets thirteen lines of OpenSSL errors about
        `ttyget` instead of being told its key needs a password. A library must
        never do either.

        The password string has to outlive the key file load, and it does: it
        is a local here and every call that can read it happens before this
        function returns.
        """
        var pass_text = c_string(password.value()) if password else String("\0")
        var set_data = _libssl().get_function[NoneType](
            "SSL_CTX_set_default_passwd_cb_userdata"
        )
        _ = set_data(self._ptr, CStringSlice(pass_text))

        var cert_text = c_string(certfile)
        var use_cert = _libssl().get_function[c_int](
            "SSL_CTX_use_certificate_chain_file"
        )
        if use_cert(self._ptr, CStringSlice(cert_text)) != 1:
            raise new_error(
                ErrorKind.CONNECT_ERROR,
                String(
                    "could not load the client certificate at '",
                    certfile,
                    "': ",
                    error_text(),
                ),
            )

        var key_text = c_string(keyfile)
        var use_key = _libssl().get_function[c_int](
            "SSL_CTX_use_PrivateKey_file"
        )
        # `key_text` stays alive across the call below, and this is where the
        # password callback runs if the key is encrypted.
        if (
            use_key(self._ptr, CStringSlice(key_text), c_int(SSL_FILETYPE_PEM))
            != 1
        ):
            # The password hint goes on only when nothing better is known. A
            # key that belongs to another certificate fails here too, OpenSSL
            # says so in as many words, and telling that reader to go and find
            # a password would send them the wrong way entirely.
            var reason = error_text()
            var hint = String()
            if not password and "mismatch" not in reason:
                hint = String(
                    " An encrypted key needs its password passing too."
                )
            raise new_error(
                ErrorKind.CONNECT_ERROR,
                String(
                    "could not load the client key at '",
                    keyfile,
                    "': ",
                    reason,
                    ".",
                    hint,
                ),
            )

        var check = _libssl().get_function[c_int]("SSL_CTX_check_private_key")
        if check(self._ptr) != 1:
            raise new_error(
                ErrorKind.CONNECT_ERROR,
                String(
                    "the client key at '",
                    keyfile,
                    "' does not match the certificate at '",
                    certfile,
                    "'",
                ),
            )

    def set_alpn_protocols[o: ImmOrigin](self, wire: Span[UInt8, o]) raises:
        """Offer this ALPN list, already in its length prefixed wire form.

        Returns zero on success, which is the opposite of every other function
        in this file and is worth reading twice rather than pattern matching.
        """
        if wire.__len__() == 0:
            return
        var f = _libssl().get_function[c_int]("SSL_CTX_set_alpn_protos")
        if f(self._ptr, Pointer(to=wire[0]), c_uint(wire.__len__())) != 0:
            raise new_error(
                ErrorKind.CONNECT_ERROR,
                String("OpenSSL rejected the ALPN list: ", error_text()),
            )

    def _ctrl_raw(self, command: Int, value: Int) raises -> c_long:
        """One `SSL_CTX_ctrl` call, result handed back unjudged.

        The headers spell several setters as macros over this, so there is no
        symbol to resolve for them and the command number is the API. What the
        result means is per command, which is why judging it is the caller's
        job.
        """
        var f = _libssl().get_function[c_long]("SSL_CTX_ctrl")
        var no_arg: Optional[Ptr[NoneType]] = None
        return f(self._ptr, c_int(command), c_long(value), no_arg)

    def _ctrl(self, command: Int, value: Int, what: String) raises:
        """The same, for the commands that report success as 1."""
        var f = _libssl().get_function[c_long]("SSL_CTX_ctrl")
        var no_arg: Optional[Ptr[NoneType]] = None
        if f(self._ptr, c_int(command), c_long(value), no_arg) != 1:
            raise new_error(
                ErrorKind.CONNECT_ERROR,
                String(
                    "OpenSSL would not accept the ",
                    what,
                    ": ",
                    error_text(),
                ),
            )


struct Ssl(Movable):
    """One `SSL`, which is one connection's worth of TLS state.

    Created from a context, tied to a file descriptor it does not own, and
    freed here. The descriptor stays with the `TcpStream` it came from, so this
    never closes it: two owners of one descriptor is how a socket gets closed
    twice and the number handed to somebody else in between.
    """

    var _ptr: Ptr[NoneType]

    def __init__(out self, ctx: SslCtx) raises:
        """A new connection state from `ctx`.

        `SSL_new` takes a reference on the context, so this object keeps its
        context alive by itself and the two lifetimes do not have to be
        ordered by hand.
        """
        var made = _libssl().get_function[Optional[Ptr[NoneType]]]("SSL_new")(
            ctx.ptr()
        )
        if not made:
            raise new_error(
                ErrorKind.CONNECT_ERROR,
                String("could not start a TLS connection: ", error_text()),
            )
        self._ptr = made.value()

    def __deinit__(deinit self):
        try:
            # Frees the connection state and drops the reference `SSL_new` took
            # on the context. Does not touch the file descriptor.
            _ = _libssl().get_function[NoneType]("SSL_free")(self._ptr)
        except:
            pass

    def set_fd(self, fd: c_int) raises:
        """Point this connection at an already connected socket.

        Borrowed, not owned. OpenSSL will read and write it and will not close
        it, which is what lets the socket layer keep being the only owner.
        """
        var f = _libssl().get_function[c_int]("SSL_set_fd")
        if f(self._ptr, fd) != 1:
            raise new_error(
                ErrorKind.CONNECT_ERROR,
                String("OpenSSL would not take the socket: ", error_text()),
            )

    def set_sni_hostname(self, hostname: StringSpan) raises:
        """Send this name in the SNI extension.

        Failure here is not fatal on its own, but it is always a sign that
        something is wrong with the name, so it is reported rather than
        swallowed. RFC 6066 forbids a literal address in SNI, and refusing to
        send one is the caller's job rather than this one's.
        """
        var text = c_string(hostname)
        var f = _libssl().get_function[c_long]("SSL_ctrl")
        var rc = f(
            self._ptr,
            c_int(SSL_CTRL_SET_TLSEXT_HOSTNAME),
            c_long(TLSEXT_NAMETYPE_host_name),
            CStringSlice(text),
        )
        if rc != 1:
            raise new_error(
                ErrorKind.CONNECT_ERROR,
                String(
                    "OpenSSL would not send '",
                    hostname,
                    "' as the server name: ",
                    error_text(),
                ),
            )

    def set_verify_hostname(self, hostname: StringSpan) raises:
        """Check the certificate against this name during the handshake.

        Through `SSL_set1_host` rather than by parsing the certificate here.
        Wildcard rules, subject alternative name against common name
        precedence, and address SANs are each a place clients have historically
        gone wrong, and OpenSSL has already got them right.
        """
        var text = c_string(hostname)
        var set_flags = _libssl().get_function[NoneType]("SSL_set_hostflags")
        _ = set_flags(self._ptr, c_uint(X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS))
        var f = _libssl().get_function[c_int]("SSL_set1_host")
        if f(self._ptr, CStringSlice(text)) != 1:
            raise new_error(
                ErrorKind.CONNECT_ERROR,
                String(
                    "OpenSSL would not verify against '",
                    hostname,
                    "': ",
                    error_text(),
                ),
            )

    def connect(self) raises -> c_int:
        """One handshake step. 1 is done, anything else asks `last_error`."""
        return _libssl().get_function[c_int]("SSL_connect")(self._ptr)

    def read[o: MutOrigin](self, buf: Span[UInt8, o]) raises -> c_int:
        """One `SSL_read`. Zero or less means ask `last_error` what happened.

        The span is contiguous and non empty by the check below, so `count`
        bytes from the address of its first element stay inside it.
        """
        if buf.__len__() == 0:
            return c_int(0)
        var f = _libssl().get_function[c_int]("SSL_read")
        return f(self._ptr, Pointer(to=buf[0]), c_int(buf.__len__()))

    def write[o: ImmOrigin](self, data: Span[UInt8, o]) raises -> c_int:
        """One `SSL_write`. Same contiguity argument as `read`."""
        if data.__len__() == 0:
            return c_int(0)
        var f = _libssl().get_function[c_int]("SSL_write")
        return f(self._ptr, Pointer(to=data[0]), c_int(data.__len__()))

    def shutdown(self) raises -> c_int:
        """Send `close_notify`. 0 means sent, 1 means the peer's arrived too."""
        return _libssl().get_function[c_int]("SSL_shutdown")(self._ptr)

    def last_error(self, result: c_int) raises -> Int:
        """What `result` meant, as one of the `SSL_ERROR_*` values.

        Takes the result rather than reading it from the connection because
        OpenSSL's answer depends on both, and a call that has already been
        followed by another call cannot be asked about any more.
        """
        var f = _libssl().get_function[c_int]("SSL_get_error")
        return Int(f(self._ptr, result))

    def verify_result(self) raises -> Int:
        """The verification verdict, `X509_V_OK` or a reason it is not.

        Worth asking even after a handshake that succeeded. With
        `SSL_VERIFY_PEER` set OpenSSL fails the handshake itself, but with
        verification off it does not, and this is what says so.
        """
        var f = _libssl().get_function[c_long]("SSL_get_verify_result")
        return Int(f(self._ptr))

    def alpn_protocol(self) raises -> String:
        """What the server picked, or empty when it ignored ALPN.

        `SSL_get0_alpn_selected` writes a pointer into OpenSSL's own memory and
        a length; the bytes are copied out here rather than held, because they
        live only as long as the connection does. The out parameters are a null
        pointer and a zero until it writes them, which is the case a server
        that said nothing leaves behind.
        """
        var data: Optional[Ptr[UInt8]] = None
        var length = c_uint(0)
        var f = _libssl().get_function[NoneType]("SSL_get0_alpn_selected")
        _ = f(self._ptr, Pointer(to=data), Pointer(to=length))
        if not data or length == 0:
            return String()
        var span = Span[UInt8, MutUntrackedOrigin](
            unsafe_ptr=data.value(), length=Int(length)
        )
        return String(StringSpan(from_utf8=span))

    def protocol_version(self) raises -> String:
        """`TLSv1.3` and friends, straight from OpenSSL's own table."""
        var f = _libssl().get_function[CStr]("SSL_get_version")
        return cstr_to_string(f(self._ptr))

    def cipher_name(self) raises -> String:
        """The negotiated cipher suite, or empty before the handshake."""
        var current = _libssl().get_function[Optional[Ptr[NoneType]]](
            "SSL_get_current_cipher"
        )(self._ptr)
        if not current:
            return String()
        var f = _libssl().get_function[CStr]("SSL_CIPHER_get_name")
        return cstr_to_string(f(current.value()))

    def peer_sent_close_notify(self) raises -> Bool:
        """Whether the peer said it was finished, rather than just going quiet.

        This is what tells a clean end of stream from a truncation. An attacker
        who can cut the connection can always stop the bytes; what they cannot
        do is forge the `close_notify` that says the sender meant to stop.
        """
        var f = _libssl().get_function[c_int]("SSL_get_shutdown")
        return (Int(f(self._ptr)) & SSL_RECEIVED_SHUTDOWN) != 0
