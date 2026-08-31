"""`URL` and `QueryParams`.

`URL` keeps one normalized string and a set of index ranges into it, rather than
a bag of decoded component strings. Three things follow from that. Copying is one
string copy. Serializing is returning the string, so it is exact rather than
reassembled and hopefully identical. And every accessor that does not need to
decode anything hands back a view instead of an allocation, which matters because
`raw_host` and `raw_path` are read on the way out for every single request.

Normalization happens once, at construction, so two URLs that mean the same thing
are the same string. That is what lets equality, hashing, the connection pool's
origin map and any cache keyed on a URL all be string comparisons. It is also why
`percent_normalize` has to be idempotent: if it were not, `URL(String(u)) == u`
would be false and every one of those would hold two entries for one resource.

The decoded and raw forms of the host are kept carefully apart. `raw_host` is the
A-label form, and it is what DNS resolves, what goes in a `Host` header and what
cookie domain matching compares. `host` is the Unicode form and is for display
only. Deciding where a request goes based on the display form is how a request
reaches one host while its cookies are scoped to another.
"""

from std.hashlib import Hasher

from httpx._bytes import Bytes, _quote, equal_ascii_ci, to_lower
from httpx._exceptions import ErrorKind, new_error
from httpx._util.idna import decode_host, encode_host
from httpx._util.percent import (
    FRAGMENT,
    PATH,
    QUERY,
    USERINFO,
    form_decode,
    form_encode,
    percent_decode,
    percent_encode,
    percent_normalize,
)


struct Range(Equatable, ImplicitlyCopyable, Movable):
    """A half open span of `URL._raw`.

    `UInt32` rather than `Int` because a URL longer than four gigabytes is not a
    URL, and eight of these ride along in every `URL`.
    """

    var start: UInt32
    var end: UInt32

    def __init__(out self, start: Int, end: Int):
        self.start = UInt32(start)
        self.end = UInt32(end)

    def __eq__(self, other: Self) -> Bool:
        return self.start == other.start and self.end == other.end

    def __ne__(self, other: Self) -> Bool:
        return not (self == other)

    def is_empty(self) -> Bool:
        return self.start == self.end

    def length(self) -> Int:
        return Int(self.end - self.start)


def default_port_for(scheme: StringSpan) -> Optional[UInt16]:
    """The port a scheme implies, so it can be left out of the serialization.

    Keeping `https://example.com:443/` and `https://example.com/` as two distinct
    strings would give the pool two origins for one server and double every
    connection to it.
    """
    if scheme == "http" or scheme == "ws":
        return Optional[UInt16](UInt16(80))
    if scheme == "https" or scheme == "wss":
        return Optional[UInt16](UInt16(443))
    return Optional[UInt16]()


def _is_scheme_start(byte: UInt8) -> Bool:
    return (byte >= UInt8(ord("a")) and byte <= UInt8(ord("z"))) or (
        byte >= UInt8(ord("A")) and byte <= UInt8(ord("Z"))
    )


def _is_scheme_byte(byte: UInt8) -> Bool:
    """RFC 3986 section 3.1."""
    return (
        _is_scheme_start(byte)
        or (byte >= UInt8(ord("0")) and byte <= UInt8(ord("9")))
        or byte == UInt8(ord("+"))
        or byte == UInt8(ord("-"))
        or byte == UInt8(ord("."))
    )


def remove_dot_segments(path: StringSpan) raises -> String:
    """RFC 3986 section 5.2.4.

    The RFC states this as a loop over a character buffer. This is the segment
    stack form, which is easier to read and easier to check, and the tests carry
    the RFC's own examples plus the cases where the two could differ, since an
    equivalent looking rewrite of this particular algorithm is exactly the sort
    of thing that is subtly wrong.

    The output can never climb above the root: a `..` with nothing left to pop is
    discarded rather than escaping, which is what stops a relative reference in a
    redirect from reaching outside the base path.
    """
    var out = List[String]()
    var input = String(path)
    var trailing_slash = False

    var segments = List[String]()
    var current = String()
    var bytes = input.as_bytes()
    for i in range(bytes.__len__()):
        if bytes[i] == UInt8(ord("/")):
            segments.append(current)
            current = String()
        else:
            current += chr(Int(bytes[i]))
    segments.append(current)

    var leading_slash = bytes.__len__() > 0 and bytes[0] == UInt8(ord("/"))

    for index in range(len(segments)):
        var segment = segments[index]
        var last = index == len(segments) - 1
        if segment == ".":
            trailing_slash = True
            continue
        if segment == "..":
            if len(out) > 0:
                _ = out.pop()
            trailing_slash = True
            continue
        if segment == "" and not last:
            continue
        if segment == "" and last:
            trailing_slash = True
            continue
        out.append(segment)
        trailing_slash = False

    var result = String()
    for index in range(len(out)):
        if index > 0 or leading_slash:
            result += "/"
        result += out[index]
    if trailing_slash and (len(out) > 0 or leading_slash):
        result += "/"
    if result.byte_length() == 0 and leading_slash:
        result = String("/")
    return result^


