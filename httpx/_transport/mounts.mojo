"""Which transport a request goes to, decided by its URL.

A client has one transport, and `mounts` is how it gets more than one. Each
entry pairs a URL pattern with a transport, the client matches the request's URL
against the patterns from most specific to least, and the first one that matches
wins. Nothing matched means the client's own transport.

This is what makes mixed traffic possible: some hosts through a proxy and the
rest direct, one domain answered by a mock while everything else goes out for
real, a scheme refused outright. All of those are the same mechanism with a
different transport on the far side of it.

## Why `proxy=` is a mount underneath

`Client(proxy=...)` builds a proxied transport and mounts it on `all://`. The
client's own transport is the unproxied one, always. That arrangement is not an
implementation detail that could have gone either way: it is the only one where
an entry saying "no transport for this pattern" means anything useful. Falling
back to the client's transport is the way out of a proxy, and if the client's
transport were itself the proxied one there would be no way out.

httpx does the same, and the `NO_PROXY` handling that comes next depends on it.

## The pattern language

`all://` matches everything. Otherwise the scheme, the host and the port are
each optional, and an omitted one matches anything:

    all://                  every request
    http://                 every http request
    all://example.com       that host, on any scheme, on any port
    https://example.com     that host over TLS
    all://*.example.com     strict subdomains, so not example.com itself
    all://*example.com      example.com and its subdomains
    all://*:8080            anything on port 8080
    https://example.com:444 all three
    all://10.0.0.0/8        every address in that range
    all://[fd00::]/8        the same for IPv6

A host that is an address is compared as a number rather than as text, so
`all://127.0.0.1` matches a URL written `http://0177.0.0.1/` as well, which is
the same address to every resolver on the machine. A prefix length is the only
thing allowed after the authority, since anything else there is a path and a
path is not something routing can act on.

A pattern has to be written as a URL and not as a bare scheme, so `http://` and
not `http`. The trailing slashes are not decoration: `http` alone is ambiguous
between a scheme and a host, and httpx rejects it for the same reason.

## The order they are tried in

Most specific first, and specific is defined the way httpx defines it: a pattern
naming a port beats one that does not, then a longer host beats a shorter one,
then a longer scheme beats a shorter one. Patterns that tie are tried in the
order they were added.

Two patterns that both name a range are ordered by prefix length instead, the
tighter one first, which httpx has nothing to say about because httpx has no
ranges. Ordering those by host length would sort them by how the network
address happens to be spelled.

The host rule is length on the host as written, `*` included, which is what
makes `all://*.example.com` beat `all://example.com`. That is worth knowing
because it is not what a reader would guess: the more specific looking exact
host loses to the wildcard. It is httpx's ordering and changing it here would
mean a configuration copied over from httpx routing somewhere else.
"""

from httpx._exceptions import ErrorKind, new_error
from httpx._models.url import URL, default_port_for
from httpx._transport.handle import TransportHandle
from httpx._util.ip import IpAddress, in_network, parse_ip_address


