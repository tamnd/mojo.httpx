"""Authentication, as a state machine over a request and what came back.

httpx writes an auth scheme as a generator. It yields a request, the client
sends it, the response is fed back in, and the generator either yields another
request or stops. That is exactly the right shape, and Mojo 1.0 has no
generators, so it is written here as the two halves the generator would have
been: `sign` produces the request to send first, and `next_request` is handed
the response and either produces another request or nothing.

Nothing here sends anything. That is what makes a scheme testable without a
server, and it is also what keeps the retry policy in one place: the client
loops, the scheme decides.

Two schemes need two round trips and one does not. Basic puts the credential on
the first request and never looks at the answer, which is why it leaks the
password to anything on the path and why it is only safe over TLS. Digest waits
to be challenged, so the first request goes out unauthenticated and the
password never goes out at all. Both are here because servers still ask for
both.
"""

from httpx._bytes import starts_with, to_lower, trim_ows
from httpx._exceptions import ErrorKind, new_error
from httpx._ffi.c import getenv, random_bytes
from httpx._ffi.clock import unix_now
from httpx._io.files import home_file, read_text
from httpx._models.cookies import CookieJar
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._util.base64 import base64_encode
from httpx._util.digest import Algorithm, hex, hex_digest, sha1
from httpx._util.erase import ErasedBox


trait Auth(Movable):
    """A scheme that can put credentials on a request.

    Two methods because there are two moments: before anything has been sent,
    and after a response has come back. A scheme that only needs the first, like
    Basic, answers the second with nothing and costs one round trip.
    """

    def sign(mut self, var request: Request) raises -> Request:
        """The request as it should first go out."""
        ...

    def next_request(mut self, response: Response) raises -> Optional[Request]:
        """Another request to send, or nothing when the flow is finished.

        The response is borrowed and carries the request that produced it, so a
        scheme that needs to retry builds the new request from that rather than
        being handed a second copy of one it already saw.
        """
        ...

    def requires_response_body(self) -> Bool:
        """Whether `next_request` needs the body to have been read.

        False for everything here, since a challenge lives in the headers. A
        scheme that reads a signed nonce out of an error document would say
        True and the client would read the body before asking.
        """
        ...


struct AnyAuth(Movable):
    """An auth scheme whose type has been forgotten, ready to be stored.

    The same trick as `AnyTransport` and for the same reason: Mojo 1.0 has no
    trait objects, a field has one type, and a client has to be able to hold
    whichever scheme the caller picked.
    """

    var _state: ErasedBox
    var _sign: def(ErasedBox, var Request) raises thin -> Request
    var _next_request: def(ErasedBox, Response) raises thin -> Optional[Request]
    var _requires_response_body: def(ErasedBox) thin -> Bool

    def __init__(
        out self,
        var state: ErasedBox,
        sign: def(ErasedBox, var Request) raises thin -> Request,
        next_request: def(ErasedBox, Response) raises thin -> Optional[Request],
        requires_response_body: def(ErasedBox) thin -> Bool,
    ):
        self._state = state^
        self._sign = sign
        self._next_request = next_request
        self._requires_response_body = requires_response_body

    def copy(self) -> Self:
        """Another handle on the same scheme, sharing its state.

        Sharing rather than duplicating, because a digest scheme remembers the
        challenge it was given and a copy that forgot it would pay an extra
        round trip on every request.
        """
        return Self(
            self._state.copy(),
            self._sign,
            self._next_request,
            self._requires_response_body,
        )

    def sign(mut self, var request: Request) raises -> Request:
        return self._sign(self._state, request^)

    def next_request(mut self, response: Response) raises -> Optional[Request]:
        return self._next_request(self._state, response)

    def requires_response_body(self) -> Bool:
        return self._requires_response_body(self._state)


def erase_auth[T: Auth & Deinitable](var auth: T) -> AnyAuth:
    """Box `auth` and build the vtable that reaches back into it."""

    def _sign(state: ErasedBox, var request: Request) raises -> Request:
        return state.get[T]().sign(request^)

    def _next_request(
        state: ErasedBox, response: Response
    ) raises -> Optional[Request]:
        return state.get[T]().next_request(response)

    def _requires_response_body(state: ErasedBox) -> Bool:
        return state.get[T]().requires_response_body()

    return AnyAuth(
        ErasedBox.make[T](auth^),
        _sign,
        _next_request,
        _requires_response_body,
    )