struct _Parts(Movable):
    """The pieces of a URL as they were written, before normalization."""

    var scheme: String
    var has_authority: Bool
    var userinfo: String
    var has_userinfo: Bool
    var host: String
    var port: String
    var path: String
    var query: String
    var has_query: Bool
    var fragment: String
    var has_fragment: Bool

    def __init__(out self):
        self.scheme = String()
        self.has_authority = False
        self.userinfo = String()
        self.has_userinfo = False
        self.host = String()
        self.port = String()
        self.path = String()
        self.query = String()
        self.has_query = False
        self.fragment = String()
        self.has_fragment = False


def _split(text: StringSpan) raises -> _Parts:
    """Split a URL into its pieces without interpreting any of them.

    RFC 3986 section 3. The order of the delimiters is what makes this
    unambiguous: the fragment starts at the first `#`, the query at the first `?`
    before it, and the authority ends at the first `/`, `?` or `#`. Scanning for
    them in any other order is how a `?` inside a fragment becomes a query.
    """
    var parts = _Parts()
    var bytes = text.as_bytes()
    var n = bytes.__len__()
    var i = 0

    # A scheme is letters, digits and a few marks, starting with a letter, up to
    # a colon. Anything else means there is no scheme, and in particular a colon
    # later in the string does not make one.
    if n > 0 and _is_scheme_start(bytes[0]):
        var j = 0
        while j < n and _is_scheme_byte(bytes[j]):
            j += 1
        if j < n and bytes[j] == UInt8(ord(":")):
            parts.scheme = String(text[byte=0:j])
            i = j + 1

    if (
        i + 1 < n
        and bytes[i] == UInt8(ord("/"))
        and bytes[i + 1] == UInt8(ord("/"))
    ):
        parts.has_authority = True
        i += 2
        var start = i
        while i < n and not (
            bytes[i] == UInt8(ord("/"))
            or bytes[i] == UInt8(ord("?"))
            or bytes[i] == UInt8(ord("#"))
        ):
            i += 1
        var authority = text[byte=start:i]
        _split_authority(authority, parts)

    var path_start = i
    while i < n and not (
        bytes[i] == UInt8(ord("?")) or bytes[i] == UInt8(ord("#"))
    ):
        i += 1
    parts.path = String(text[byte=path_start:i])

    if i < n and bytes[i] == UInt8(ord("?")):
        parts.has_query = True
        i += 1
        var query_start = i
        while i < n and bytes[i] != UInt8(ord("#")):
            i += 1
        parts.query = String(text[byte=query_start:i])

    if i < n and bytes[i] == UInt8(ord("#")):
        parts.has_fragment = True
        parts.fragment = String(text[byte = i + 1 : n])

    return parts^


def _split_authority(authority: StringSpan, mut parts: _Parts) raises:
    """Split `userinfo@host:port`.

    The split is at the *last* `@`, not the first. A `@` inside userinfo has to
    be escaped, but if one arrives unescaped anyway, splitting at the first would
    let it name a different host than the one the rest of the string spells out,
    which is the whole mechanism behind a credential phishing URL.

    Likewise the port is taken from the last `:` outside brackets, because an
    IPv6 literal is full of colons.
    """
    var bytes = authority.as_bytes()
    var n = bytes.__len__()

    var at = -1
    for i in range(n):
        if bytes[i] == UInt8(ord("@")):
            at = i
    var host_start = 0
    if at >= 0:
        parts.has_userinfo = True
        parts.userinfo = String(authority[byte=0:at])
        host_start = at + 1

    # An IPv6 literal is bracketed, and the brackets are part of the host as it
    # is written. Only a colon after the closing bracket can be a port.
    var scan_from = host_start
    if host_start < n and bytes[host_start] == UInt8(ord("[")):
        var close = -1
        for i in range(host_start, n):
            if bytes[i] == UInt8(ord("]")):
                close = i
                break
        if close < 0:
            raise new_error(
                ErrorKind.INVALID_URL,
                String("unclosed bracket in the host of ", _quote(bytes)),
            )
        scan_from = close + 1

    var colon = -1
    for i in range(scan_from, n):
        if bytes[i] == UInt8(ord(":")):
            colon = i
            break
    if colon >= 0:
        parts.host = String(authority[byte=host_start:colon])
        parts.port = String(authority[byte = colon + 1 : n])
    else:
        parts.host = String(authority[byte=host_start:n])


