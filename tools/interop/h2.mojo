"""HTTP/2 interop against nginx, Caddy, Envoy and nghttpx.

    pixi run interop-h2

The four are not four ways of asking the same question. nginx and Caddy are web
servers that grew an HTTP/2 front end, Envoy is an HTTP/2 stack that grew a
proxy, and nghttpx is the reference implementation's own server, written by the
people who wrote the RFC. They disagree about window sizes, about how many
frames a body arrives in, about whether a header block is Huffman coded, and
about how strict to be with what we send. A client that works against one of
them has been tested against one set of choices.

All four sit in front of the same HTTP/1.1 origin, so the answers are the same
and a difference in a result is a difference in the HTTP/2 and not in what each
server thinks a directory listing looks like.

The cases are mostly about the parts of HTTP/2 that have no HTTP/1.1
equivalent, because the rest is already covered by the unit tests and by the
parity suite. Flow control is the main one: a body larger than the initial
window cannot be sent or received without the two sides exchanging
`WINDOW_UPDATE` correctly, and nothing smaller than a real server on the other
end will tell you whether that works.

The last case is the one that would be easy to leave out. It asks a server that
speaks HTTP/2 for HTTP/1.1 and checks it gets it, because a suite where every
case is an HTTP/2 case passes on a client that has forgotten how to negotiate
and simply assumes.

This needs Docker and it is not in CI. tools/interop/h2_run.sh brings the
servers up and sets the two environment variables this reads. See
docs/testing.md.
"""

from std.time import perf_counter_ns

from httpx import Client
from httpx._ffi.c import getenv
from httpx._models.headers import Headers
from httpx._models.json import Json
from httpx._models.stream import ByteSource, ByteStream, erase_source
from httpx._stream.config import SSLVerify

comptime SERVERS: InlineArray[StaticString, 4] = [
    "nginx",
    "caddy",
    "envoy",
    "nghttpx",
]

comptime PORTS: InlineArray[StaticString, 4] = ["8443", "8444", "8445", "8446"]

comptime LABELS: InlineArray[StaticString, 14] = [
    "a plain GET",
    "a request header arrives at the origin",
    "a POST with a body",
    "a request body larger than the initial window",
    "a streamed request body has no length",
    "a response body larger than the initial window",
    "a streamed response arrives in pieces",
    "a 204 has no body",
    "an error status is still a response",
    "a response with forty headers",
    "a redirect is followed",
    "a connection carries several requests",
    "HEAD has no body",
    "asking for HTTP/1.1 gets HTTP/1.1",
]

comptime BIG_UPLOAD = 200 * 1024
"""Larger than the 65535 octet initial window, so the send side has to wait.

Three times over, so that a client which handled the first `WINDOW_UPDATE` and
then stopped accounting would still run out.
"""

comptime BIG_DOWNLOAD = 1024 * 1024
"""Same idea in the other direction, and large enough to need many DATA frames
whatever frame size the server settled on."""

comptime DRIP_CHUNKS = 16

comptime STREAM_CHUNK = 16 * 1024
comptime STREAM_CHUNKS = 8
"""128 KiB in eight pieces, which crosses the initial window with no length."""


struct _Chunks(ByteSource, Movable):
    """A request body handed over a piece at a time, so its length is unknown.

    HTTP/2 has no chunked encoding, so this goes out as DATA frames and no
    `content-length`, and a front end proxying it to an HTTP/1.1 origin has
    nothing left to frame the upstream hop with but chunked. That translation
    is the part worth checking against four different implementations of it.
    """

    var _left: Int

    def __init__(out self):
        self._left = STREAM_CHUNKS

    def read_chunk(mut self) raises -> List[UInt8]:
        var out = List[UInt8]()
        if self._left == 0:
            return out^
        self._left -= 1
        for i in range(STREAM_CHUNK):
            out.append(UInt8(ord("a") + (i % 26)))
        return out^

    def close(mut self):
        self._left = 0

    def trailers(self) -> Headers:
        return Headers()


struct Report(Movable):
    """What happened, kept per server so the summary can name the odd one out."""

    var passed: Int
    var failures: List[String]

    def __init__(out self):
        self.passed = 0
        self.failures = List[String]()


def _base(port: StringSpan) -> String:
    return String("https://localhost:", port)


def _client(ca: String, http2: Bool) raises -> Client:
    """A client that verifies against the suite's own CA.

    Verification stays on. Turning it off would be one line shorter and would
    also mean the handshake in every case below proved nothing, since ALPN is
    negotiated inside a handshake this would then not be checking.
    """
    return Client(verify=SSLVerify.from_file(ca.copy()), http2=http2)


def _want(condition: Bool, what: String) raises:
    if not condition:
        raise Error(what)