def _basic_header(username: StringSpan, password: StringSpan) -> String:
    """`Basic` plus the base64 of `user:password`.

    The credential is bytes and not text. A password that is not ASCII has no
    encoding agreed anywhere in the specification, so what goes out is whatever
    bytes the caller handed over, which is what every other client does.
    """
    var joined = List[UInt8]()
    joined.extend(username.as_bytes())
    joined.append(UInt8(ord(":")))
    joined.extend(password.as_bytes())
    return String("Basic ", base64_encode(Span(joined)))


struct BasicAuth(Auth, Movable):
    """RFC 7617. The password, base64 of it, on every request.

    Base64 is not encryption and this is not a secure scheme over a plain
    connection. It is here because it is what a great many servers ask for, and
    because httpx has it.
    """

    var _header: String

    def __init__(out self, username: StringSpan, password: StringSpan):
        self._header = _basic_header(username, password)

    def sign(mut self, var request: Request) raises -> Request:
        request.headers["Authorization"] = self._header
        return request^

    def next_request(mut self, response: Response) raises -> Optional[Request]:
        """Nothing, always. Basic does not wait to be asked."""
        return None

    def requires_response_body(self) -> Bool:
        return False


struct _NetrcEntry(Movable):
    var machine: String
    var login: String
    var password: String

    def __init__(
        out self, var machine: String, var login: String, var password: String
    ):
        self.machine = machine^
        self.login = login^
        self.password = password^

    def copy(self) -> Self:
        return Self(
            String(self.machine), String(self.login), String(self.password)
        )


def parse_netrc(text: StringSpan) raises -> List[_NetrcEntry]:
    """The entries in a `.netrc`, in the order they were written.

    The format is a flat stream of words, not a line oriented one, so a machine
    and its login can be on one line or on five and both are correct. That is
    why this tokenizes first and looks at structure second.

    `macdef` is recognised only so that its body can be skipped. It defines an
    FTP macro, nothing in an HTTP client will ever run one, and a parser that
    did not know to skip it would read the macro body as more credentials.
    """
    var words = _netrc_words(text)
    var out = List[_NetrcEntry]()

    var machine = String()
    var login = String()
    var password = String()
    var have = False

    var at = 0
    while at < len(words):
        var word = words[at]
        if word == "machine" or word == "default":
            if have:
                out.append(_NetrcEntry(machine^, login^, password^))
            machine = String()
            login = String()
            password = String()
            have = True
            if word == "machine":
                at += 1
                if at < len(words):
                    machine = String(words[at])
            # `default` keeps an empty machine name, which is how the lookup
            # recognises the catch all entry without a second field for it.
            at += 1
            continue

        if word == "macdef":
            # Skip the name and then the body, which runs to the marker the
            # tokenizer left where a blank line was.
            at += 2
            while at < len(words) and words[at] != "\n":
                at += 1
            at += 1
            continue

        if word == "login" or word == "user":
            at += 1
            if at < len(words):
                login = String(words[at])
            at += 1
            continue

        if word == "password":
            at += 1
            if at < len(words):
                password = String(words[at])
            at += 1
            continue

        # `account` and anything else unrecognised takes its argument with it,
        # so an unknown keyword cannot make the next value look like a keyword.
        at += 2

    if have:
        out.append(_NetrcEntry(machine^, login^, password^))
    return out^


def _netrc_words(text: StringSpan) raises -> List[String]:
    """The file as words, with a blank line marked and quotes honoured.

    A blank line comes back as a word of its own because it is the only thing
    that ends a `macdef` body. Everything else is whitespace separated, except
    that a double quoted run is one word, which is how a password with a space
    in it is written.
    """
    var out = List[String]()
    var bytes = text.as_bytes()
    var at = 0
    var newlines = 0

    while at < len(bytes):
        var byte = bytes[at]
        if byte == UInt8(ord("\n")):
            newlines += 1
            if newlines == 2:
                out.append(String("\n"))
                newlines = 0
            at += 1
            continue
        if (
            byte == UInt8(ord(" "))
            or byte == UInt8(ord("\t"))
            or byte == UInt8(ord("\r"))
        ):
            at += 1
            continue

        newlines = 0
        if byte == UInt8(ord("#")):
            while at < len(bytes) and bytes[at] != UInt8(ord("\n")):
                at += 1
            continue

        var word = List[UInt8]()
        if byte == UInt8(ord('"')):
            at += 1
            while at < len(bytes) and bytes[at] != UInt8(ord('"')):
                if bytes[at] == UInt8(ord("\\")) and at + 1 < len(bytes):
                    at += 1
                word.append(bytes[at])
                at += 1
            at += 1
        else:
            while at < len(bytes) and not _is_space(bytes[at]):
                word.append(bytes[at])
                at += 1
        # Not validated as UTF-8. A `.netrc` password is bytes, and a file
        # written in some other encoding should still authenticate rather than
        # make the whole file unreadable.
        out.append(String(StringSpan(unsafe_from_utf8=Span(word))))

    return out^


