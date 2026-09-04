"""Proxy interop against Squid, tinyproxy, mitmproxy and Dante.

    pixi run interop-proxy

Four proxies that are four different things. Squid is the one a corporate
network actually runs, thirty years old and tolerant of almost anything.
tinyproxy is a few thousand lines that forward and tunnel and nothing else, so
it has none of that tolerance and a request that is not quite right fails
against it first. mitmproxy is a proxy whose whole purpose is to break the
tunnel open, which makes it the only one here that can prove the tunnelling
cases are checking what they claim to. Dante is SOCKS5, which is not HTTP at
all and shares no code with the other three on either side of the connection.

All four reach the same origin, `tools/interop/origin.py`, so the answers are
the same and a difference in a result is a difference in the proxying. The
tunnelling cases go to `tlsorigin`, which is nginx with the suite's own
certificate in front of that same origin.

Two things about the addresses are load bearing. The proxies are reached on the
loopback address, because that is where the ports are published, and the
targets are named `origin` and `tlsorigin`, which are Docker network names that
do not resolve on the machine running this. A client that resolved the target
itself instead of handing the name to the proxy would fail every case here with
a resolver error, which is exactly the failure worth catching.

The mitmproxy cases are the pair worth reading. The first asks for a tunnel
while trusting the suite's own CA, and requires it to fail, because a proxy
that answers with its own certificate is a party in the middle and there is no
version of that which should quietly work. The second trusts mitmproxy's CA on
purpose and requires the same request to succeed, which is what keeps the first
case from passing on a client that cannot handshake through a tunnel at all.

This needs Docker and it is not in CI. tools/interop/proxy_run.sh brings the
proxies up and sets the environment variables this reads. See docs/testing.md.
"""

from std.time import perf_counter_ns

from httpx import Client, Proxy
from httpx._ffi.c import getenv
from httpx._models.headers import Headers
from httpx._models.json import Json
from httpx._stream.config import SSLVerify

comptime ORIGIN = "http://origin:8080"
"""The plain origin, by its name on the Docker network.

Not resolvable here, which is the point. Every forwarded case proves the name
went to the proxy rather than to a resolver on this machine.
"""

comptime TLS_ORIGIN = "https://tlsorigin"
"""The same origin behind nginx, for the cases that need a tunnel."""

comptime TINYPROXY_AUTH = "http://127.0.0.1:18889"
"""The tinyproxy that wants credentials, without them."""

comptime TINYPROXY_AUTH_OK = "http://interop:hunter2@127.0.0.1:18889"
"""The same one with them. The password is the one in the configuration file,
which guards a proxy that lives for the length of one run."""

comptime DANTE_AUTH = "socks5://127.0.0.1:11081"
comptime DANTE_AUTH_OK = "socks5://interop:hunter2@127.0.0.1:11081"

comptime BIG_DOWNLOAD = 1024 * 1024
"""Large enough to need many reads through the proxy, and large enough that a
proxy that buffered the whole thing would show up as a pause rather than as a
failure."""

comptime DRIP_CHUNKS = 16


struct Report(Movable):
    """What happened, kept per proxy so the summary can name the odd one out."""

    var passed: Int
    var failures: List[String]

    def __init__(out self):
        self.passed = 0
        self.failures = List[String]()


def _client(ca: String, proxy: StringSpan) raises -> Client:
    """A client that sends everything through `proxy`.

    Verification stays on, against the suite's own CA. Turning it off would be
    one line shorter and would also mean the tunnelling cases proved nothing,
    since what they are checking is which certificate comes back through the
    tunnel.
    """
    return Client(
        verify=SSLVerify.from_file(ca.copy()),
        proxy=Optional[Proxy](Proxy(proxy)),
    )


def _want(condition: Bool, what: String) raises:
    if not condition:
        raise Error(what)


def _want_status(found: Int, expected: Int) raises:
    _want(
        found == expected,
        String("wanted status ", expected, ", got ", found),
    )


def _echoed_headers(body: String) raises -> Headers:
    """The request headers, as /get saw them."""
    var document = Json.loads(body)
    var found = document.value()["headers"]
    var out = Headers()
    var names = found.keys()
    for i in range(len(names)):
        out.append(names[i], found[names[i]].as_string())
    return out^


