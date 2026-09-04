"""Cookies, the jar behind them, and the RFC 6265 rules that decide what goes
where.

There are two types here because they answer two different questions. `Cookies`
is what a caller touches, and it behaves like a dictionary of name to value
because that is how people think about cookies. `CookieJar` is the storage
model from RFC 6265 section 5.3, which is not a dictionary at all: the same name
can be stored several times under different domains and paths, and which copy
gets sent depends on the URL being requested.

Collapsing the two would be easy and wrong. A jar holding `session=a` for
`example.com` and `session=b` for `other.example.com` is a correct jar, and a
dictionary cannot hold it. `Cookies` handles that by raising `CookieConflict`
when a lookup by bare name is ambiguous, which is what httpx2 does, rather than
picking one and being quietly wrong half the time.

Three rules in here are security controls rather than conveniences, and each one
is written out at the function that implements it: a cookie may not be scoped to
a public suffix, a cookie may not be scoped to a domain the responding host does
not belong to, and a `Secure` cookie never leaves over plain HTTP.

Everything that depends on the current time takes it as an argument. That keeps
the clock out of this layer and, more usefully, makes expiry testable without
waiting for it.
"""

from httpx._bytes import equal_ascii_ci, index_of, is_digit, to_lower
from httpx._exceptions import ErrorKind, new_error
from httpx._models.headers import Headers
from httpx._models.url import URL
from httpx._util.date import parse_cookie_date
from httpx._util.psl import is_public_suffix

comptime _SEMICOLON = UInt8(0x3B)
comptime _EQUALS = UInt8(0x3D)
comptime _SLASH = UInt8(0x2F)
comptime _DOT = UInt8(0x2E)
comptime _SPACE = UInt8(0x20)
comptime _HTAB = UInt8(0x09)
comptime _MINUS = UInt8(0x2D)

comptime _EXPIRED = -1
"""The expiry a `Max-Age` of zero or less produces.

Any value in the past would do. Using one fixed value keeps the deletion case
recognisable in a debugger instead of looking like a date from 1969 that
happened to be sent.
"""


def _ci(text: StringSpan, expected: StaticString) -> Bool:
    """Case-insensitive compare against a literal, without building a String.

    Comparing a span to a literal directly would construct a `String` for the
    literal on every call, and attribute names are compared several times per
    `Set-Cookie`.
    """
    return equal_ascii_ci(text.as_bytes(), expected.as_bytes())


def _lowered(text: StringSpan) -> String:
    # Built through a byte buffer rather than by appending characters, because
    # `chr` re-encodes anything above 127 as two UTF-8 bytes and a domain that
    # arrived as raw bytes would come out corrupted.
    var buffer = List[UInt8]()
    for byte in text.as_bytes():
        buffer.append(to_lower(byte))
    return String(StringSpan(unsafe_from_utf8=Span(buffer)))


def _is_wsp(byte: UInt8) -> Bool:
    return byte == _SPACE or byte == _HTAB


def _trim[o: ImmOrigin](text: Span[UInt8, o]) -> Span[UInt8, o]:
    """Strip the whitespace RFC 6265 section 5.2 says to strip.

    Space and horizontal tab only. A carriage return or a line feed inside a
    `Set-Cookie` is a header injection attempt, and `Headers` has already
    rejected the whole header by the time anything gets here.
    """
    var start = 0
    var end = text.__len__()
    while start < end and _is_wsp(text[start]):
        start += 1
    while end > start and _is_wsp(text[end - 1]):
        end -= 1
    return text[start:end]


def _text[o: ImmOrigin](span: Span[UInt8, o]) -> String:
    """The bytes as they are, with no UTF-8 validation.

    A cookie value is octets. Servers send text in whatever encoding they like
    and some send bytes that are not text at all, so validating here would mean
    rejecting cookies that browsers accept. The bytes are carried through
    unchanged and it is the caller's business what they mean.
    """
    return String(StringSpan(unsafe_from_utf8=span))