def _is_space(byte: UInt8) -> Bool:
    return (
        byte == UInt8(ord(" "))
        or byte == UInt8(ord("\t"))
        or byte == UInt8(ord("\r"))
        or byte == UInt8(ord("\n"))
    )


struct NetRCAuth(Auth, Movable):
    """Basic auth with the credentials read out of a `.netrc`.

    The file is read once, when this is built, rather than per request. A file
    that changed under a running program would otherwise give two requests in
    the same session two different identities, and the failure would depend on
    timing.
    """

    var _entries: List[_NetrcEntry]

    def __init__(out self, path: StringSpan = "") raises:
        """Read `path`, or the usual file when no path is given.

        `NETRC` in the environment wins over the home directory, which is what
        curl and Python's `netrc` both do, and what makes this testable without
        writing to a real home directory.
        """
        var file = String(path)
        if file == "":
            file = _default_netrc_path()
        self._entries = parse_netrc(read_text(file))

    def sign(mut self, var request: Request) raises -> Request:
        var host = request.url.host()
        var found = self._lookup(host)
        if found:
            request.headers["Authorization"] = found.value()
        return request^

    def _lookup(self, host: StringSpan) raises -> Optional[String]:
        """The header for `host`, preferring a named entry over `default`.

        A `default` entry applies to every host that has no entry of its own,
        so it is only consulted after every named one has been ruled out, and
        only ever once even if the file repeats it.
        """
        for i in range(len(self._entries)):
            if self._entries[i].machine == host:
                return _basic_header(
                    self._entries[i].login, self._entries[i].password
                )
        for i in range(len(self._entries)):
            if self._entries[i].machine == "":
                return _basic_header(
                    self._entries[i].login, self._entries[i].password
                )
        return None

    def next_request(mut self, response: Response) raises -> Optional[Request]:
        return None

    def requires_response_body(self) -> Bool:
        return False


def _default_netrc_path() raises -> String:
    var override = getenv("NETRC")
    if override and override.value() != "":
        return override.take()
    return home_file(".netrc")


def _lower(text: StringSpan) -> String:
    """ASCII lowercase, built through a byte buffer.

    Through bytes rather than characters because a header value is octets and
    re-encoding it as text would corrupt anything a server sent that is not
    UTF-8. ASCII only for the same reason `Headers` folds case that way: a
    locale aware fold turns a Turkish `I` into something no server recognises.
    """
    var buffer = List[UInt8]()
    for byte in text.as_bytes():
        buffer.append(to_lower(byte))
    return String(StringSpan(unsafe_from_utf8=Span(buffer)))


def _hex8(value: Int) -> String:
    """Eight lowercase hex digits, zero padded.

    The nonce count goes on the wire in exactly this shape. A server that is
    checking for replay compares the text it was sent, so `1` and `00000001`
    are not interchangeable even though they are the same number.
    """
    comptime digits = StaticString("0123456789abcdef")
    var out = String()
    for i in range(7, -1, -1):
        var nibble = (value >> (4 * i)) & 0xF
        out += digits[byte = nibble : nibble + 1]
    return out^