def _parse_port(text: StringSpan) raises -> Optional[UInt16]:
    """A port, or nothing when the field was empty.

    An empty port is legal and means the default, which is why `http://x:/` is
    not an error. Anything non numeric or above 65535 is, because a port that
    does not fit is not a port and silently truncating one sends the request to
    whatever is listening on the remainder.
    """
    if text.byte_length() == 0:
        return Optional[UInt16]()
    var bytes = text.as_bytes()
    var value = 0
    for i in range(bytes.__len__()):
        if bytes[i] < UInt8(ord("0")) or bytes[i] > UInt8(ord("9")):
            raise new_error(
                ErrorKind.INVALID_URL,
                String("port ", _quote(bytes), " is not a number"),
            )
        value = value * 10 + (Int(bytes[i]) - ord("0"))
        if value > 65535:
            raise new_error(
                ErrorKind.INVALID_URL,
                String("port ", _quote(bytes), " is above 65535"),
            )
    return Optional[UInt16](UInt16(value))


def _normalize_host(host: StringSpan) raises -> String:
    """Lowercase and IDNA encode a host, leaving an IPv6 literal alone.

    A bracketed literal is not a name and must not go through IDNA, which would
    reject the colons. It is lowercased because hex digits are case insensitive
    and one spelling is what makes two URLs comparable.
    """
    if host.byte_length() == 0:
        return String("")
    var bytes = host.as_bytes()
    if bytes[0] == UInt8(ord("[")):
        var out = String()
        for i in range(bytes.__len__()):
            out += chr(Int(to_lower(bytes[i])))
        return out^
    # A host may arrive percent encoded, and the escapes have to come out before
    # IDNA sees it, or a label is encoded as the literal text `%C3%BC`.
    var decoded = percent_decode(bytes)
    return encode_host(decoded.to_string())