def is_ip_address(host: StringSpan) -> Bool:
    """Whether `host` is a literal address rather than a name.

    This exists for domain matching, which must never treat an address as
    belonging to a domain. Without the check a response from `1.2.3.4` could set
    a cookie for `3.4`, and the suffix rule would happily agree that it matches.

    The test is deliberately loose: anything made only of digits and dots, and
    anything containing a colon, which covers IPv6 in every form it is written.
    A hostname can be neither of those, so nothing is misclassified in the
    direction that matters.
    """
    var bytes = host.as_bytes()
    if bytes.__len__() == 0:
        return False
    if index_of(bytes, UInt8(0x3A)) >= 0:
        return True
    for byte in bytes:
        if not is_digit(byte) and byte != _DOT:
            return False
    return True


def domain_matches(host: StringSpan, domain: StringSpan) -> Bool:
    """RFC 6265 section 5.1.3.

    True when the host is the domain, or is a subdomain of it. The dot in the
    subdomain case has to be checked explicitly: `notexample.com` ends with
    `example.com` as a string and is a completely unrelated site.
    """
    var h = host.as_bytes()
    var d = domain.as_bytes()
    if d.__len__() == 0:
        return False
    if equal_ascii_ci(h, d):
        return True
    if h.__len__() <= d.__len__():
        return False
    if not equal_ascii_ci(h[h.__len__() - d.__len__() : h.__len__()], d):
        return False
    if h[h.__len__() - d.__len__() - 1] != _DOT:
        return False
    return not is_ip_address(host)


def default_path(request_path: StringSpan) -> String:
    """RFC 6265 section 5.1.4, the path a cookie gets when it does not say.

    The rule is the directory of the request, not the request itself, so a
    cookie set by `/a/b` covers `/a` and everything under it. That is wider than
    people expect and it is what the specification says.
    """
    var bytes = request_path.as_bytes()
    if bytes.__len__() == 0 or bytes[0] != _SLASH:
        return String("/")
    var last = -1
    for i in range(bytes.__len__()):
        if bytes[i] == _SLASH:
            last = i
    if last <= 0:
        return String("/")
    return _text(bytes[0:last])


def path_matches(request_path: StringSpan, cookie_path: StringSpan) -> Bool:
    """RFC 6265 section 5.1.4.

    A prefix is not enough on its own. `/foobar` starts with `/foo` and is not
    underneath it, so the byte after the prefix has to be a separator, unless
    the cookie path already ended in one.
    """
    var request = request_path.as_bytes()
    var cookie = cookie_path.as_bytes()
    if cookie.__len__() == 0:
        return False
    if request.__len__() == cookie.__len__():
        return request == cookie
    if request.__len__() < cookie.__len__():
        return False
    for i in range(cookie.__len__()):
        if request[i] != cookie[i]:
            return False
    if cookie[cookie.__len__() - 1] == _SLASH:
        return True
    return request[cookie.__len__()] == _SLASH


struct SameSite(Equatable, ImplicitlyCopyable, Movable):
    """The `SameSite` attribute, including the case where there was not one.

    `UNSET` is distinct from `NONE` on purpose. A server that omits the
    attribute and a server that writes `SameSite=None` are saying different
    things, and collapsing them loses the only signal a caller has for which
    happened.

    ```mojo
    from httpx import Cookie, SameSite


    def main() raises:
        var c = Cookie(
            "session",
            "abc123",
            domain="example.com",
            same_site=SameSite.STRICT,
        )
        print(c.same_site.name())
    ```
    """

    var _value: UInt8

    comptime UNSET = SameSite(0)
    comptime STRICT = SameSite(1)
    comptime LAX = SameSite(2)
    comptime NONE = SameSite(3)

    def __init__(out self, value: UInt8):
        self._value = value

    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value

    def __ne__(self, other: Self) -> Bool:
        return self._value != other._value

    def name(self) -> StaticString:
        if self._value == 1:
            return "Strict"
        if self._value == 2:
            return "Lax"
        if self._value == 3:
            return "None"
        return "Unset"