struct _Challenge(Movable):
    """The parts of a `WWW-Authenticate: Digest` needed to answer it."""

    var realm: String
    var nonce: String
    var algorithm: String
    var opaque: Optional[String]
    var qop: Optional[String]

    def __init__(
        out self,
        var realm: String,
        var nonce: String,
        var algorithm: String,
        var opaque: Optional[String],
        var qop: Optional[String],
    ):
        self.realm = realm^
        self.nonce = nonce^
        self.algorithm = algorithm^
        self.opaque = opaque^
        self.qop = qop^

    def copy(self) -> Self:
        var opaque = Optional[String]()
        if self.opaque:
            opaque = Optional[String](String(self.opaque.value()))
        var qop = Optional[String]()
        if self.qop:
            qop = Optional[String](String(self.qop.value()))
        return Self(
            String(self.realm),
            String(self.nonce),
            String(self.algorithm),
            opaque^,
            qop^,
        )


def split_http_list(text: StringSpan) -> List[String]:
    """A comma separated header value, split without breaking quoted strings.

    A digest challenge is a list of `key=value` pairs, and a value is allowed to
    be a quoted string containing commas. The realm is the one that bites in
    practice, since `realm="Files, private"` is legal and splitting it naively
    produces two fields that both parse and are both wrong.
    """
    var out = List[String]()
    var bytes = text.as_bytes()
    var field = List[UInt8]()
    var in_quotes = False
    var at = 0

    while at < len(bytes):
        var byte = bytes[at]
        if in_quotes and byte == UInt8(ord("\\")) and at + 1 < len(bytes):
            # A backslash inside a quoted string quotes whatever follows, so a
            # quoted quote does not end the string.
            field.append(byte)
            field.append(bytes[at + 1])
            at += 2
            continue
        if byte == UInt8(ord('"')):
            in_quotes = not in_quotes
        elif byte == UInt8(ord(",")) and not in_quotes:
            out.append(_trimmed_bytes(Span(field)))
            field = List[UInt8]()
            at += 1
            continue
        field.append(byte)
        at += 1

    out.append(_trimmed_bytes(Span(field)))
    return out^


def _trimmed(text: StringSpan) -> String:
    return _trimmed_bytes(text.as_bytes())


def _trimmed_bytes[o: ImmOrigin](bytes: Span[UInt8, o]) -> String:
    # Not validated as UTF-8, because a header value is octets and a realm sent
    # in some other encoding has to survive to be hashed. It is hashed as bytes
    # either way, so what it means as text never comes up.
    return String(StringSpan(unsafe_from_utf8=trim_ows(bytes)))


def _unquoted(text: StringSpan) -> String:
    """The value with its surrounding quotes taken off, if it had any."""
    var bytes = text.as_bytes()
    if (
        len(bytes) >= 2
        and bytes[0] == UInt8(ord('"'))
        and bytes[len(bytes) - 1] == UInt8(ord('"'))
    ):
        return String(StringSpan(unsafe_from_utf8=bytes[1 : len(bytes) - 1]))
    return String(text)


def parse_challenge(header: StringSpan) raises -> _Challenge:
    """A `Digest ...` challenge, taken apart.

    `realm` and `nonce` are the two fields there is no way to answer without,
    so a challenge missing either is refused here rather than producing a
    header the server will reject for reasons the caller cannot see. Everything
    else has a default or is optional.
    """
    var space = -1
    var bytes = header.as_bytes()
    for i in range(len(bytes)):
        if bytes[i] == UInt8(ord(" ")):
            space = i
            break
    if space < 0:
        raise new_error(
            ErrorKind.PROTOCOL_ERROR,
            String("Malformed Digest WWW-Authenticate header"),
        )

    var realm = String()
    var nonce = String()
    var algorithm = String()
    var opaque = Optional[String]()
    var qop = Optional[String]()
    var have_realm = False
    var have_nonce = False

    var fields = split_http_list(header[byte = space + 1 :])
    for i in range(len(fields)):
        var field = fields[i]
        var eq = field.find("=")
        if eq < 0:
            continue
        var name = _lower(_trimmed(field[byte=0:eq]))
        var value = _unquoted(_trimmed(field[byte = eq + 1 :]))
        if name == "realm":
            realm = value^
            have_realm = True
        elif name == "nonce":
            nonce = value^
            have_nonce = True
        elif name == "algorithm":
            algorithm = value^
        elif name == "opaque":
            opaque = Optional[String](value^)
        elif name == "qop":
            qop = Optional[String](value^)

    if not have_realm or not have_nonce:
        raise new_error(
            ErrorKind.PROTOCOL_ERROR,
            String("Malformed Digest WWW-Authenticate header"),
        )
    if algorithm == "":
        # RFC 7616 says an absent algorithm means MD5, and plenty of servers
        # leave it out.
        algorithm = String("MD5")
    return _Challenge(realm^, nonce^, algorithm^, opaque^, qop^)


