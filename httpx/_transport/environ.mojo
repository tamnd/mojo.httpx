"""The proxy settings a process inherits from its environment.

`HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` and `NO_PROXY` are how a corporate
network tells everything running on a machine where to send its traffic, and a
client that ignores them is a client that has to be configured twice. Reading
them turns into a routing table, which is why this lives next to
`httpx._transport.mounts` rather than next to the pool: `HTTPS_PROXY` is a mount
on `https://` and every entry in `NO_PROXY` is a bypass.

## The names, and which spelling wins

Each variable is looked up in lower case first and then in upper case, and the
first one with a value in it is the answer. An empty value counts as unset,
because `HTTP_PROXY=` is how a script says "not through a proxy" and treating it
as a proxy named the empty string helps nobody.

Lower case first is deliberate and it is what curl does. Python's own
`urllib.request.getproxies` instead lets whichever spelling comes later in the
environment block win, which makes the answer depend on the order a shell
happened to export things in.

## httpoxy, which is why `HTTP_PROXY` is special

CGI puts every request header into the environment with an `HTTP_` prefix, so a
request carrying a header called `Proxy` arrives as `HTTP_PROXY`. A client
reading that variable in a CGI process is taking routing instructions from
whoever sent the request, and the traffic it sends is server side traffic with
server side credentials on it. That is CVE-2016-5385, and the mitigation
everyone settled on is the one here: when `REQUEST_METHOD` is set, which is the
marker that says this process is answering a CGI request, the upper case
`HTTP_PROXY` is ignored. The lower case `http_proxy` still works, because no CGI
server produces that name.

Only `HTTP_PROXY` is affected. A header would have to be called `Proxy` to reach
it, and there is no header that turns into `HTTPS_PROXY` or `ALL_PROXY`.

## `NO_PROXY`

A comma separated list, and the entries are matched the way curl matches them
rather than the way any one RFC says, because there is no RFC. A bare name
matches that name and everything under it, a leading dot means subdomains only,
an address matches that address, an address with a prefix length matches that
range, and a single `*` anywhere in the list turns proxying off completely.
"""

from httpx._exceptions import ErrorKind, new_error
from httpx._ffi.c import getenv
from httpx._models.url import URL
from httpx._pool.proxy import Proxy
from httpx._util.ip import parse_ip_address


struct ProxyRoute(Movable):
    """One line of the routing table the environment asked for."""

    var pattern: String
    """The mount pattern, ready for `URLPattern`."""

    var proxy: Optional[Proxy]
    """Where matching requests go, and nothing for a `NO_PROXY` entry."""

    def __init__(out self, var pattern: String, var proxy: Optional[Proxy]):
        self.pattern = pattern^
        self.proxy = proxy^


def environment_proxies() raises -> List[ProxyRoute]:
    """The routing table this process's environment describes.

    Empty when nothing is set, which is the ordinary case, and empty as well
    when `NO_PROXY` contains a `*`.
    """
    var cgi = Bool(getenv("REQUEST_METHOD"))
    return proxy_routes(
        _variable("http_proxy", "HTTP_PROXY", not cgi),
        _variable("https_proxy", "HTTPS_PROXY", True),
        _variable("all_proxy", "ALL_PROXY", True),
        _variable("no_proxy", "NO_PROXY", True),
    )


def proxy_routes(
    http: StringSpan, https: StringSpan, all: StringSpan, no: StringSpan
) raises -> List[ProxyRoute]:
    """The same table from four values that have already been looked up.

    Split out from `environment_proxies` so the rules can be tested without a
    process environment in the way, and because the CLI will want to build this
    from flags one day.
    """
    var routes = List[ProxyRoute]()

    var entries = _split(no)
    for i in range(len(entries)):
        if entries[i] == "*":
            # Everything is exempt, so there is no table at all. Returning here
            # rather than adding a bypass on `all://` because a bypass sits in
            # front of whatever else was mounted, and this has to lose to a
            # transport the caller mounted themselves.
            return routes^

    if http.byte_length() > 0:
        routes.append(ProxyRoute(String("http://"), _proxy(http)))
    if https.byte_length() > 0:
        routes.append(ProxyRoute(String("https://"), _proxy(https)))
    if all.byte_length() > 0:
        routes.append(ProxyRoute(String("all://"), _proxy(all)))

    for i in range(len(entries)):
        if entries[i] == "":
            continue
        routes.append(ProxyRoute(no_proxy_pattern(entries[i]), None))
    return routes^