struct Cookie(Copyable, Movable, Writable):
    """One stored cookie, with everything the matching rules need.

    `host_only` is the field that is easy to leave out and impossible to
    reconstruct later. A `Set-Cookie` without a `Domain` attribute belongs to
    exactly the host that sent it, while one with `Domain=example.com` belongs
    to that host and every host under it. Both end up with `domain` set to
    something, so without a separate flag the narrow case silently widens.

    ```mojo
    from httpx import Cookie


    def main() raises:
        var c = Cookie("session", "abc123", domain="example.com", secure=True)
        print(c.matches("example.com", "/", True))
        print(c.is_expired(0))
    ```
    """

    var name: String
    var value: String
    var domain: String
    var host_only: Bool
    var path: String
    var expires: Optional[Int]
    var secure: Bool
    var http_only: Bool
    var same_site: SameSite
    var creation: Int

    def __init__(
        out self,
        name: StringSpan,
        value: StringSpan,
        domain: StringSpan = "",
        path: StringSpan = "/",
        host_only: Bool = True,
        expires: Optional[Int] = None,
        secure: Bool = False,
        http_only: Bool = False,
        same_site: SameSite = SameSite.UNSET,
        creation: Int = 0,
    ):
        self.name = String(name)
        self.value = String(value)
        self.domain = _lowered(domain)
        self.host_only = host_only
        self.path = String(path)
        self.expires = expires
        self.secure = secure
        self.http_only = http_only
        self.same_site = same_site
        self.creation = creation

    def is_expired(self, now: Int) -> Bool:
        """Session cookies never expire this way, they expire with the jar."""
        if not self.expires:
            return False
        return self.expires.value() <= now

    def matches(self, host: StringSpan, path: StringSpan, secure: Bool) -> Bool:
        """Whether this cookie belongs on a request to `host` and `path`."""
        if self.host_only:
            if not equal_ascii_ci(host.as_bytes(), self.domain.as_bytes()):
                return False
        elif self.domain and not domain_matches(host, self.domain):
            # No domain at all only happens for a cookie the application set
            # itself, since one parsed out of a response always ends up scoped
            # to something. It means every host, which is what somebody writing
            # `client.cookies["session"] = ...` and no domain meant.
            return False
        if not path_matches(path, self.path):
            return False
        # A Secure cookie withheld from a plain HTTP request is the whole point
        # of the attribute. Sending it once is enough to leak it.
        if self.secure and not secure:
            return False
        return True

    def write_to[W: Writer](self, mut writer: W):
        """Renders as a `Set-Cookie` would, minus the value.

        The value is left out because this is what ends up in a log line or a
        test failure, and a session cookie printed into a log is a session
        somebody else can use.
        """
        writer.write(self.name)
        writer.write("=[", String(self.value.byte_length()), " bytes]")
        writer.write("; Domain=")
        if not self.host_only:
            writer.write(".")
        writer.write(self.domain)
        writer.write("; Path=", self.path)
        if self.expires:
            writer.write("; Expires=", String(self.expires.value()))
        if self.secure:
            writer.write("; Secure")
        if self.http_only:
            writer.write("; HttpOnly")
        if self.same_site != SameSite.UNSET:
            writer.write("; SameSite=", self.same_site.name())