def forwarded_get(proxy: String, ca: String) raises:
    var client = _client(ca, proxy)
    var r = client.get(String(ORIGIN, "/get"))
    _want_status(r.status_code, 200)

    var document = Json.loads(r.text())
    _want(
        document.value()["method"].as_string() == "GET",
        String("the origin saw ", document.value()["method"].as_string()),
    )


def host_names_the_server(proxy: String, ca: String) raises:
    """The two halves of a forwarded request, checked at the far end.

    The request line carries the whole URL, which is the only way the proxy
    knows where to send it, so a client that sent a path would fail before this
    reads anything. What is left to check is the `Host`, which has to name the
    server and not the proxy, because a proxy that passed our `Host` through
    would deliver the request to the wrong virtual host on a machine that has
    more than one.
    """
    var client = _client(ca, proxy)
    var r = client.get(String(ORIGIN, "/get"))
    _want_status(r.status_code, 200)

    var echoed = _echoed_headers(r.text())
    _want(
        echoed.get("host") == "origin:8080",
        String("the origin saw host as ", echoed.get("host")),
    )


def post_a_body(proxy: String, ca: String) raises:
    var client = _client(ca, proxy)
    var r = client.post(String(ORIGIN, "/echo"), text="the quick brown fox")
    _want_status(r.status_code, 200)
    _want(
        r.text() == "the quick brown fox",
        String("the echo came back as ", r.text()),
    )


def big_response_body(proxy: String, ca: String) raises:
    var client = _client(ca, proxy)
    var r = client.get(String(ORIGIN, "/bytes/", BIG_DOWNLOAD))
    _want_status(r.status_code, 200)

    var body = r.content()
    _want(
        len(body) == BIG_DOWNLOAD,
        String("wanted ", BIG_DOWNLOAD, " octets, got ", len(body)),
    )
    for i in range(len(body)):
        if body[i] != UInt8(ord("a")):
            raise Error(String("octet ", i, " is not what was sent"))


def streamed_response(proxy: String, ca: String) raises:
    """A body with no length, read as it arrives.

    A proxy is free to buffer, so the number of pieces is not asserted. What is
    asserted is that a response the origin sent chunked, over a connection the
    proxy is framing for a second time, arrives whole and ends where the origin
    ended it.
    """
    var wanted = String()
    for _ in range(DRIP_CHUNKS):
        wanted += "drip"

    var client = _client(ca, proxy)
    with client.stream(
        "GET", String(ORIGIN, "/drip?chunks=", DRIP_CHUNKS)
    ) as r:
        _want_status(r.status_code, 200)
        var found = String()
        var chunks = r.iter_bytes()
        while chunks.has_next():
            found += StringSpan(from_utf8=Span(chunks.next()))
        _want(
            found == wanted,
            String("the drip came back as ", found.byte_length(), " octets"),
        )


def error_status(proxy: String, ca: String) raises:
    # A 500 from the origin is a response and not an error, and it has to stay
    # one on the way back through a proxy. A client that raised on it would
    # leave the caller unable to read the body the server sent to explain
    # itself.
    var client = _client(ca, proxy)
    var r = client.get(String(ORIGIN, "/status/500"))
    _want_status(r.status_code, 500)


def head_has_no_body(proxy: String, ca: String) raises:
    var client = _client(ca, proxy)
    var r = client.head(String(ORIGIN, "/get"))
    _want_status(r.status_code, 200)
    _want(
        len(r.content()) == 0,
        String("a HEAD arrived with ", len(r.content()), " octets of body"),
    )


def several_requests(proxy: String, ca: String) raises:
    """Several requests through one client, which is one connection.

    Every forwarded request through a proxy goes to the same address whatever
    server it is aimed at, so they all share. What this catches is the thing
    that actually goes wrong: a response whose framing was read wrong leaves
    the connection with bytes on it, and the request after it is the one that
    fails.
    """
    var client = _client(ca, proxy)
    for _ in range(5):
        var r = client.get(String(ORIGIN, "/get"))
        _want_status(r.status_code, 200)


def follows_a_redirect(proxy: String, ca: String) raises:
    """A redirect to a relative location, resolved and then proxied again.

    The `Location` is `/get`, so the client has to resolve it against the URL
    it asked for and send the result through the proxy in absolute form again.
    A client that resolved it against the proxy would ask for the proxy's own
    `/get`.
    """
    var client = _client(ca, proxy)
    var r = client.get(String(ORIGIN, "/redirect"), follow_redirects=True)
    _want_status(r.status_code, 200)
    var document = Json.loads(r.text())
    _want(
        document.value()["path"].as_string() == "/get",
        String("ended up at ", document.value()["path"].as_string()),
    )