struct URLPattern(ImplicitlyCopyable, Movable, Writable):
    """One `mounts` key, parsed.

    Parsed by hand rather than through `URL`, because these are not URLs. A
    pattern host can be `*.example.com`, which no URL parser should accept, and
    running one through IDNA and percent decoding on the way in would either
    reject it or quietly turn it into something else.
    """

    var pattern: String
    """The text it was built from, kept for messages and for identity."""

    var scheme: String
    """The scheme it demands, and empty for any scheme."""

    var host: String
    """The host as written, wildcard included, and empty for any host.

    As written rather than as matched, because the ordering rule measures this
    and the leading `*` counts. `_suffix` is the part that is actually compared.
    """

    var port: Optional[UInt16]
    """The port it demands, and nothing for any port."""

    var subdomains: Bool
    """Whether the host was written with a leading `*`."""

    var strict: Bool
    """Whether that `*` was `*.`, which excludes the domain itself."""

    var _suffix: String
    """`host` with the wildcard removed, lowercased, brackets stripped.

    Empty when the host is an address, since those are compared as numbers.
    """

    var network: IpAddress
    """The address the host names, and family 0 when the host is a name."""

    var prefix: Int
    """How many bits of `network` have to match, and -1 when there is none.

    An address written on its own gets the whole width, so an exact address and
    a range are the same comparison with a different number in it.
    """

    def __init__(out self, pattern: StringSpan) raises:
        """Parse `pattern`, raising if it is not one.

        Raising rather than matching nothing. A pattern that is a typo is a
        mount that never fires, and a mount that never fires looks exactly like
        a proxy that is not working, which is a bad afternoon.
        """
        self.pattern = String(pattern)
        self.scheme = String()
        self.host = String()
        self.port = None
        self.subdomains = False
        self.strict = False
        self._suffix = String()
        self.network = IpAddress()
        self.prefix = -1

        var text = String(pattern)
        if text == "":
            # Matches everything, the same as `all://`. Not something anybody
            # would write by hand, and the environment variable reader builds it.
            return

        var mark = text.find("://")
        if mark < 0:
            raise new_error(
                ErrorKind.INVALID_ARGUMENT,
                String(
                    "'",
                    text,
                    (
                        "' is not a mount pattern, which has to be written as a"
                        " URL rather than as a bare scheme: try '"
                    ),
                    text,
                    "://'",
                ),
            )

        var scheme = String(text[byte=0:mark]).lower()
        if scheme != "all":
            self.scheme = scheme^
        var rest = String(text[byte = mark + 3 :])

        var slash = rest.find("/")
        if slash >= 0:
            # The one thing that can follow the authority is a prefix length,
            # which is a range of addresses rather than a path. Anything else
            # would match nothing extra and hide everything the pattern was
            # meant to narrow, since routing looks at the scheme, the host and
            # the port and never at the path.
            self.prefix = _prefix_bits(String(rest[byte = slash + 1 :]))
            if self.prefix < 0:
                raise new_error(
                    ErrorKind.INVALID_ARGUMENT,
                    String(
                        "the mount pattern '",
                        text,
                        (
                            "' has a path on it, and routing only looks at the"
                            " scheme, the host and the port"
                        ),
                    ),
                )
            var head = String(rest[byte=0:slash])
            rest = head^

        if not rest.startswith("[") and _colons(rest) > 1:
            # Without brackets there is no telling an IPv6 address from a host
            # and a port, and the reading that wins would be the wrong one:
            # `::1` would parse as the host `:` on port 1 and match nothing ever.
            raise new_error(
                ErrorKind.INVALID_ARGUMENT,
                String(
                    "the IPv6 address in the mount pattern '",
                    text,
                    (
                        "' needs brackets round it, so that a port can be told"
                        " apart from the address"
                    ),
                ),
            )

        var host = rest
        var colon = _port_mark(rest)
        if colon >= 0:
            var digits = String(rest[byte = colon + 1 :])
            self.port = _port_value(digits, text)
            host = String(rest[byte=0:colon])
            # A port that the scheme implies anyway is dropped, because a URL
            # never carries one: `https://example.com:443/` parses with no port
            # on it, so a pattern that insisted on 443 would match nothing at
            # all. Somebody who writes the port they know the scheme uses means
            # every request on that scheme, and this is how they get it.
            if self.scheme != "":
                var implied = default_port_for(self.scheme)
                if implied and implied.value() == self.port.value():
                    self.port = None

        if host == "" or host == "*":
            if self.prefix >= 0:
                raise new_error(
                    ErrorKind.INVALID_ARGUMENT,
                    String(
                        "the mount pattern '",
                        text,
                        (
                            "' has a prefix length on nothing, and a prefix"
                            " length needs an address in front of it"
                        ),
                    ),
                )
            return

        self.host = host.copy()
        var matched = host.lower()
        if matched.startswith("*."):
            self.subdomains = True
            self.strict = True
            var tail = String(matched[byte=2:])
            matched = tail^
        elif matched.startswith("*"):
            self.subdomains = True
            var tail = String(matched[byte=1:])
            matched = tail^

        if not self.subdomains:
            # Addresses are compared as numbers rather than as text, so the two
            # spellings of one address are one host here. `0177.0.0.1` and
            # `127.0.0.1` reach the same machine and a pattern written with one
            # of them has to match a URL written with the other.
            self.network = parse_ip_address(matched)
        if self.network.family == 0:
            if self.prefix >= 0:
                raise new_error(
                    ErrorKind.INVALID_ARGUMENT,
                    String(
                        "the mount pattern '",
                        text,
                        (
                            "' has a prefix length on something that is not an"
                            " IP address"
                        ),
                    ),
                )
            self._suffix = _bare_host(matched)
            return

        if self.prefix < 0:
            self.prefix = self.network.bits()
        elif self.prefix > self.network.bits():
            raise new_error(
                ErrorKind.INVALID_ARGUMENT,
                String(
                    "the mount pattern '",
                    text,
                    "' has a prefix length above ",
                    self.network.bits(),
                ),
            )

    def matches(self, url: URL) raises -> Bool:
        """Whether a request for `url` should go to whatever this is mounted on.
        """
        if self.scheme != "" and self.scheme != url.scheme():
            return False

        if self.port:
            # `url.port()` is empty when the port is the scheme's default, so
            # `https://example.com:443` is written by a caller who wants every
            # ordinary https request rather than only the ones spelled with a
            # port. That is httpx's reading of it too.
            var given = url.port()
            if not given or given.value() != self.port.value():
                return False

        if self.prefix >= 0:
            return in_network(
                parse_ip_address(StringSpan(from_utf8=url.raw_host())),
                self.network,
                self.prefix,
            )

        if self._suffix == "":
            return True

        var host = _bare_host(
            String(StringSpan(from_utf8=url.raw_host())).lower()
        )
        if not self.subdomains:
            return host == self._suffix
        if host == self._suffix:
            return not self.strict
        return host.endswith(String(".", self._suffix))

    def beats(self, other: Self) -> Bool:
        """Whether this pattern is tried before `other`.

        Ties answer False both ways, which is what keeps the order things were
        added in when two patterns are equally specific.
        """
        var mine = 0 if self.port else 1
        var theirs = 0 if other.port else 1
        if mine != theirs:
            return mine < theirs
        if self.prefix >= 0 and other.prefix >= 0:
            # Two ranges, so the tighter one first. Nothing in httpx to copy
            # here, because httpx has no ranges, and host length would order
            # these by how the network address happens to be spelled.
            if self.prefix != other.prefix:
                return self.prefix > other.prefix
        var mine_host = self.host.byte_length()
        var their_host = other.host.byte_length()
        if mine_host != their_host:
            return mine_host > their_host
        return self.scheme.byte_length() > other.scheme.byte_length()

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.pattern)