def _want_status(found: Int, expected: Int) raises:
    _want(
        found == expected,
        String("wanted status ", expected, ", got ", found),
    )


def _want_h2(version: String) raises:
    _want(
        version == "HTTP/2",
        String("wanted HTTP/2, the response says ", version),
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


def plain_get(mut client: Client, base: String) raises:
    var r = client.get(String(base, "/get"))
    _want_status(r.status_code, 200)
    _want_h2(r.http_version)

    var document = Json.loads(r.text())
    _want(
        document.value()["method"].as_string() == "GET",
        String("the origin saw ", document.value()["method"].as_string()),
    )


def request_header_arrives(mut client: Client, base: String) raises:
    var headers = Headers()
    headers.append("x-interop", "carried")
    var r = client.get(String(base, "/get"), headers=headers^)
    _want_status(r.status_code, 200)

    var echoed = _echoed_headers(r.text())
    _want(
        echoed.get("x-interop") == "carried",
        String("the origin saw x-interop as ", echoed.get("x-interop")),
    )
    # HTTP/2 has no Host field. It has an :authority pseudo-header, and every
    # front end here turns that back into a Host on the way to the origin, so a
    # client that sent neither would show up right here.
    _want(
        echoed.get("host").startswith("localhost"),
        String("the origin saw host as ", echoed.get("host")),
    )


def post_a_body(mut client: Client, base: String) raises:
    var sent = String("the quick brown fox").as_bytes()
    var r = client.post(String(base, "/echo"), content=List(sent))
    _want_status(r.status_code, 200)
    _want(
        r.text() == "the quick brown fox",
        String("the echo came back as ", r.text()),
    )


def big_request_body(mut client: Client, base: String) raises:
    var sent = List[UInt8]()
    for i in range(BIG_UPLOAD):
        sent.append(UInt8(ord("a") + (i % 26)))

    var r = client.post(String(base, "/echo"), content=sent^)
    _want_status(r.status_code, 200)

    var back = r.content()
    _want(
        len(back) == BIG_UPLOAD,
        String("sent ", BIG_UPLOAD, " octets and got ", len(back), " back"),
    )
    for i in range(BIG_UPLOAD):
        if back[i] != UInt8(ord("a") + (i % 26)):
            raise Error(String("the echo differs at octet ", i))


def streamed_request_body(mut client: Client, base: String) raises:
    var r = client.post(
        String(base, "/echo"),
        content_stream=Optional[ByteStream](erase_source(_Chunks())),
    )
    _want_status(r.status_code, 200)

    var back = r.content()
    var wanted = STREAM_CHUNK * STREAM_CHUNKS
    _want(
        len(back) == wanted,
        String("sent ", wanted, " octets and got ", len(back), " back"),
    )
    for i in range(len(back)):
        if back[i] != UInt8(ord("a") + ((i % STREAM_CHUNK) % 26)):
            raise Error(String("the echo differs at octet ", i))


def big_response_body(mut client: Client, base: String) raises:
    var r = client.get(String(base, "/bytes/", BIG_DOWNLOAD))
    _want_status(r.status_code, 200)

    var body = r.content()
    _want(
        len(body) == BIG_DOWNLOAD,
        String("wanted ", BIG_DOWNLOAD, " octets, got ", len(body)),
    )
    for i in range(len(body)):
        if body[i] != UInt8(ord("a")):
            raise Error(String("octet ", i, " is not what was sent"))


def streamed_response(mut client: Client, base: String) raises:
    """A body with no length, read as it arrives.

    The count of pieces is not asserted. How a server splits a stream into DATA
    frames is its own business and Envoy in particular will coalesce, so the
    thing worth checking is that a body with no `content-length` arrives whole
    and ends when the server says it does.
    """
    var wanted = String()
    for _ in range(DRIP_CHUNKS):
        wanted += "drip"

    with client.stream(
        "GET", String(base, "/drip?chunks=", DRIP_CHUNKS)
    ) as r:
        _want_status(r.status_code, 200)
        _want_h2(r.http_version)

        var found = String()
        var chunks = r.iter_bytes()
        while chunks.has_next():
            found += StringSpan(from_utf8=Span(chunks.next()))
        _want(
            found == wanted,
            String("the drip came back as ", found.byte_length(), " octets"),
        )


def no_body_on_204(mut client: Client, base: String) raises:
    var r = client.get(String(base, "/status/204"))
    _want_status(r.status_code, 204)
    _want(
        len(r.content()) == 0,
        String("a 204 arrived with ", len(r.content()), " octets of body"),
    )


def error_status(mut client: Client, base: String) raises:
    # A 500 is a response and not an error. A client that raised on it would
    # leave the caller unable to read the body the server sent to explain
    # itself.
    var r = client.get(String(base, "/status/500"))
    _want_status(r.status_code, 500)


def many_headers(mut client: Client, base: String) raises:
    var r = client.get(String(base, "/headers/40"))
    _want_status(r.status_code, 200)
    for i in range(40):
        var name = String("x-test-", i)
        _want(
            r.headers.get(name) == "value",
            String(name, " came back as ", r.headers.get(name)),
        )
    # Forty copies of one name and one value, which is what an HPACK encoder
    # will index rather than spell out, so this is the dynamic table being read
    # from rather than the static one.
    var repeated = r.headers.get_list("x-repeated")
    _want(
        len(repeated) == 40,
        String("wanted 40 copies of x-repeated, got ", len(repeated)),
    )


def follows_a_redirect(mut client: Client, base: String) raises:
    var r = client.get(String(base, "/redirect"), follow_redirects=True)
    _want_status(r.status_code, 200)
    var document = Json.loads(r.text())
    _want(
        document.value()["path"].as_string() == "/get",
        String("ended up at ", document.value()["path"].as_string()),
    )


def several_requests(mut client: Client, base: String) raises:
    """Several requests through one client, which is one connection.

    The pool is not asked how many connections it made, because it does not
    publish that and a tool reaching into it would be testing the pool rather
    than the server. What this catches is the thing that actually goes wrong: a
    stream that is not cleaned up, or a connection left in a state where the
    second request on it is the one that fails.
    """
    for i in range(5):
        var r = client.get(String(base, "/get"))
        _want_status(r.status_code, 200)
        _want_h2(r.http_version)
        _ = i


def head_has_no_body(mut client: Client, base: String) raises:
    var r = client.head(String(base, "/get"))
    _want_status(r.status_code, 200)
    _want(
        len(r.content()) == 0,
        String("a HEAD arrived with ", len(r.content()), " octets of body"),
    )


def http11_when_asked(mut client: Client, base: String) raises:
    """The negotiation, which is the case a suite of HTTP/2 cases forgets.

    Its own client, because `http2` is fixed when the client is made, and that
    is the point: the same server, the same address, a different offer in the
    handshake and a different protocol out of it.
    """
    var ca = getenv("HTTPX_INTEROP_CA")
    if not ca:
        raise Error("HTTPX_INTEROP_CA is not set")

    var other = _client(ca.value(), http2=False)
    var r = other.get(String(base, "/get"))
    _want_status(r.status_code, 200)
    _want(
        r.http_version == "HTTP/1.1",
        String("asked for HTTP/1.1 and the response says ", r.http_version),
    )


def run_server(name: StringSpan, port: StringSpan, ca: String) raises -> Report:
    var checks = [
        plain_get,
        request_header_arrives,
        post_a_body,
        big_request_body,
        streamed_request_body,
        big_response_body,
        streamed_response,
        no_body_on_204,
        error_status,
        many_headers,
        follows_a_redirect,
        several_requests,
        head_has_no_body,
        http11_when_asked,
    ]
    var labels = materialize[LABELS]()
    var base = _base(port)
    var report = Report()

    print("===", name, "on", base)
    for i in range(len(checks)):
        # One client per case. Sharing one across all of them would mean a case
        # that left a connection in a bad state failing the next case instead of
        # its own, and the report would name the wrong one.
        var client = _client(ca, http2=True)
        var started = perf_counter_ns()
        try:
            checks[i](client, base)
            var took = (perf_counter_ns() - started) // 1000000
            print("  ok      ", labels[i], "(", took, "ms )")
            report.passed += 1
        except e:
            print("  FAILED  ", labels[i])
            print("            ", String(e))
            report.failures.append(String(name, ": ", labels[i]))
    return report^


def main() raises:
    var ca = getenv("HTTPX_INTEROP_CA")
    if not ca:
        raise Error(
            "HTTPX_INTEROP_CA is not set. Run this as `pixi run interop-h2`,"
            " which brings the servers up first."
        )

    # Set by the runner when it was given --only, so that the two halves agree
    # about which servers are actually listening.
    var only = getenv("HTTPX_INTEROP_ONLY").or_else(String())

    var servers = materialize[SERVERS]()
    var ports = materialize[PORTS]()
    var failures = List[String]()
    var passed = 0
    var ran = 0

    for i in range(len(servers)):
        if only.byte_length() > 0 and String(" ", servers[i], " ") not in only:
            continue
        ran += 1
        var report = run_server(servers[i], ports[i], ca.value())
        passed += report.passed
        for f in range(len(report.failures)):
            failures.append(report.failures[f].copy())
        print()

    if ran == 0:
        raise Error("no servers matched")

    if len(failures) == 0:
        print(passed, "cases across", ran, "server(s), all as expected")
        return

    print(len(failures), "of", passed + len(failures), "cases failed:")
    for i in range(len(failures)):
        print("  ", failures[i])
    raise Error(String(len(failures), " interop failure(s)"))