def tunnel_reaches_the_origin(proxy: String, ca: String) raises:
    """CONNECT, then a handshake inside it, to the server's own certificate.

    The CA here is the suite's, which signed the certificate nginx is holding
    and nothing the proxy has. So this passing means the certificate that came
    back was the origin's own, which is the whole claim a tunnel makes: the
    proxy copies bytes and is not in the trust path.
    """
    var client = _client(ca, proxy)
    var r = client.get(String(TLS_ORIGIN, "/get"))
    _want_status(r.status_code, 200)

    var echoed = _echoed_headers(r.text())
    _want(
        echoed.get("host") == "tlsorigin",
        String("the origin saw host as ", echoed.get("host")),
    )


def big_body_through_a_tunnel(proxy: String, ca: String) raises:
    var client = _client(ca, proxy)
    var r = client.get(String(TLS_ORIGIN, "/bytes/", BIG_DOWNLOAD))
    _want_status(r.status_code, 200)
    _want(
        len(r.content()) == BIG_DOWNLOAD,
        String("wanted ", BIG_DOWNLOAD, " octets, got ", len(r.content())),
    )


def two_requests_share_a_tunnel(proxy: String, ca: String) raises:
    """Two requests to the same server through one client.

    A tunnel is pooled under the server on the far end of it rather than under
    the proxy, so the second request should not need a second CONNECT. Nothing
    here can see how many tunnels were opened, and what it does catch is a
    tunnel left in a state the second request cannot use, which is the failure
    that would matter anyway.
    """
    var client = _client(ca, proxy)
    for _ in range(2):
        var r = client.get(String(TLS_ORIGIN, "/get"))
        _want_status(r.status_code, 200)


def a_refused_tunnel_names_the_status(proxy: String, ca: String) raises:
    """Squid refuses a CONNECT to anything but 443, and says 403.

    A refusal has nowhere to arrive as a response, because a tunnel that was
    never opened has no channel for one to come back through, so this has to be
    an error and the error has to carry the status. The configuration in
    proxy_squid.conf keeps the default rule that produces it.
    """
    var client = _client(ca, proxy)
    var opened = False
    var message = String()
    try:
        _ = client.get("https://origin:8080/get")
        opened = True
    except e:
        message = String(e)

    _want(not opened, String("the proxy tunnelled to a port it refuses"))
    _want(
        message.find("403") >= 0,
        String("the message does not name the status: ", message),
    )
    _want(
        message.find("origin:8080") >= 0,
        String("the message does not name the target: ", message),
    )


def credentials_are_wanted_and_missing(proxy: String, ca: String) raises:
    """No credentials, forwarded, which comes back as an ordinary 407.

    A forwarded request that the proxy refuses is a response and not an error.
    There is a real HTTP exchange to carry it, the proxy sends a body
    explaining itself and a `Proxy-Authenticate` naming the scheme, and a
    client that raised here would throw all of that away.
    """
    var client = _client(ca, TINYPROXY_AUTH)
    var r = client.get(String(ORIGIN, "/get"))
    _want_status(r.status_code, 407)
    _want(
        r.headers.get("proxy-authenticate").lower().startswith("basic"),
        String(
            "the challenge came back as ", r.headers.get("proxy-authenticate")
        ),
    )


def credentials_in_the_proxy_url_are_used(proxy: String, ca: String) raises:
    """The same request with the password in the proxy URL.

    That is how `HTTP_PROXY` carries one, and the credential has to come out of
    the URL and go into a `Proxy-Authorization` on the hop rather than into the
    request the origin sees.
    """
    var client = _client(ca, TINYPROXY_AUTH_OK)
    var r = client.get(String(ORIGIN, "/get"))
    _want_status(r.status_code, 200)

    var echoed = _echoed_headers(r.text())
    _want(
        echoed.get("proxy-authorization") == "",
        String("the credential reached the origin as a header"),
    )