def _colons(rest: String) -> Int:
    var seen = 0
    for byte in rest.as_bytes():
        if byte == UInt8(ord(":")):
            seen += 1
    return seen


def _port_mark(rest: String) -> Int:
    """Where the `:port` starts in `rest`, or -1.

    Searched from the end and only accepted when what follows is digits, so the
    colons inside an IPv6 literal are not mistaken for a port.
    """
    var at = rest.rfind(":")
    if at < 0:
        return -1
    var close = rest.rfind("]")
    if close >= 0 and at < close:
        return -1
    if at + 1 >= rest.byte_length():
        return -1
    var digits = rest[byte = at + 1 :]
    for byte in digits.as_bytes():
        if byte < UInt8(ord("0")) or byte > UInt8(ord("9")):
            return -1
    return at


def _port_value(digits: String, pattern: String) raises -> Optional[UInt16]:
    var value = 0
    for byte in digits.as_bytes():
        value = value * 10 + Int(byte - UInt8(ord("0")))
        if value > 65535:
            raise new_error(
                ErrorKind.INVALID_ARGUMENT,
                String(
                    "the mount pattern '",
                    pattern,
                    "' names a port above 65535",
                ),
            )
    return Optional[UInt16](UInt16(value))


def _prefix_bits(text: String) -> Int:
    """The `/16` of a pattern as a number, or -1 when it is not one.

    Three digits at most, which is enough for 128 and keeps `/2016` a path
    rather than a prefix length nobody could have meant. Whether the number
    fits the address is the caller's question, because the answer depends on
    which family the address is and the message should say so.
    """
    if text == "" or text.byte_length() > 3:
        return -1
    var value = 0
    for byte in text.as_bytes():
        if byte < UInt8(ord("0")) or byte > UInt8(ord("9")):
            return -1
        value = value * 10 + Int(byte - UInt8(ord("0")))
    return value