struct QueryParams(Boolable, Equatable, Movable, Sized, Writable):
    """An immutable, ordered, multi valued query string.

    Immutable because every alternative is worse here. A query string is read far
    more often than it is built, it is shared by every copy of a `URL` that
    derives from it, and a mutable version would hand out references into a list
    that the next `add` reallocates. So `set`, `add`, `remove` and `merge` all
    return a new instance and none of them touch the receiver.

    Keys and values are held decoded. Encoding happens on the way out, once, with
    the strict form set, so a value containing `&` cannot introduce a parameter
    that was not there.
    """

    var _keys: List[String]
    var _values: List[String]

    def __init__(out self):
        self._keys = List[String]()
        self._values = List[String]()

    def __init__(out self, raw: StringSpan) raises:
        """Parse `a=1&b=2`.

        A field with no `=` is a key with an empty value, which is what every
        server does with it, and it round trips as `key=` rather than as `key`.
        Both `&` and `;` used to be separators; only `&` is now, because reading
        `;` as one lets a value containing a semicolon split into two parameters.
        """
        self._keys = List[String]()
        self._values = List[String]()
        var text = raw
        if text.byte_length() > 0 and text.as_bytes()[0] == UInt8(ord("?")):
            text = text[byte = 1 : text.byte_length()]
        if text.byte_length() == 0:
            return
        for field in text.split("&"):
            if field.byte_length() == 0:
                continue
            var bytes = field.as_bytes()
            var eq = -1
            for i in range(bytes.__len__()):
                if bytes[i] == UInt8(ord("=")):
                    eq = i
                    break
            if eq < 0:
                self._keys.append(form_decode(bytes).to_string())
                self._values.append(String())
            else:
                self._keys.append(
                    form_decode(field.as_bytes()[0:eq]).to_string()
                )
                self._values.append(
                    form_decode(
                        field.as_bytes()[eq + 1 : bytes.__len__()]
                    ).to_string()
                )

    def __init__(out self, var items: List[Tuple[String, String]]):
        self._keys = List[String]()
        self._values = List[String]()
        for i in range(len(items)):
            self._keys.append(items[i][0])
            self._values.append(items[i][1])

    def copy(self) -> Self:
        var out = Self()
        out._keys = self._keys.copy()
        out._values = self._values.copy()
        return out^

    def __len__(self) -> Int:
        return len(self._keys)

    def __bool__(self) -> Bool:
        return len(self._keys) > 0

    def __contains__(self, key: StringSpan) -> Bool:
        for i in range(len(self._keys)):
            if self._keys[i] == key:
                return True
        return False

    def __getitem__(self, key: StringSpan) raises -> String:
        """The first value for `key`, raising when there is none.

        First rather than last because that is the order a server reading the
        query sees them in, and disagreeing with the server about which duplicate
        wins is how a request means one thing here and another there.
        """
        for i in range(len(self._keys)):
            if self._keys[i] == key:
                return self._values[i]
        raise new_error(
            ErrorKind.INVALID_URL,
            String("no query parameter named ", _quote(key.as_bytes())),
        )

    def get(self, key: StringSpan, default: StringSpan = "") -> String:
        for i in range(len(self._keys)):
            if self._keys[i] == key:
                return self._values[i]
        return String(default)

    def get_list(self, key: StringSpan) -> List[String]:
        var out = List[String]()
        for i in range(len(self._keys)):
            if self._keys[i] == key:
                out.append(self._values[i])
        return out^

    def keys(self) -> List[String]:
        """Every key, once each, in the order it first appeared."""
        var out = List[String]()
        for i in range(len(self._keys)):
            var seen = False
            for j in range(len(out)):
                if out[j] == self._keys[i]:
                    seen = True
                    break
            if not seen:
                out.append(self._keys[i])
        return out^

    def values(self) -> List[String]:
        """The first value for each key, matching `keys` position for position.
        """
        var out = List[String]()
        for key in self.keys():
            out.append(self.get(key))
        return out^

    def items(self) -> List[Tuple[String, String]]:
        """One pair per key, taking the first value."""
        var out = List[Tuple[String, String]]()
        for key in self.keys():
            out.append((key, self.get(key)))
        return out^

    def multi_items(self) -> List[Tuple[String, String]]:
        """Every pair, including duplicates, in order."""
        var out = List[Tuple[String, String]]()
        for i in range(len(self._keys)):
            out.append((self._keys[i], self._values[i]))
        return out^

    def set(self, key: StringSpan, value: StringSpan) -> Self:
        """A copy with `key` present exactly once.

        The replacement goes where the first occurrence was rather than at the
        end, because parameter order is visible to the server and moving one is a
        change nobody asked for.
        """
        var out = Self()
        var placed = False
        for i in range(len(self._keys)):
            if self._keys[i] == key:
                if not placed:
                    out._keys.append(String(key))
                    out._values.append(String(value))
                    placed = True
                continue
            out._keys.append(self._keys[i])
            out._values.append(self._values[i])
        if not placed:
            out._keys.append(String(key))
            out._values.append(String(value))
        return out^

    def add(self, key: StringSpan, value: StringSpan) -> Self:
        var out = self.copy()
        out._keys.append(String(key))
        out._values.append(String(value))
        return out^

    def remove(self, key: StringSpan) -> Self:
        var out = Self()
        for i in range(len(self._keys)):
            if self._keys[i] == key:
                continue
            out._keys.append(self._keys[i])
            out._values.append(self._values[i])
        return out^

    def merge(self, other: Self) -> Self:
        """A copy with every key of `other` set, replacing what was there.

        Set rather than add, so merging the same parameters twice gives what
        merging them once gave.
        """
        var out = self.copy()
        for pair in other.multi_items():
            out = out.set(pair[0], pair[1])
        return out^

    def __eq__(self, other: Self) -> Bool:
        """Order insensitive, multiplicity sensitive.

        `a=1&b=2` and `b=2&a=1` request the same thing, so they compare equal.
        `a=1&a=1` and `a=1` do not, because a server reading a repeated parameter
        can tell the difference and some of them act on it.
        """
        if len(self._keys) != len(other._keys):
            return False
        for i in range(len(self._keys)):
            if self._count(self._keys[i], self._values[i]) != other._count(
                self._keys[i], self._values[i]
            ):
                return False
        return True

    def __ne__(self, other: Self) -> Bool:
        return not (self == other)

    def _count(self, key: StringSpan, value: StringSpan) -> Int:
        var total = 0
        for i in range(len(self._keys)):
            if self._keys[i] == key and self._values[i] == value:
                total += 1
        return total

    def encode(self) raises -> String:
        """Serialize back to `a=1&b=2`, each part strictly encoded."""
        var out = String()
        for i in range(len(self._keys)):
            if i > 0:
                out += "&"
            out += form_encode(self._keys[i].as_bytes()).to_string()
            out += "="
            out += form_encode(self._values[i].as_bytes()).to_string()
        return out^

    def write_to[W: Writer](self, mut writer: W):
        # `write_to` cannot raise, and encoding cannot fail on values that were
        # decoded on the way in, so the fallback is unreachable rather than
        # merely unlikely. It exists because the compiler needs it to.
        try:
            writer.write(self.encode())
        except:
            writer.write("")