def a_tunnel_without_credentials_is_refused(
    proxy: String, ca: String
) raises:
    """The same 407, on a CONNECT, where it cannot be a response.

    This is the case the pair above exists to contrast with. A refused
    forwarded request is a `Response` and a refused tunnel is an error, and the
    difference is not a choice: after a 407 to a CONNECT there is no tunnel for
    a response to come back through.
    """
    var client = _client(ca, TINYPROXY_AUTH)
    var opened = False
    var message = String()
    try:
        _ = client.get(String(TLS_ORIGIN, "/get"))
        opened = True
    except e:
        message = String(e)

    _want(not opened, String("the proxy tunnelled without credentials"))
    _want(
        message.find("407") >= 0,
        String("the message does not name the status: ", message),
    )


def a_tunnel_with_credentials_is_opened(proxy: String, ca: String) raises:
    var client = _client(ca, TINYPROXY_AUTH_OK)
    var r = client.get(String(TLS_ORIGIN, "/get"))
    _want_status(r.status_code, 200)


def an_intercepted_tunnel_is_refused(proxy: String, ca: String) raises:
    """The handshake is answered by mitmproxy itself, and that has to fail.

    mitmproxy is not misconfigured here, it is doing the one thing it exists to
    do. What it turns into is the only test that matters about a tunnel: a
    party in the middle of one, with a certificate signed by a CA the client
    does not trust. Every other tunnelling case would still pass on a client
    that had quietly stopped verifying, and this one would not.
    """
    var client = _client(ca, proxy)
    var opened = False
    var message = String()
    try:
        _ = client.get(String(TLS_ORIGIN, "/get"))
        opened = True
    except e:
        message = String(e)

    _want(not opened, String("the interception was not noticed"))
    _want(
        message.find("was rejected") >= 0,
        String("the message is not about the certificate: ", message),
    )
    _want(
        message.find("tlsorigin") >= 0,
        String("the message does not name the host: ", message),
    )


def an_interceptor_can_be_trusted_on_purpose(
    proxy: String, ca: String
) raises:
    """The same request again, trusting mitmproxy's own CA.

    Which is what somebody debugging their own traffic actually does. It also
    keeps the case above honest: without this one, a client that could not
    handshake through a tunnel at all would pass the pair.
    """
    var mitm = getenv("HTTPX_INTEROP_MITM_CA")
    if not mitm:
        raise Error("HTTPX_INTEROP_MITM_CA is not set")

    var client = _client(mitm.value(), proxy)
    var r = client.get(String(TLS_ORIGIN, "/get"))
    _want_status(r.status_code, 200)

    var document = Json.loads(r.text())
    _want(
        document.value()["path"].as_string() == "/get",
        String("the body did not come from the origin: ", r.text()),
    )


def socks_reaches_a_name_it_cannot_resolve(proxy: String, ca: String) raises:
    """SOCKS5 to a host that only exists on the other side of the proxy.

    The name goes over as a name, in the handshake, and the proxy resolves it.
    A client that resolved it here would not get as far as connecting, which is
    what makes this the case that proves it does not.
    """
    var client = _client(ca, proxy)
    var r = client.get(String(ORIGIN, "/get"))
    _want_status(r.status_code, 200)

    var echoed = _echoed_headers(r.text())
    _want(
        echoed.get("host") == "origin:8080",
        String("the origin saw host as ", echoed.get("host")),
    )


def socks_sends_the_request_unchanged(proxy: String, ca: String) raises:
    """A SOCKS proxy never reads the request, so nothing about it changes.

    No absolute request line, no `Proxy-Authorization`, nothing. What the
    origin receives is byte for byte the request that would have gone to it
    directly, and the path in the echo is what says so.
    """
    var client = _client(ca, proxy)
    var r = client.post(String(ORIGIN, "/echo"), text="through a socks pipe")
    _want_status(r.status_code, 200)
    _want(
        r.text() == "through a socks pipe",
        String("the echo came back as ", r.text()),
    )


def socks_big_response_body(proxy: String, ca: String) raises:
    var client = _client(ca, proxy)
    var r = client.get(String(ORIGIN, "/bytes/", BIG_DOWNLOAD))
    _want_status(r.status_code, 200)
    _want(
        len(r.content()) == BIG_DOWNLOAD,
        String("wanted ", BIG_DOWNLOAD, " octets, got ", len(r.content())),
    )


def socks_carries_tls(proxy: String, ca: String) raises:
    """`https://` over SOCKS5, which is the same pipe with a handshake in it.

    SOCKS makes no distinction between an `http://` target and an `https://`
    one, so this is not a second code path in the proxy the way CONNECT is. It
    is here because the certificate that comes back still has to be the
    origin's own.
    """
    var client = _client(ca, proxy)
    var r = client.get(String(TLS_ORIGIN, "/get"))
    _want_status(r.status_code, 200)