def parse_set_cookie(
    header: StringSpan, host: StringSpan, path: StringSpan, now: Int
) raises -> Optional[Cookie]:
    """Read one `Set-Cookie` value, following RFC 6265 section 5.2 literally.

    Literally is the operative word. The algorithm looks wrong in several places
    and every one of those places is load bearing, because it describes what
    browsers already did rather than what would have been tidy:

    An unrecognised attribute is skipped, not an error, which is what lets new
    attributes be deployed without breaking old clients.

    An attribute whose value is unusable does not reject the cookie, it falls
    back to that attribute's default. The two cases differ in a way worth
    knowing: a `Max-Age` that is not a number is skipped entirely, so an earlier
    `Max-Age` still stands, while a `Path` that does not start with a slash
    resets the path to the default and overwrites an earlier `Path` that was
    perfectly good. Both are what section 5.2 says.

    The name and value are split at the first equals sign and nothing else is
    inspected, so quotes stay part of the value and a value may contain further
    equals signs.

    Only two things reject the whole cookie: no equals sign in the first pair at
    all, and an empty name. Returns nothing in those cases.

    The result is not stored yet. `CookieJar.set_cookie` applies the rules that
    need to compare it against the request, which is where a cookie can still be
    refused.
    """
    var bytes = header.as_bytes()
    var end = index_of(bytes, _SEMICOLON)
    var pair = bytes[0:end] if end >= 0 else bytes
    var split = index_of(pair, _EQUALS)
    if split < 0:
        return None
    var name = _trim(pair[0:split])
    var value = _trim(pair[split + 1 : pair.__len__()])
    if name.__len__() == 0:
        return None

    var domain = String()
    # Seeded with the default rather than left empty, because a `Path` whose
    # value is unusable resets to the default rather than being skipped, and
    # that has to overwrite an earlier `Path` that was fine.
    var cookie_path = default_path(path)
    var expires = Optional[Int]()
    var max_age = Optional[Int]()
    var secure = False
    var http_only = False
    var same_site = SameSite.UNSET

    var i = end
    while i >= 0 and i < bytes.__len__():
        var start = i + 1
        var stop = index_of(bytes, _SEMICOLON, start)
        var attribute = (
            bytes[start:stop] if stop >= 0 else bytes[start : bytes.__len__()]
        )
        i = stop

        var mark = index_of(attribute, _EQUALS)
        var key = _trim(attribute[0:mark]) if mark >= 0 else _trim(attribute)
        var raw = (
            _trim(attribute[mark + 1 : attribute.__len__()]) if mark
            >= 0 else attribute[0:0]
        )
        # The attribute name is only ever compared with `_ci`, which works on
        # bytes, so no byte of it is decoded and invalid UTF-8 cannot escape
        # this span. Validating instead would reject the whole cookie because a
        # server misspelled an attribute we were going to ignore anyway.
        var key_text = StringSpan(unsafe_from_utf8=key)
        var raw_text = _text(raw)

        if _ci(key_text, "expires"):
            try:
                expires = parse_cookie_date(raw)
            except:
                # A date we cannot read leaves the cookie as a session cookie.
                # Treating it as already expired would delete a cookie because
                # of a server's formatting, which is the worse mistake.
                pass
        elif _ci(key_text, "max-age"):
            var delta = _parse_max_age(raw)
            if delta:
                max_age = delta.value()
        elif _ci(key_text, "domain"):
            if raw.__len__() > 0:
                var trimmed = raw[1 : raw.__len__()] if raw[0] == _DOT else raw
                domain = _lowered(StringSpan(unsafe_from_utf8=trimmed))
        elif _ci(key_text, "path"):
            if raw.__len__() > 0 and raw[0] == _SLASH:
                cookie_path = raw_text^
            else:
                cookie_path = default_path(path)
        elif _ci(key_text, "secure"):
            secure = True
        elif _ci(key_text, "httponly"):
            http_only = True
        elif _ci(key_text, "samesite"):
            if _ci(raw_text, "strict"):
                same_site = SameSite.STRICT
            elif _ci(raw_text, "lax"):
                same_site = SameSite.LAX
            elif _ci(raw_text, "none"):
                same_site = SameSite.NONE

    # Max-Age wins over Expires when both are present. It is a duration rather
    # than a date, so it survives a client whose clock is wrong, which is why
    # the specification prefers it.
    if max_age:
        var seconds = max_age.value()
        expires = _EXPIRED if seconds <= 0 else now + seconds

    var host_only = domain.byte_length() == 0
    var scope = String(host) if host_only else domain^

    return Cookie(
        name=StringSpan(unsafe_from_utf8=name),
        value=StringSpan(unsafe_from_utf8=value),
        domain=scope,
        path=cookie_path^,
        host_only=host_only,
        expires=expires,
        secure=secure,
        http_only=http_only,
        same_site=same_site,
        creation=now,
    )