def _bare_host(host: String) -> String:
    """An IPv6 literal without its brackets, and anything else unchanged.

    Both sides of a comparison go through this, so it does not matter whether
    the caller wrote `all://[::1]` or `all://::1`.
    """
    if host.startswith("[") and host.endswith("]") and host.byte_length() > 2:
        return String(host[byte = 1 : host.byte_length() - 1])
    return host.copy()


struct Mount[H: TransportHandle](Movable):
    """One pattern and where it sends what it matches."""

    var pattern: URLPattern

    var transport: Optional[Self.H]
    """Where the request goes, and nothing to send it where it would have gone.

    The empty case is httpx's `None` and it means the client's own transport,
    which is the unproxied one. It is the way to carve an exception out of a
    broader mount rather than a way to refuse a request. Refusing is a transport
    that raises, which `httpx._transport.blocked` provides.
    """

    def __init__(
        out self, var pattern: URLPattern, var transport: Optional[Self.H]
    ):
        self.pattern = pattern^
        self.transport = transport^


struct Mounts[H: TransportHandle](Movable, Sized):
    """A routing table, kept in the order it will be searched.

    Sorted on insert rather than at the end, so there is no step a caller can
    forget and no window where the table is built but not yet usable.
    """

    var entries: List[Mount[Self.H]]

    def __init__(out self):
        self.entries = List[Mount[Self.H]]()

    def __len__(self) -> Int:
        return len(self.entries)

    def mount(mut self, pattern: StringSpan, var transport: Self.H) raises:
        """Send everything matching `pattern` to `transport`.

        Mounting the same pattern twice replaces the first one, which is what a
        dictionary literal would do in httpx.
        """
        self._add(URLPattern(pattern), Optional[Self.H](transport^))

    def bypass(mut self, pattern: StringSpan) raises:
        """Send everything matching `pattern` to the client's own transport.

        This is httpx's `mounts={"...": None}`, and it exists to punch a hole in
        a wider mount. `Client(proxy=...)` mounts the proxy on `all://`, so
        `bypass("all://example.com")` is how one host goes direct while the rest
        keep going through the proxy. On a client with no proxy it changes
        nothing, because the client's own transport is where an unmatched
        request was going anyway.

        Not to be confused with refusing a request. `httpx._transport.blocked`
        is that, and the two are separate because a hole in a proxy rule and a
        wall are not the same instruction.
        """
        self._add(URLPattern(pattern), None)

    def extend(mut self, var other: Self):
        """Add every mount in `other`, later ones winning a repeated pattern."""
        while len(other.entries) > 0:
            self._add_entry(other.entries.pop(0))

    def route_for(self, url: URL) raises -> Int:
        """Which entry handles `url`, or -1 for the client's own transport.

        An index rather than the transport itself, because Mojo has no way to
        return a reference that is sometimes into one field and sometimes into
        another, and because the caller has to be able to tell "this mount"
        from "no mount" without a second call.
        """
        for i in range(len(self.entries)):
            if self.entries[i].pattern.matches(url):
                if self.entries[i].transport:
                    return i
                return -1
        return -1

    def close(mut self):
        """Close every transport mounted here."""
        for i in range(len(self.entries)):
            if self.entries[i].transport:
                self.entries[i].transport.value().close()

    def _add(
        mut self, var pattern: URLPattern, var transport: Optional[Self.H]
    ):
        self._add_entry(Mount[Self.H](pattern^, transport^))

    def _add_entry(mut self, var entry: Mount[Self.H]):
        """Put `entry` where the search order says it goes.

        Whole entries move rather than their fields, because Mojo will not let a
        field be taken out of the middle of a value that still has to be
        destroyed. Replacing a repeated pattern therefore swaps the entry rather
        than its transport, which comes to the same thing since the two patterns
        are the same text.
        """
        for i in range(len(self.entries)):
            if self.entries[i].pattern.pattern == entry.pattern.pattern:
                self.entries[i] = entry^
                return

        var at = len(self.entries)
        for i in range(len(self.entries)):
            if entry.pattern.beats(self.entries[i].pattern):
                at = i
                break
        self.entries.insert(at, entry^)