def socks_several_requests(proxy: String, ca: String) raises:
    """Two requests to the same server, which is one tunnel reused.

    Everything through SOCKS is a tunnel and a tunnel is filed under the server
    on the far end, so the second request should find the first one's
    connection idle in the pool.
    """
    var client = _client(ca, proxy)
    for _ in range(2):
        var r = client.get(String(ORIGIN, "/get"))
        _want_status(r.status_code, 200)


def socks_credentials_are_sent_in_the_handshake(
    proxy: String, ca: String
) raises:
    """RFC 1929, which is a username and a password as length prefixed bytes.

    Not a header, because SOCKS has none. This is the only place that code path
    meets a server that did not come out of this repository, and Dante checks
    the password against a real account in the image.
    """
    var client = _client(ca, DANTE_AUTH_OK)
    var r = client.get(String(ORIGIN, "/get"))
    _want_status(r.status_code, 200)


def socks_without_credentials_is_refused(proxy: String, ca: String) raises:
    """The same proxy with nothing to offer it.

    Dante offers only the username method, the client has only the no
    authentication one to answer with, and the greeting ends there. The message
    has to say that rather than reporting a closed connection, because what the
    reader has to do about it is put credentials in the proxy URL.
    """
    var client = _client(ca, DANTE_AUTH)
    var opened = False
    var message = String()
    try:
        _ = client.get(String(ORIGIN, "/get"))
        opened = True
    except e:
        message = String(e)

    _want(not opened, String("the proxy took an unauthenticated connection"))
    _want(
        message.find("authentication") >= 0,
        String("the message is not about authentication: ", message),
    )


comptime Case = def (proxy: String, ca: String) raises thin -> None
"""What every case above is. The proxy it goes through and the CA to trust are
all any of them needs, and having one shape means the runner is a loop rather
than a list of calls somebody has to remember to add to."""

comptime SHARED_LABELS: InlineArray[StaticString, 9] = [
    "a forwarded GET reaches the origin",
    "the Host names the server and not the proxy",
    "a POST body goes through",
    "a megabyte comes back whole",
    "a streamed body arrives and ends where the origin ended it",
    "an error status is still a response",
    "HEAD has no body",
    "several requests share one connection",
    "a relative redirect is resolved and proxied again",
]

comptime TUNNEL_LABELS: InlineArray[StaticString, 3] = [
    "a tunnel reaches the origin's own certificate",
    "a megabyte comes back through a tunnel",
    "two requests share one tunnel",
]

comptime SQUID_LABELS: InlineArray[StaticString, 1] = [
    "a refused tunnel is an error naming the status",
]

comptime AUTH_LABELS: InlineArray[StaticString, 4] = [
    "a forwarded 407 arrives as a response",
    "credentials in the proxy URL are accepted",
    "a 407 to a CONNECT is an error",
    "a tunnel opens with credentials",
]

comptime MITM_LABELS: InlineArray[StaticString, 2] = [
    "an intercepted tunnel is refused",
    "an interceptor trusted on purpose works",
]

comptime SOCKS_LABELS: InlineArray[StaticString, 7] = [
    "a name is resolved at the proxy",
    "the request goes through unchanged",
    "a megabyte comes back whole",
    "TLS runs end to end through the pipe",
    "two requests share one connection",
    "a username and password are accepted",
    "no credentials at all is refused, and says so",
]


def _walk[
    N: Int
](
    mut report: Report,
    name: StringSpan,
    where: String,
    ca: String,
    checks: InlineArray[Case, N],
    labels: InlineArray[StaticString, N],
) raises:
    """Run one group of cases and add what happened to `report`.

    A group rather than all of them, because which cases a proxy gets depends
    on what it is, and a runner that took every case and skipped the ones that
    did not apply would report a count that meant something different for each
    proxy.
    """
    for i in range(len(checks)):
        var started = perf_counter_ns()
        try:
            checks[i](where, ca)
            var took = (perf_counter_ns() - started) // 1000000
            print("  ok      ", labels[i], "(", took, "ms )")
            report.passed += 1
        except e:
            print("  FAILED  ", labels[i])
            print("            ", String(e))
            report.failures.append(String(name, ": ", labels[i]))