def no_proxy_pattern(entry: StringSpan) raises -> String:
    """One `NO_PROXY` entry as a mount pattern.

    ```
    example.com         all://*example.com      the name and everything under it
    .example.com        all://*.example.com     everything under it and not it
    localhost           all://localhost         that name alone
    10.0.0.1            all://10.0.0.1          that address
    10.0.0.0/8          all://10.0.0.0/8        that range
    ::1                 all://[::1]             brackets, since it goes in a URL
    https://example.com https://example.com     already a pattern, left alone
    ```

    A bare name becoming `*name` rather than `name` is the part worth knowing.
    It is what curl does and what httpx does, and it means `NO_PROXY=example.com`
    exempts `www.example.com` as well. A leading dot is how the list says the
    domain itself is not exempt.
    """
    var text = String(entry)
    if text.find("://") >= 0:
        return text^

    var host = text.copy()
    var suffix = String()
    var slash = text.rfind("/")
    if slash >= 0:
        var bits = String(text[byte = slash + 1 :])
        if bits != "" and bits.byte_length() <= 3 and _all_digits(bits):
            suffix = String("/", bits)
            var head = String(text[byte=0:slash])
            host = head^

    var address = parse_ip_address(host)
    if address.family == 6:
        # Bracketed on the way out, because the pattern is read as a URL
        # authority and an unbracketed address there is a host and a port.
        return String("all://[", host, "]", suffix)
    if address.family == 4:
        return String("all://", host, suffix)
    if host.lower() == "localhost":
        # A name with nothing under it, so the wildcard below would only widen
        # it to things like `notlocalhost`.
        return String("all://", host)
    return String("all://*", text)


def _variable(
    lower: StringSpan, upper: StringSpan, trust_upper: Bool
) raises -> String:
    """One setting, in whichever spelling is set, and empty for neither."""
    var found = getenv(lower)
    if found and found.value() != "":
        return found.take()
    if not trust_upper:
        return String()
    var shouted = getenv(upper)
    if shouted and shouted.value() != "":
        return shouted.take()
    return String()


def _proxy(value: StringSpan) raises -> Optional[Proxy]:
    """A proxy from an environment value, which may have no scheme on it.

    `HTTP_PROXY=squid:3128` is a common way to write it and means the same as
    `http://squid:3128`, so the scheme is filled in rather than refused. Any
    other failure is raised, because a proxy variable that cannot be read means
    traffic going direct out of a network that expects it not to.
    """
    var text = String(value)
    if text.find("://") < 0:
        var qualified = String("http://", text)
        text = qualified^
    try:
        return Optional[Proxy](Proxy(URL(text)))
    except error:
        raise new_error(
            ErrorKind.INVALID_ARGUMENT,
            String(
                "the proxy named in the environment, '",
                text,
                "', is not a URL this client can use: ",
                error,
            ),
        )


def _split(text: StringSpan) -> List[String]:
    """A comma separated list with the spaces taken off each entry."""
    var out = List[String]()
    var held = String(text)
    var at = 0
    while at <= held.byte_length():
        var stop = held.find(",", at)
        if stop < 0:
            stop = held.byte_length()
        out.append(String(held[byte=at:stop].strip()))
        at = stop + 1
    return out^


def _all_digits(text: String) -> Bool:
    for byte in text.as_bytes():
        if byte < UInt8(ord("0")) or byte > UInt8(ord("9")):
            return False
    return True