def _hash_for(algorithm: StringSpan) raises -> Algorithm:
    """The hash a challenge named, with the session variants folded in.

    `-sess` changes how `HA1` is built, not which hash builds it, so it is
    stripped here and looked at again where it matters.
    """
    var name = _lower(algorithm)
    if name.endswith("-sess"):
        var stem = String(name[byte = 0 : name.byte_length() - 5])
        name = stem^
    if name == "md5":
        return Algorithm.MD5
    if name == "sha":
        return Algorithm.SHA1
    if name == "sha-256":
        return Algorithm.SHA256
    if name == "sha-512":
        return Algorithm.SHA512
    raise new_error(
        ErrorKind.PROTOCOL_ERROR,
        String(
            "Unknown algorithm '",
            algorithm,
            "' in Digest WWW-Authenticate header",
        ),
    )


def _resolve_qop(qop: Optional[String]) raises -> Optional[String]:
    """Which quality of protection to use, out of what the server offered.

    `auth` is the only one implemented. `auth-int` covers the body as well,
    which means the entire request body has to be hashed before the headers can
    be written, and nothing in the wild asks for it. A server that offers only
    `auth-int` is told so instead of being sent an `auth` response it will
    reject.
    """
    if not qop:
        return None
    var offered = String(qop.value())
    var found_auth = False
    var only_auth_int = True
    for piece in offered.split(","):
        var one = _trimmed(piece)
        if one == "auth":
            found_auth = True
        if one != "auth-int":
            only_auth_int = False
    if found_auth:
        return Optional[String](String("auth"))
    if only_auth_int:
        raise new_error(
            ErrorKind.PROTOCOL_ERROR,
            String("Digest auth-int support is not yet implemented"),
        )
    raise new_error(
        ErrorKind.PROTOCOL_ERROR,
        String("Unexpected qop value '", offered, "' in digest auth"),
    )