def run_http_proxy(
    name: StringSpan, port: StringSpan, ca: String
) raises -> Report:
    var where = String("http://127.0.0.1:", port)
    var report = Report()
    print("===", name, "on", where)

    _walk(
        report,
        name,
        where,
        ca,
        [
            forwarded_get,
            host_names_the_server,
            post_a_body,
            big_response_body,
            streamed_response,
            error_status,
            head_has_no_body,
            several_requests,
            follows_a_redirect,
        ],
        materialize[SHARED_LABELS](),
    )

    # mitmproxy is left out of the tunnelling group on purpose. It has its own
    # pair below, because a tunnel it is sitting in the middle of is not
    # supposed to reach the origin's certificate.
    if name == "squid" or name == "tinyproxy":
        _walk(
            report,
            name,
            where,
            ca,
            [
                tunnel_reaches_the_origin,
                big_body_through_a_tunnel,
                two_requests_share_a_tunnel,
            ],
            materialize[TUNNEL_LABELS](),
        )

    if name == "squid":
        _walk(
            report,
            name,
            where,
            ca,
            [a_refused_tunnel_names_the_status],
            materialize[SQUID_LABELS](),
        )

    # Against the second tinyproxy, which is the same build wanting
    # credentials. These are here rather than under a proxy of their own so
    # that the contrast with the cases above is in one report.
    if name == "tinyproxy":
        _walk(
            report,
            name,
            where,
            ca,
            [
                credentials_are_wanted_and_missing,
                credentials_in_the_proxy_url_are_used,
                a_tunnel_without_credentials_is_refused,
                a_tunnel_with_credentials_is_opened,
            ],
            materialize[AUTH_LABELS](),
        )

    if name == "mitmproxy":
        _walk(
            report,
            name,
            where,
            ca,
            [
                an_intercepted_tunnel_is_refused,
                an_interceptor_can_be_trusted_on_purpose,
            ],
            materialize[MITM_LABELS](),
        )

    return report^


def run_socks_proxy(ca: String) raises -> Report:
    var where = String("socks5://127.0.0.1:11080")
    var report = Report()
    print("=== dante on", where)

    _walk(
        report,
        "dante",
        where,
        ca,
        [
            socks_reaches_a_name_it_cannot_resolve,
            socks_sends_the_request_unchanged,
            socks_big_response_body,
            socks_carries_tls,
            socks_several_requests,
            socks_credentials_are_sent_in_the_handshake,
            socks_without_credentials_is_refused,
        ],
        materialize[SOCKS_LABELS](),
    )
    return report^


def main() raises:
    var ca = getenv("HTTPX_INTEROP_CA")
    if not ca:
        raise Error(
            "HTTPX_INTEROP_CA is not set. Run this as `pixi run"
            " interop-proxy`, which brings the proxies up first."
        )

    # Set by the runner when it was given --only, so that the two halves agree
    # about which proxies are actually listening.
    var only = getenv("HTTPX_INTEROP_ONLY").or_else(String())

    # The ports the runner publishes. High ones on purpose: 3128 and 8080 and
    # 1080 are where a proxy somebody else started is already sitting, and a
    # case that quietly ran against one of those is worse than a case that
    # failed. The runner checks they are free before it starts anything.
    var names = ["squid", "tinyproxy", "mitmproxy"]
    var ports = ["13128", "18888", "18080"]
    var failures = List[String]()
    var passed = 0
    var ran = 0

    for i in range(len(names)):
        if only.byte_length() > 0 and String(" ", names[i], " ") not in only:
            continue
        ran += 1
        var report = run_http_proxy(names[i], ports[i], ca.value())
        passed += report.passed
        for f in range(len(report.failures)):
            failures.append(report.failures[f].copy())
        print()

    if only.byte_length() == 0 or " dante " in only:
        ran += 1
        var report = run_socks_proxy(ca.value())
        passed += report.passed
        for f in range(len(report.failures)):
            failures.append(report.failures[f].copy())
        print()

    if ran == 0:
        raise Error("no proxies matched")

    if len(failures) == 0:
        var what = "proxies" if ran > 1 else "proxy"
        print(passed, "cases across", ran, String(what, ", all as expected"))
        return

    print(len(failures), "of", passed + len(failures), "cases failed:")
    for i in range(len(failures)):
        print("  ", failures[i])
    raise Error(String(len(failures), " interop failure(s)"))