struct URL(Equatable, Movable, Writable):
    """A parsed, normalized URL.

    The bytes are the source of truth and the ranges index into them. Every
    component is stored in the form it goes on the wire in, so building a request
    is slicing rather than encoding.

    The backing store is `Bytes` rather than `String` because that is what the
    accessors that matter hand out. Returning a view of a `String` would mean
    reconstructing one from bytes at the boundary, and the only way to do that
    without a UTF-8 check is an unsafe call, which does not belong in this layer.
    """

    var _raw: Bytes
    var _scheme: Range
    var _userinfo: Range
    var _host: Range
    var _port: Optional[UInt16]
    var _path: Range
    var _query: Range
    var _fragment: Range
    var _has_authority: Bool
    var _has_query: Bool
    var _has_fragment: Bool

    def __init__(out self, url: StringSpan) raises:
        var parts = _split(url)
        self = Self._from_parts(parts)

    def __init__(out self):
        self._raw = Bytes()
        self._scheme = Range(0, 0)
        self._userinfo = Range(0, 0)
        self._host = Range(0, 0)
        self._port = Optional[UInt16]()
        self._path = Range(0, 0)
        self._query = Range(0, 0)
        self._fragment = Range(0, 0)
        self._has_authority = False
        self._has_query = False
        self._has_fragment = False

    @staticmethod
    def _from_parts(parts: _Parts) raises -> Self:
        """Normalize the pieces and lay them out as one string.

        The order here is the order in section 5 of `03-url.md` and it matters.
        The host is IDNA encoded before the port is compared against the scheme
        default, and dot segments come out before the path is percent normalized,
        because normalizing first could produce a `%2E` that then fails to be
        recognised as a dot segment. That last one is the difference between
        removing a `/../` and leaving it in for the next hop to act on.
        """
        var out = Self()

        var scheme = String()
        for byte in parts.scheme.as_bytes():
            scheme += chr(Int(to_lower(byte)))

        var host = _normalize_host(parts.host)
        var port = _parse_port(parts.port)
        var default = default_port_for(scheme)
        if port and default and port.value() == default.value():
            port = Optional[UInt16]()

        var userinfo = String()
        if parts.has_userinfo:
            # The first colon separates the user from the password and has to
            # stay literal, but the USERINFO set escapes colons, so normalizing
            # the field as one string would escape the separator too and it
            # could never be found again. Each side is normalized on its own and
            # the separator is written back in. Any further colon is part of the
            # password and does get escaped, which is what stops a password from
            # moving the host when the URL is parsed a second time.
            var info = parts.userinfo.as_bytes()
            var sep = -1
            for i in range(info.__len__()):
                if info[i] == UInt8(ord(":")):
                    sep = i
                    break
            if sep < 0:
                userinfo = percent_normalize(info, USERINFO).to_string()
            else:
                userinfo = percent_normalize(info[0:sep], USERINFO).to_string()
                userinfo += ":"
                userinfo += percent_normalize(
                    info[sep + 1 : info.__len__()], USERINFO
                ).to_string()

        var path = String(parts.path)
        # An absolute URL addresses the root when no path is written, and saying
        # so here means the request target never has to special case it.
        if parts.has_authority and path.byte_length() == 0:
            path = String("/")
        if path.byte_length() > 0:
            path = remove_dot_segments(path)
            path = percent_normalize(path.as_bytes(), PATH).to_string()

        var query = String()
        if parts.has_query:
            query = percent_normalize(parts.query.as_bytes(), QUERY).to_string()

        var fragment = String()
        if parts.has_fragment:
            fragment = percent_normalize(
                parts.fragment.as_bytes(), FRAGMENT
            ).to_string()

        var raw = String()
        out._scheme = Range(0, scheme.byte_length())
        if scheme.byte_length() > 0:
            raw += scheme
            raw += ":"

        out._has_authority = parts.has_authority
        if parts.has_authority:
            raw += "//"
            if parts.has_userinfo:
                out._userinfo = Range(
                    raw.byte_length(),
                    raw.byte_length() + userinfo.byte_length(),
                )
                raw += userinfo
                raw += "@"
            else:
                out._userinfo = Range(raw.byte_length(), raw.byte_length())
            out._host = Range(
                raw.byte_length(), raw.byte_length() + host.byte_length()
            )
            raw += host
            if port:
                raw += ":"
                raw += String(Int(port.value()))
        else:
            out._userinfo = Range(raw.byte_length(), raw.byte_length())
            out._host = Range(raw.byte_length(), raw.byte_length())

        out._port = port
        out._path = Range(
            raw.byte_length(), raw.byte_length() + path.byte_length()
        )
        raw += path

        out._has_query = parts.has_query
        if parts.has_query:
            raw += "?"
            out._query = Range(
                raw.byte_length(), raw.byte_length() + query.byte_length()
            )
            raw += query
        else:
            out._query = Range(raw.byte_length(), raw.byte_length())

        out._has_fragment = parts.has_fragment
        if parts.has_fragment:
            raw += "#"
            out._fragment = Range(
                raw.byte_length(), raw.byte_length() + fragment.byte_length()
            )
            raw += fragment
        else:
            out._fragment = Range(raw.byte_length(), raw.byte_length())

        out._raw = Bytes(raw)
        return out^

    def copy(self) -> Self:
        var out = Self()
        out._raw = self._raw.copy()
        out._scheme = self._scheme
        out._userinfo = self._userinfo
        out._host = self._host
        out._port = self._port
        out._path = self._path
        out._query = self._query
        out._fragment = self._fragment
        out._has_authority = self._has_authority
        out._has_query = self._has_query
        out._has_fragment = self._has_fragment
        return out^

    def _slice(
        ref self, start: Int, end: Int
    ) -> Span[UInt8, origin_of(self._raw._data)]:
        """A view of one component.

        Takes plain offsets rather than a `Range` because a borrowed `self` and a
        borrowed field of that same `self` alias, and the compiler rejects the
        pair. Copying two integers out first is what breaks the alias.
        """
        return self._raw.as_span()[start:end]

    def _text(self, r: Range) -> String:
        """A component as text.

        Sound without a UTF-8 check only because every component reaches `_raw`
        already percent normalized, and normalization escapes every byte outside
        printable ASCII. There is nothing in here that is not ASCII.
        """
        var out = String()
        var span = self._raw.as_span()
        for i in range(Int(r.start), Int(r.end)):
            out += chr(Int(span[i]))
        return out^

    def scheme(self) -> String:
        """Lowercased, as stored."""
        return self._text(self._scheme)

    def raw_scheme(ref self) -> Span[UInt8, origin_of(self._raw._data)]:
        return self._slice(Int(self._scheme.start), Int(self._scheme.end))

    def raw_host(ref self) -> Span[UInt8, origin_of(self._raw._data)]:
        """The A-label host, which is what goes in `Host` and into DNS."""
        return self._slice(Int(self._host.start), Int(self._host.end))

    def host(self) raises -> String:
        """The Unicode host, for showing a person.

        Never use this to decide where a request goes or what a cookie covers.
        Two different A-labels can present identically to a reader, so a decision
        made on this form is a decision made on something an attacker chooses.
        """
        return decode_host(self._text(self._host))

    def userinfo(ref self) -> Span[UInt8, origin_of(self._raw._data)]:
        return self._slice(Int(self._userinfo.start), Int(self._userinfo.end))

    def username(self) raises -> String:
        var span = self._slice(
            Int(self._userinfo.start), Int(self._userinfo.end)
        )
        for i in range(span.__len__()):
            if span[i] == UInt8(ord(":")):
                return percent_decode(span[0:i]).to_string()
        return percent_decode(span).to_string()

    def password(self) raises -> String:
        var span = self._slice(
            Int(self._userinfo.start), Int(self._userinfo.end)
        )
        for i in range(span.__len__()):
            if span[i] == UInt8(ord(":")):
                return percent_decode(span[i + 1 : span.__len__()]).to_string()
        return String()

    def port(self) -> Optional[UInt16]:
        """The port, or nothing when it is the scheme default."""
        return self._port

    def effective_port(self) -> Optional[UInt16]:
        """The port to actually connect to, filling in the scheme default."""
        if self._port:
            return self._port
        return default_port_for(self.scheme())

    def netloc(self) -> String:
        """`host:port`, with the port only when it is not the default."""
        var out = self._text(self._host)
        if self._port:
            out += ":"
            out += String(Int(self._port.value()))
        return out^

    def authority(self) -> String:
        """`userinfo@host:port`.

        The credentials are part of the parsed authority, so they are here. What
        goes in a log line is `netloc`, which is not.
        """
        var out = String()
        if not self._userinfo.is_empty():
            out += self._text(self._userinfo)
            out += "@"
        out += self.netloc()
        return out^

    def raw_path(self) -> String:
        """The request target: path plus query, encoded, ready to send.

        An empty path becomes `/` here even on a relative URL, because a request
        line with an empty target is malformed.
        """
        var out = self._text(self._path)
        if out.byte_length() == 0:
            out = String("/")
        if self._has_query:
            out += "?"
            out += self._text(self._query)
        return out^

    def path(self) raises -> String:
        """The decoded path."""
        return percent_decode(
            self._slice(Int(self._path.start), Int(self._path.end))
        ).to_string()

    def raw_query(ref self) -> Span[UInt8, origin_of(self._raw._data)]:
        return self._slice(Int(self._query.start), Int(self._query.end))

    def params(self) raises -> QueryParams:
        return QueryParams(self._text(self._query))

    def fragment(self) raises -> String:
        return percent_decode(
            self._slice(Int(self._fragment.start), Int(self._fragment.end))
        ).to_string()

    def is_absolute_url(self) -> Bool:
        return not self._scheme.is_empty() and not self._host.is_empty()

    def is_relative_url(self) -> Bool:
        return not self.is_absolute_url()

    def is_ssl(self) -> Bool:
        var scheme = self.scheme()
        return scheme == "https" or scheme == "wss"

    def __eq__(self, other: Self) -> Bool:
        """Two URLs are equal when their normalized forms are.

        This is only sound because normalization is total and idempotent. Every
        component that has a preferred spelling is put into it at construction,
        so there is nothing left for a comparison to have to know about.
        """
        if len(self._raw) != len(other._raw):
            return False
        for i in range(len(self._raw)):
            if self._raw[i] != other._raw[i]:
                return False
        return True

    def __ne__(self, other: Self) -> Bool:
        return not (self == other)

    def __str__(self) -> String:
        var out = String()
        var span = self._raw.as_span()
        for i in range(span.__len__()):
            out += chr(Int(span[i]))
        return out^

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.__str__())

    def join(self, relative: StringSpan) raises -> Self:
        """Resolve `relative` against this URL. RFC 3986 section 5.3.

        This is what turns a `Location` header into somewhere to go next, so it
        is the function a redirect chain runs through. Two properties matter more
        than the rest. A reference with its own scheme and authority replaces
        this URL entirely, which is how a redirect can legitimately leave the
        host. And a reference with a path is merged and then has its dot segments
        removed, so it cannot climb out of the base, which is how it cannot leave
        the host by accident.

        The base must be absolute. Resolving against a relative base has no
        defined answer, and picking one would mean guessing at a host.
        """
        if not self.is_absolute_url():
            raise new_error(
                ErrorKind.INVALID_URL,
                String(
                    "cannot resolve ",
                    _quote(relative.as_bytes()),
                    " against the relative URL ",
                    _quote(self._raw.as_span()),
                ),
            )

        var ref_parts = _split(relative)
        var out = _Parts()

        if ref_parts.scheme.byte_length() > 0:
            out = ref_parts^
        else:
            out.scheme = self.scheme()
            if ref_parts.has_authority:
                out.has_authority = True
                out.has_userinfo = ref_parts.has_userinfo
                out.userinfo = ref_parts.userinfo
                out.host = ref_parts.host
                out.port = ref_parts.port
                out.path = ref_parts.path
                out.has_query = ref_parts.has_query
                out.query = ref_parts.query
            else:
                out.has_authority = self._has_authority
                out.has_userinfo = not self._userinfo.is_empty()
                out.userinfo = self._text(self._userinfo)
                out.host = self._text(self._host)
                if self._port:
                    out.port = String(Int(self._port.value()))

                if ref_parts.path.byte_length() == 0:
                    out.path = self._text(self._path)
                    # An empty reference path keeps the base query, but only when
                    # the reference has no query of its own. `?x` replaces it and
                    # `` keeps it, which is the distinction has_query records.
                    if ref_parts.has_query:
                        out.has_query = True
                        out.query = ref_parts.query
                    else:
                        out.has_query = self._has_query
                        out.query = self._text(self._query)
                else:
                    out.has_query = ref_parts.has_query
                    out.query = ref_parts.query
                    if ref_parts.path.as_bytes()[0] == UInt8(ord("/")):
                        out.path = ref_parts.path
                    else:
                        out.path = _merge_paths(
                            self._text(self._path),
                            self._has_authority,
                            ref_parts.path,
                        )
            out.has_fragment = ref_parts.has_fragment
            out.fragment = ref_parts.fragment

        return Self._from_parts(out)

    def copy_with(
        self,
        *,
        scheme: Optional[String] = None,
        username: Optional[String] = None,
        password: Optional[String] = None,
        host: Optional[String] = None,
        port: Optional[Int] = None,
        raw_path: Optional[String] = None,
        query: Optional[String] = None,
        fragment: Optional[String] = None,
    ) raises -> Self:
        """A copy with the named components replaced.

        Everything not named is carried over in the form it is already in, so
        changing a port does not re-encode a path. The result is normalized like
        any other, which means a change that makes two URLs equal really does
        make them equal.
        """
        var parts = _Parts()
        parts.scheme = scheme.value() if scheme else self.scheme()

        var user = username.value() if username else self.username()
        var secret = password.value() if password else self.password()
        parts.has_userinfo = user.byte_length() > 0 or secret.byte_length() > 0
        if parts.has_userinfo:
            # Re-encoded rather than copied, because these arrive decoded and a
            # colon in a password would otherwise move the host.
            parts.userinfo = percent_encode(
                user.as_bytes(), USERINFO
            ).to_string()
            if secret.byte_length() > 0:
                parts.userinfo += ":"
                parts.userinfo += percent_encode(
                    secret.as_bytes(), USERINFO
                ).to_string()

        parts.host = host.value() if host else self._text(self._host)
        parts.has_authority = (
            parts.host.byte_length() > 0 or self._has_authority
        )
        if port:
            parts.port = String(port.value())
        elif not port and self._port and not host:
            parts.port = String(Int(self._port.value()))

        parts.path = raw_path.value() if raw_path else self._text(self._path)

        if query:
            parts.has_query = True
            parts.query = query.value()
        else:
            parts.has_query = self._has_query
            parts.query = self._text(self._query)

        if fragment:
            parts.has_fragment = True
            parts.fragment = fragment.value()
        else:
            parts.has_fragment = self._has_fragment
            parts.fragment = self._text(self._fragment)

        return Self._from_parts(parts)

    def copy_set_param(self, key: StringSpan, value: StringSpan) raises -> Self:
        return self.copy_with(query=self.params().set(key, value).encode())

    def copy_add_param(self, key: StringSpan, value: StringSpan) raises -> Self:
        return self.copy_with(query=self.params().add(key, value).encode())

    def copy_remove_param(self, key: StringSpan) raises -> Self:
        return self.copy_with(query=self.params().remove(key).encode())

    def copy_merge_params(self, params: QueryParams) raises -> Self:
        return self.copy_with(query=self.params().merge(params).encode())


def _merge_paths(
    base: StringSpan, base_has_authority: Bool, reference: StringSpan
) raises -> String:
    """RFC 3986 section 5.2.3.

    The reference replaces everything after the last slash of the base, which is
    why `a/b` resolved against `/x/y` gives `/x/a/b` and not `/x/y/a/b`. The
    special case for an authority with an empty path is the RFC's own, and
    without it a reference against `http://example.com` loses its leading slash.
    """
    if base_has_authority and base.byte_length() == 0:
        return String("/", reference)
    var bytes = base.as_bytes()
    var last_slash = -1
    for i in range(bytes.__len__()):
        if bytes[i] == UInt8(ord("/")):
            last_slash = i
    if last_slash < 0:
        return String(reference)
    return String(base[byte = 0 : last_slash + 1], reference)