struct DigestAuth(Auth, Movable):
    """RFC 7616. Answer a challenge with a hash, never with the password.

    Costs a round trip the first time, because there is nothing to answer until
    the server has sent a nonce. After that the challenge is remembered and
    every later request goes out authenticated straight away, which is what the
    nonce count field is for: it lets the server see that a captured header is
    being replayed.
    """

    var _username: String
    var _password: String
    var _challenge: Optional[_Challenge]
    var _nonce_count: Int
    var _retried: Bool

    def __init__(out self, username: StringSpan, password: StringSpan):
        self._username = String(username)
        self._password = String(password)
        self._challenge = None
        self._nonce_count = 1
        self._retried = False

    def sign(mut self, var request: Request) raises -> Request:
        self._retried = False
        if self._challenge:
            var challenge = self._challenge.value().copy()
            var header = self._build_header(request, challenge)
            request.headers["Authorization"] = header
        return request^

    def next_request(mut self, response: Response) raises -> Optional[Request]:
        """The retry, once, after a challenge we can answer.

        Only once, because a server that answers the response to its own
        challenge with another challenge is either rejecting the credentials or
        is broken, and in both cases trying again produces the same 401 forever.
        """
        if self._retried:
            return None
        if response.status_code != 401:
            return None

        var challenge_header = String()
        var found = False
        for ref header in response.headers.get_list("www-authenticate"):
            if _lower(header).startswith("digest "):
                challenge_header = String(header)
                found = True
                break
        if not found:
            return None

        self._challenge = Optional[_Challenge](
            parse_challenge(challenge_header)
        )
        # A fresh challenge restarts the count. The server is tracking it
        # against the nonce it just issued, and that count starts at one.
        self._nonce_count = 1
        self._retried = True

        var retry = response.request().copy()
        var challenge = self._challenge.value().copy()
        retry.headers["Authorization"] = self._build_header(retry, challenge)

        # Some servers tie the challenge to a session cookie sent alongside it,
        # so the retry has to carry that cookie or it gets challenged again with
        # a different nonce and never converges.
        var jar = CookieJar()
        var now = unix_now()
        var stored = False
        for ref header in response.headers.get_list("set-cookie"):
            if jar.set_cookie(retry.url, header, now):
                stored = True
        if stored:
            var cookies = jar.header_for(retry.url, now)
            if cookies:
                retry.headers["Cookie"] = cookies
        return Optional[Request](retry^)

    def requires_response_body(self) -> Bool:
        return False

    def _build_header(
        mut self, request: Request, challenge: _Challenge
    ) raises -> String:
        var algorithm = _hash_for(challenge.algorithm)

        # The path is taken from the URL rather than from anything the caller
        # wrote, because the server hashes the path it received. A `uri` field
        # that disagreed with the request line by so much as an encoded space
        # would fail with no way to tell why.
        var path = request.url.raw_path()

        var a1 = String(
            self._username, ":", challenge.realm, ":", self._password
        )
        var a2 = String(request.method, ":", path)
        var ha2 = hex_digest(algorithm, a2.as_bytes())

        var nc_value = _hex8(self._nonce_count)
        var cnonce = self._client_nonce(self._nonce_count, challenge.nonce)
        self._nonce_count += 1

        var ha1 = hex_digest(algorithm, a1.as_bytes())
        if _lower(challenge.algorithm).endswith("-sess"):
            # The session variant folds both nonces into HA1 once, so a later
            # password change is not what invalidates the session, the nonce is.
            var seed = String(ha1, ":", challenge.nonce, ":", cnonce)
            ha1 = hex_digest(algorithm, seed.as_bytes())

        var qop = _resolve_qop(challenge.qop)
        var digest_data: String
        if qop:
            digest_data = String(
                ha1,
                ":",
                challenge.nonce,
                ":",
                nc_value,
                ":",
                cnonce,
                ":",
                qop.value(),
                ":",
                ha2,
            )
        else:
            # No qop at all is the RFC 2069 shape, which some old servers still
            # speak and which leaves out the client nonce entirely.
            digest_data = String(ha1, ":", challenge.nonce, ":", ha2)
        var response = hex_digest(algorithm, digest_data.as_bytes())

        var out = String("Digest ")
        out += String('username="', self._username, '"')
        out += String(', realm="', challenge.realm, '"')
        out += String(', nonce="', challenge.nonce, '"')
        out += String(', uri="', path, '"')
        out += String(', response="', response, '"')
        # `algorithm`, `qop` and `nc` are the three fields the grammar says are
        # bare tokens. Quoting them is what a lot of servers reject.
        out += String(", algorithm=", challenge.algorithm)
        if challenge.opaque:
            out += String(', opaque="', challenge.opaque.value(), '"')
        if qop:
            out += String(", qop=", qop.value())
            out += String(", nc=", nc_value)
            out += String(', cnonce="', cnonce, '"')
        return out^

    def _client_nonce(
        self, nonce_count: Int, nonce: StringSpan
    ) raises -> String:
        """A value the server cannot have chosen.

        This is the half of the exchange the client controls, and it is what
        stops a hostile server from picking both nonces and running an offline
        attack on the password with a chosen plaintext. The count and the
        server nonce are in there so two requests a second apart cannot collide,
        and the kernel bytes are what make it unpredictable.
        """
        var seed = String(nonce_count, StringSpan(nonce), unix_now())
        var material = List[UInt8]()
        material.extend(seed.as_bytes())
        material.extend(Span(random_bytes(8)))
        return String(hex(Span(sha1(Span(material))))[byte=0:16])


def basic_auth(username: StringSpan, password: StringSpan) -> AnyAuth:
    """`BasicAuth`, ready to hand to a client.

    httpx lets you write `auth=("user", "pass")` and turns the pair into a
    `BasicAuth` behind your back. A tuple here would have to be one more
    overload on every method that takes an auth, so the sugar is a function
    instead. It is the same amount of typing and it says which scheme it is,
    which the tuple never did.
    """
    return erase_auth(BasicAuth(username, password))


def digest_auth(username: StringSpan, password: StringSpan) -> AnyAuth:
    """`DigestAuth`, ready to hand to a client."""
    return erase_auth(DigestAuth(username, password))


def netrc_auth(path: StringSpan = "") raises -> AnyAuth:
    """`NetRCAuth`, ready to hand to a client. Reads the file now, not later."""
    return erase_auth(NetRCAuth(path))
