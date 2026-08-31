"""What decides whether two requests can share a connection.

Scheme, host and port, and nothing else. The path is not part of it, the query
is not part of it, and neither is anything about the request, because a
connection to `example.com:443` carries any request to that host equally well.

Getting the comparison wrong in the lenient direction is a security bug rather
than a performance one. Two origins that compare equal share a connection, and a
connection that has been authenticated to one server must never carry a request
meant for another. So the port is always explicit, the host is always compared
in its normalised form, and `http` and `https` on the same host and port are
still two different origins.
"""

from httpx._exceptions import ErrorKind, new_error
from httpx._models.url import URL, default_port_for


struct Origin(Equatable, ImplicitlyCopyable, Movable, Writable):
    """A scheme, a host and a port that a connection can be pooled under."""

    var scheme: String
    """Lowercased, and only ever `http` or `https` on a pooled connection."""

    var host: String
    """The host exactly as it will be handed to the resolver.

    Which means the A-label form of an internationalised name, lowercased, and
    an IPv6 literal with its brackets taken off. The brackets belong to the URL
    syntax that has to separate the address from the port, and passing them to
    a name lookup would look up a name that does not exist.

    Deliberately not the Unicode form. Two different names can present
    identically to a reader, so keying a connection on what a host looks like
    rather than on what it resolves to would let one of them be served a
    connection opened for the other."""

    var port: UInt16
    """Always explicit. A URL that left the port out has had the scheme default
    filled in, so `https://example.com` and `https://example.com:443` are one
    origin rather than two."""

    def __init__(out self, var scheme: String, var host: String, port: UInt16):
        self.scheme = scheme^
        self.host = host^
        self.port = port

    def __eq__(self, other: Self) -> Bool:
        return (
            self.port == other.port
            and self.scheme == other.scheme
            and self.host == other.host
        )

    def __ne__(self, other: Self) -> Bool:
        return not self == other

    def is_secure(self) -> Bool:
        return self.scheme == "https"

    def is_ipv6_literal(self) -> Bool:
        # A name cannot contain a colon and an IPv6 address always does, so one
        # byte is the whole test.
        return ":" in self.host

    def write_to[W: Writer](self, mut writer: W):
        """`https://example.com:443`, which is what a user should see in an
        error. The port is shown even when it is the default, because an error
        about a connection should say exactly what was connected to, and an
        address gets its brackets back so that the port is still readable."""
        writer.write(self.scheme, "://")
        if self.is_ipv6_literal():
            writer.write("[", self.host, "]")
        else:
            writer.write(self.host)
        writer.write(":", self.port)


def origin_for(url: URL) raises -> Origin:
    """The origin a request to `url` belongs to.

    Raises rather than guessing when the URL cannot be routed. A relative URL
    has no host to connect to and a scheme this library does not speak has no
    connection to make, and in both cases the caller has made a mistake that no
    default can repair.
    """
    var scheme = url.scheme()
    if scheme == "":
        # A relative URL. Checked before the scheme is judged, because telling
        # somebody that the empty scheme is unsupported is a worse answer than
        # telling them the URL was relative, which is the mistake they made.
        raise new_error(
            ErrorKind.INVALID_URL,
            String(
                "a request needs an absolute URL and '",
                url,
                "' is relative, so there is nothing to connect to",
            ),
        )
    if scheme != "http" and scheme != "https":
        raise new_error(
            ErrorKind.UNSUPPORTED_PROTOCOL,
            String(
                "the scheme '",
                scheme,
                "' is not one this client speaks, expected http or https",
            ),
        )

    # The A-label form, not the display form. The docstring on `host` says why.
    var host = String(StringSpan(from_utf8=url.raw_host()))
    if host.startswith("[") and host.endswith("]"):
        var inner = String(host[byte = 1 : host.byte_length() - 1])
        host = inner^
    if host == "":
        raise new_error(
            ErrorKind.INVALID_URL,
            String("the URL '", url, "' has no host to connect to"),
        )

    var port = url.effective_port()
    if not port:
        # Only reachable if the scheme table and the check above disagree, which
        # would be a bug here rather than bad input. Reported as one.
        var default = default_port_for(scheme)
        if not default:
            raise new_error(
                ErrorKind.INVALID_URL,
                String("no port and no default port for scheme '", scheme, "'"),
            )
        port = default

    return Origin(scheme^, host^, port.value())