def _parse_max_age[o: ImmOrigin](raw: Span[UInt8, o]) -> Optional[Int]:
    """`Max-Age`, which is a signed count of seconds and nothing else.

    A leading minus is allowed and means the cookie is already gone. Anything
    that is not digits after that, including a decimal point, makes the whole
    attribute unusable, and an unusable attribute is skipped rather than
    rejecting the cookie.
    """
    if raw.__len__() == 0:
        return None
    var start = 1 if raw[0] == _MINUS else 0
    if raw.__len__() == start:
        return None
    var total = 0
    for i in range(start, raw.__len__()):
        if not is_digit(raw[i]):
            return None
        var digit = Int(raw[i] - UInt8(0x30))
        if total > (Int.MAX - digit) // 10:
            # A count of seconds this large is the far future either way, so it
            # saturates rather than raising. Overflowing into a negative would
            # turn a very long lived cookie into a deletion.
            return Int.MAX
        total = total * 10 + digit
    return -total if start == 1 else total


struct CookieJar(Boolable, Movable, Sized):
    """The RFC 6265 section 5.3 storage model.

    Cookies are keyed by the triple of name, domain and path, so the same name
    can be present many times over. Storage is a flat list rather than a map
    because every read is a scan anyway: deciding whether a cookie applies to a
    request means running the domain and path rules against each one, and there
    is no key that could be looked up instead. Jars hold single digit numbers of
    cookies in practice.

    ```mojo
    from httpx import CookieJar, Cookie, URL


    def main() raises:
        var jar = CookieJar()
        jar.store(Cookie("session", "abc123", domain="example.com"))
        print(jar.header_for(URL("https://example.com/account"), 0))
    ```
    """

    var _cookies: List[Cookie]

    def __init__(out self):
        self._cookies = List[Cookie]()

    def copy(self) -> Self:
        var out = Self()
        for ref cookie in self._cookies:
            out._cookies.append(cookie.copy())
        return out^

    def __len__(self) -> Int:
        return len(self._cookies)

    def __bool__(self) -> Bool:
        return len(self._cookies) > 0

    def _find(
        self, name: StringSpan, domain: StringSpan, path: StringSpan
    ) -> Int:
        """The index of the cookie with this exact identity, or -1.

        Names are compared case sensitively and domains are not, which is not an
        inconsistency: a domain is a hostname and hostnames are case insensitive,
        while a cookie name is an opaque token and `Session` and `session` are
        two different cookies.
        """
        for i in range(len(self._cookies)):
            ref cookie = self._cookies[i]
            if cookie.name != name:
                continue
            if not equal_ascii_ci(cookie.domain.as_bytes(), domain.as_bytes()):
                continue
            if cookie.path != path:
                continue
            return i
        return -1

    def store(mut self, var cookie: Cookie):
        """Insert or replace, keeping the original creation time.

        Section 5.3 step 11. The creation time is preserved across an update
        because it is what breaks ties in send order, and a server refreshing a
        cookie on every response would otherwise walk it to the end of the
        `Cookie` header and change what the server sees.
        """
        var found = self._find(cookie.name, cookie.domain, cookie.path)
        if found < 0:
            self._cookies.append(cookie^)
            return
        cookie.creation = self._cookies[found].creation
        self._cookies[found] = cookie^

    def remove(
        mut self, name: StringSpan, domain: StringSpan, path: StringSpan
    ) -> Bool:
        var found = self._find(name, domain, path)
        if found < 0:
            return False
        _ = self._cookies.pop(found)
        return True

    def clear(mut self):
        self._cookies.clear()

    def purge_expired(mut self, now: Int):
        var kept = List[Cookie]()
        for ref cookie in self._cookies:
            if not cookie.is_expired(now):
                kept.append(cookie.copy())
        self._cookies = kept^

    def set_cookie(
        mut self, url: URL, header: StringSpan, now: Int
    ) raises -> Bool:
        """Apply one `Set-Cookie` from a response to `url`. True when stored.

        This is where a well formed cookie can still be refused, and both
        refusals are security controls.

        A cookie scoped to a public suffix is dropped. `Domain=co.uk` would
        otherwise let any site under it set a cookie every other site under it
        sends back, which is a cross site write on the whole registry.

        A cookie scoped to a domain the responding host does not belong to is
        dropped. Without that check a response from `evil.com` could set a
        cookie for `bank.com`.

        A cookie that arrives already expired is a deletion, which is the
        standard way servers remove one, so it takes the matching cookie with it
        rather than being stored and cleaned up later.
        """
        var host = String(StringSpan(unsafe_from_utf8=url.raw_host()))
        var parsed = parse_set_cookie(header, host, url.path(), now)
        if not parsed:
            return False
        var cookie = parsed.take()

        if not cookie.host_only:
            # Equal to the host is the one case a public suffix is allowed: a
            # site that genuinely sits at one can still set a cookie for itself.
            if is_public_suffix(
                cookie.domain.as_bytes()
            ) and not equal_ascii_ci(host.as_bytes(), cookie.domain.as_bytes()):
                return False
            if not domain_matches(host, cookie.domain):
                return False

        if cookie.is_expired(now):
            _ = self.remove(cookie.name, cookie.domain, cookie.path)
            return False

        self.store(cookie^)
        return True

    def extract(mut self, url: URL, headers: Headers, now: Int) raises -> Int:
        """Apply every `Set-Cookie` in a response to `url`. Returns how many stuck.

        The count is returned rather than thrown away because a caller that
        wants to know whether anything changed would otherwise have to compare
        the size of the jar before and against after, and a refresh of a cookie
        that was already there does not change the size.
        """
        var stored = 0
        for ref header in headers.get_list("set-cookie"):
            if self.set_cookie(url, header, now):
                stored += 1
        return stored

    def matching(self, url: URL, now: Int) raises -> List[Cookie]:
        """Every cookie that belongs on a request to `url`, in send order.

        Section 5.4 fixes the order: longer paths first, and among equal paths
        the one created first. Servers do rely on it, usually without knowing
        they do, because the first value for a repeated name is what most
        frameworks hand to the application.
        """
        var host = String(StringSpan(unsafe_from_utf8=url.raw_host()))
        var path = url.path()
        if path.byte_length() == 0:
            path = String("/")
        var secure = url.is_ssl()

        var out = List[Cookie]()
        for ref cookie in self._cookies:
            if cookie.is_expired(now):
                continue
            if cookie.matches(host, path, secure):
                out.append(cookie.copy())

        # An insertion sort, because a jar holds a handful of cookies and this
        # keeps the comparison in one readable place.
        for i in range(1, len(out)):
            var j = i
            while j > 0 and _sorts_before(out[j], out[j - 1]):
                out.swap_elements(j, j - 1)
                j -= 1
        return out^

    def header_for(self, url: URL, now: Int) raises -> String:
        """The `Cookie` header value for a request to `url`, or empty.

        Empty means send no header at all. A `Cookie:` with nothing after it is
        not the same message and some servers treat it differently.
        """
        var out = String()
        var cookies = self.matching(url, now)
        for i in range(len(cookies)):
            if i:
                out += "; "
            out += cookies[i].name
            out += "="
            out += cookies[i].value
        return out^


def _sorts_before(left: Cookie, right: Cookie) -> Bool:
    var l = left.path.byte_length()
    var r = right.path.byte_length()
    if l != r:
        return l > r
    return left.creation < right.creation


struct Cookies(Boolable, Movable, Sized):
    """The dictionary shaped view a caller uses.

    Lookups take a bare name because that is what callers have. When a name is
    unambiguous that works exactly like a dictionary. When it is not, because
    the jar holds the same name for two domains or two paths, the lookup raises
    `CookieConflict` rather than choosing, since either choice would be wrong
    half the time and wrong silently.

    ```mojo
    from httpx import Client, Cookies


    def main() raises:
        var jar = Cookies()
        jar.set("consent", "yes", domain="example.com")
        with Client(cookies=jar^) as client:
            var r = client.get("https://example.com/account")
            print(r.status_code, client.cookies.get("session"))
    ```
    """

    var jar: CookieJar

    def __init__(out self):
        self.jar = CookieJar()

    def __init__(out self, items: List[Tuple[String, String]]):
        self.jar = CookieJar()
        for ref item in items:
            self.set(item[0], item[1])

    def copy(self) -> Self:
        var out = Self()
        out.jar = self.jar.copy()
        return out^

    def __len__(self) -> Int:
        return len(self.jar)

    def __bool__(self) -> Bool:
        return len(self.jar) > 0

    def __contains__(self, name: StringSpan) -> Bool:
        for ref cookie in self.jar._cookies:
            if cookie.name == name:
                return True
        return False

    def set(
        mut self,
        name: StringSpan,
        value: StringSpan,
        domain: StringSpan = "",
        path: StringSpan = "/",
    ):
        """Add a cookie directly, bypassing the response rules.

        Nothing is checked against a public suffix here, because there is no
        response to check against and the caller is the application rather than
        a remote server. A cookie set this way with an empty domain matches any
        host, which is what a caller who wrote no domain meant.
        """
        self.jar.store(
            Cookie(
                name=name,
                value=value,
                domain=domain,
                path=path,
                host_only=False,
            )
        )

    def get(
        self,
        name: StringSpan,
        default: StringSpan = "",
        domain: StringSpan = "",
        path: StringSpan = "",
    ) raises -> String:
        """The value for `name`, narrowed by domain and path if given.

        An empty domain or path means any, so `get("session")` searches the whole
        jar and `get("session", domain="example.com")` searches one site's
        cookies. Raises `CookieConflict` when more than one matches, and returns
        `default` when none does.
        """
        var found = String()
        var seen = 0
        for ref cookie in self.jar._cookies:
            if cookie.name != name:
                continue
            if domain and cookie.domain != domain:
                continue
            if path and cookie.path != path:
                continue
            found = cookie.value
            seen += 1
        if seen > 1:
            raise new_error(
                ErrorKind.COOKIE_CONFLICT,
                String(
                    "multiple cookies named ",
                    name,
                    ". Narrow the lookup with domain= or path=.",
                ),
            )
        if seen == 0:
            return String(default)
        return found^

    def __getitem__(self, name: StringSpan) raises -> String:
        var found = self.get(name, default="")
        if not found and name not in self:
            raise new_error(
                ErrorKind.COOKIE_CONFLICT, String("no cookie named ", name)
            )
        return found^

    def __setitem__(mut self, name: StringSpan, value: StringSpan):
        self.set(name, value)

    def __delitem__(mut self, name: StringSpan) raises:
        if not self.delete(name):
            raise new_error(
                ErrorKind.COOKIE_CONFLICT, String("no cookie named ", name)
            )

    def delete(
        mut self,
        name: StringSpan,
        domain: StringSpan = "",
        path: StringSpan = "",
    ) -> Bool:
        """Drop every cookie with this name, narrowed by domain and path.

        Deleting is allowed to be plural where reading is not. A caller asking
        for one value has to be told which one they meant, but a caller asking
        for a name to be gone means gone.
        """
        var kept = List[Cookie]()
        var removed = False
        for ref cookie in self.jar._cookies:
            var hit = cookie.name == name
            if hit and domain and cookie.domain != domain:
                hit = False
            if hit and path and cookie.path != path:
                hit = False
            if hit:
                removed = True
            else:
                kept.append(cookie.copy())
        self.jar._cookies = kept^
        return removed

    def clear(mut self, domain: StringSpan = "", path: StringSpan = ""):
        var kept = List[Cookie]()
        for ref cookie in self.jar._cookies:
            var hit = True
            if domain and cookie.domain != domain:
                hit = False
            if path and cookie.path != path:
                hit = False
            if not hit:
                kept.append(cookie.copy())
        self.jar._cookies = kept^

    def update(mut self, other: Self):
        for ref cookie in other.jar._cookies:
            self.jar.store(cookie.copy())

    def extract(mut self, url: URL, headers: Headers, now: Int) raises -> Int:
        """Apply a response's `Set-Cookie` fields to this jar."""
        return self.jar.extract(url, headers, now)

    def header_for(self, url: URL, now: Int) raises -> String:
        """The `Cookie` header value for a request to `url`, or empty."""
        return self.jar.header_for(url, now)

    def keys(self) -> List[String]:
        var out = List[String]()
        for ref cookie in self.jar._cookies:
            out.append(cookie.name)
        return out^

    def values(self) -> List[String]:
        var out = List[String]()
        for ref cookie in self.jar._cookies:
            out.append(cookie.value)
        return out^

    def items(self) -> List[Tuple[String, String]]:
        var out = List[Tuple[String, String]]()
        for ref cookie in self.jar._cookies:
            out.append((cookie.name, cookie.value))
        return out^
