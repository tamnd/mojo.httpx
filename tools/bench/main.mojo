"""The benchmarks, one case per headline number 1.0 is held to.

This is the measuring half. The comparing half is `tools/bench/run.py`, which
starts the server, runs this once per case in its own process, and checks what
comes back against the committed baseline. Run the pair with `pixi run bench`.

Every case prints its numbers as `RESULT <case> <metric> <unit> <value>` lines
and nothing else on stdout, so the driver reads four fields rather than a table
that a later edit would break.

A case is run more than once and the best run is what gets reported. Best and
not mean, because everything that makes a run slower than the machine is capable
of is noise from somewhere else on the box, and averaging it in makes the number
depend on what else was running. The whole gate is a comparison against a number
measured the same way on the same machine, so the measure that varies least is
the one worth having.

The two things the driver owns rather than this program are the server and the
clock for cold start. The server is Python and starting it from here would mean
`std.python` inside a benchmark process, which is exactly the sort of thing that
ends up in a measurement by accident. Cold start is the time a whole process
takes, which a program cannot time from the inside.
"""

from std.sys import argv
from std.time import perf_counter_ns

from httpx._aio_client import AsyncClient, gather
from httpx._bytes import Bytes
from httpx._client import Client
from httpx._io.buffer import ByteBuffer
from httpx._io.deadline import Deadline
from httpx._io.socket import open_stream
from httpx._models.request import Request
from httpx._models.url import URL
from httpx._pool.limits import Limits
from httpx._proto.h1.head import parse_head
from httpx._proto.h2.driver import H2Driver
from httpx._proto.h2.frames import (
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FRAME_HEADER_SIZE,
    PREFACE,
    FrameHeader,
    FrameType,
    parse_frame_header,
    write_frame_header,
)
from httpx._proto.h2.hpack import HpackDecoder, HpackEncoder
from httpx._proto.h2.table import HeaderField
from httpx._stream.config import SSLVerify

from tests.support.loopback import Loopback, Peer

comptime NS_PER_SECOND = 1_000_000_000.0
comptime NS_PER_MS = 1_000_000.0
comptime BYTES_PER_MIB = 1_048_576.0

comptime KEEPALIVE_REQUESTS = 500
"""Enough that connecting once at the start is a rounding error in the rate."""

comptime CONCURRENCY = 100
"""The number M9 names. Also the pool's default connection limit, which is why
the case sets its own limits rather than letting a hundred requests queue behind
ten connections and measuring the queue."""

comptime BATCHES = 50
"""How many times the hundred go out, which is how many latency samples there
are to take percentiles over."""

comptime TRANSFER_BYTES = 10 * 1024 * 1024

comptime H2_STREAMS = 1000
comptime H2_BODY = 64
"""Small on purpose. A thousand streams carrying this much is 64000 octets,
which fits inside the 65535 the connection window starts at, so the canned peer
below never has to honour a `WINDOW_UPDATE` to finish the run."""

comptime MICRO_OPS = 20000
"""Operations per timed run in the three parser cases. Large enough that the
clock read at either end is nothing, small enough that a run is under a second
on the slowest machine in the fleet."""

comptime TEST_CERT = "tests/fixtures/tls/server.pem"
"""The certificate the driver's https server serves, which is also its own
trust anchor. Relative to the repository root, which is where the driver runs
these from."""

comptime CASES = String(
    "h1-keepalive h1-concurrent-100 upload-10mb download-10mb h2-streams-1000"
    " parse-headers parse-hpack parse-url cold-start cold-start-tls nothing"
)


def main() raises:
    var args = argv()
    var name = String()
    var base = String("http://127.0.0.1:0")
    var reps = 3

    var i = 1
    while i < len(args):
        var flag = String(args[i])
        if flag == "--list":
            print(CASES)
            return
        if i + 1 >= len(args):
            raise Error(String(flag, " needs a value"))
        var value = String(args[i + 1])
        if flag == "--case":
            name = value^
        elif flag == "--url":
            base = value^
        elif flag == "--reps":
            reps = Int(value)
        else:
            raise Error(String("unknown option ", flag))
        i += 2

    if reps < 1:
        raise Error("--reps has to be at least one")

    # Trailing slashes are the sort of thing that turns into a 404 halfway
    # through a run, so the one place a path is joined on is here.
    while base.endswith("/"):
        var shorter = String(base[byte = 0 : base.byte_length() - 1])
        base = shorter^

    if name == "h1-keepalive":
        _keepalive(base, reps)
    elif name == "h1-concurrent-100":
        _concurrent(base, reps)
    elif name == "upload-10mb":
        _upload(base, reps)
    elif name == "download-10mb":
        _download(base, reps)
    elif name == "h2-streams-1000":
        _h2_streams(reps)
    elif name == "parse-headers":
        _parse_headers(reps)
    elif name == "parse-hpack":
        _parse_hpack(reps)
    elif name == "parse-url":
        _parse_url(reps)
    elif name == "cold-start":
        _cold_start(base)
    elif name == "cold-start-tls":
        _cold_start_tls(base)
    elif name == "nothing":
        # The other half of cold start. The driver times this process too and
        # subtracts it, so that what is reported is the client starting up and
        # not the language runtime starting up.
        pass
    else:
        raise Error(String("no such case: ", name, ". Try --list"))


def _report(
    which: StringSpan, metric: StringSpan, unit: StringSpan, value: Float64
):
    print("RESULT", which, metric, unit, value)


# The client against a live server.


def _keepalive(base: String, reps: Int) raises:
    """Requests one after another down a connection that stays open.

    The number this reports is the one a caller sees when they loop over a list
    of URLs on one host, and it is mostly a measure of the request writer, the
    response parser and two syscalls. What it must not be is a measure of
    connecting, which is why the connection is checked before the clock starts.
    """
    var best = 0.0
    for _ in range(reps):
        var client = Client()
        _same_connection_twice(client, base)

        var started = perf_counter_ns()
        for _ in range(KEEPALIVE_REQUESTS):
            var response = client.get(String(base, "/status/200"))
            if response.status_code != 200:
                raise Error(
                    String("the server answered ", response.status_code)
                )
        var spent = Float64(perf_counter_ns() - started)

        var rate = Float64(KEEPALIVE_REQUESTS) * NS_PER_SECOND / spent
        if rate > best:
            best = rate
        client.close()
    _report("h1-keepalive", "req_per_s", "req/s", best)


def _same_connection_twice(mut client: Client, base: String) raises:
    """Fail rather than measure, when the connection is not being reused.

    A pool that had stopped keeping connections would still answer every
    request here and would report a number about a third of the real one, and
    the only sign of it would be a regression nobody could explain. The test
    server names the connection that answered, so asking is one request.
    """
    var first = client.get(String(base, "/conn"))
    var second = client.get(String(base, "/conn"))
    if first.headers["x-conn-id"] != second.headers["x-conn-id"]:
        raise Error(
            "two requests went down two connections, so this would be timing"
            " the connect and not the exchange"
        )


def _concurrent(base: String, reps: Int) raises:
    """A hundred requests in flight at once, over and over.

    The sample a percentile is taken over is one batch of a hundred and not one
    request. That is a real limit rather than a shortcut: the async pool reports
    a batch as a single outcome, so there is no moment recorded anywhere at
    which the seventeenth response of a hundred finished, and a per request
    percentile would have to be invented. A batch is still the sample that
    answers the question worth asking, because a caller who asks for a hundred
    at once waits for all hundred, and a pool that stalls one of them shows up
    here in the tail.
    """
    var best_p50 = -1.0
    var best_p99 = -1.0
    var best_rate = 0.0

    for _ in range(reps):
        var limits = Limits(
            max_connections=CONCURRENCY,
            max_keepalive_connections=CONCURRENCY,
        )
        var client = AsyncClient(limits=Optional[Limits](limits))

        # One batch before the clock, so the pool is full of open connections
        # and what follows is about requests rather than about a hundred
        # simultaneous connects.
        _ = _one_batch(client, base)

        var samples = List[Float64]()
        var started = perf_counter_ns()
        for _ in range(BATCHES):
            samples.append(_one_batch(client, base))
        var spent = Float64(perf_counter_ns() - started)

        _sort(samples)
        var p50 = _percentile(samples, 50)
        var p99 = _percentile(samples, 99)
        var rate = Float64(BATCHES * CONCURRENCY) * NS_PER_SECOND / spent
        if best_p50 < 0 or p50 < best_p50:
            best_p50 = p50
        if best_p99 < 0 or p99 < best_p99:
            best_p99 = p99
        if rate > best_rate:
            best_rate = rate
        client.close()

    _report("h1-concurrent-100", "batch_p50_ms", "ms", best_p50)
    _report("h1-concurrent-100", "batch_p99_ms", "ms", best_p99)
    _report("h1-concurrent-100", "req_per_s", "req/s", best_rate)


def _one_batch(mut client: AsyncClient, base: String) raises -> Float64:
    """One hundred requests together, in milliseconds.

    The requests are built before the clock starts. Building one parses a URL
    and copies the client's headers, and that work has its own case further
    down rather than being charged to this one.
    """
    var pending = List[Request]()
    for _ in range(CONCURRENCY):
        pending.append(client.build_request("GET", String(base, "/status/200")))

    var started = perf_counter_ns()
    var answers = gather(client, pending^)
    var spent = Float64(perf_counter_ns() - started) / NS_PER_MS

    if len(answers) != CONCURRENCY:
        raise Error(String(len(answers), " of ", CONCURRENCY, " came back"))
    return spent


def _upload(base: String, reps: Int) raises:
    """Ten mebibytes out, to a route that reads them and answers with nothing.

    `/status/200` rather than an echo route on purpose. An echo would send the
    same ten mebibytes back and the number would be half about reading them.
    """
    var body = _payload(TRANSFER_BYTES)
    var client = Client()
    var best = 0.0

    # A small one first, so that the connection is open and the buffers have
    # been touched before anything is timed.
    _ = client.post(String(base, "/status/200"), text="warm")

    for _ in range(reps):
        # Copied outside the timed region, because the copy is this benchmark's
        # own bookkeeping and not something a caller pays for.
        var payload = body.copy()
        var started = perf_counter_ns()
        var response = client.post(
            String(base, "/status/200"), content=payload^
        )
        var spent = Float64(perf_counter_ns() - started)
        if response.status_code != 200:
            raise Error(String("the server answered ", response.status_code))

        var rate = (
            Float64(TRANSFER_BYTES) * NS_PER_SECOND / spent / BYTES_PER_MIB
        )
        if rate > best:
            best = rate
    client.close()
    _report("upload-10mb", "mib_per_s", "MiB/s", best)


def _download(base: String, reps: Int) raises:
    """Ten mebibytes in, with a declared length, read into memory."""
    var client = Client()
    var url = String(base, "/bytes/", TRANSFER_BYTES)
    var best = 0.0

    # A small one first, for the reason the upload above does it.
    _ = client.get(String(base, "/status/200"))

    for _ in range(reps):
        var started = perf_counter_ns()
        var response = client.get(url)
        var content = response.content()
        var spent = Float64(perf_counter_ns() - started)
        if len(content) != TRANSFER_BYTES:
            raise Error(
                String(len(content), " octets arrived of ", TRANSFER_BYTES)
            )

        var rate = (
            Float64(TRANSFER_BYTES) * NS_PER_SECOND / spent / BYTES_PER_MIB
        )
        if rate > best:
            best = rate
    client.close()
    _report("download-10mb", "mib_per_s", "MiB/s", best)


def _payload(size: Int) -> List[UInt8]:
    """Bytes with a pattern rather than zeroes, so nothing downstream can be
    fast for a reason that would not hold on real content."""
    var out = List[UInt8](length=size, fill=0)
    for i in range(size):
        out[i] = UInt8(i % 251)
    return out^


# HTTP/2 against a peer that answers from a script.


def _h2_streams(reps: Int) raises:
    """A thousand streams on one connection, one at a time.

    One at a time because that is what the client does today: HTTP/2 here
    carries one request at a time per connection, so a thousand streams is a
    thousand round trips rather than a thousand in flight. When multiplexing
    lands this case is the one to rewrite, and until then calling it concurrent
    would be reporting a number nobody can get.

    The peer is a script, not a server. Its answers are encoded before the clock
    starts and it does no thinking, so what is measured is our framing, our
    HPACK and the syscalls. Some peer side reading is inside the timed region
    and cannot be lifted out, because a real exchange is the two sides taking
    turns, and it is the same on every run.
    """
    var best = 0.0

    for _ in range(reps):
        var listener = Loopback()
        var driver = H2Driver(
            open_stream(listener.addr, "loopback", Deadline.after(5.0))
        )
        var peer = listener.accept_within()

        var canned = _canned_responses(H2_STREAMS)
        var pending = List[Request]()
        for _ in range(H2_STREAMS):
            pending.append(Request("GET", URL("https://bench.invalid/one")))

        var started = perf_counter_ns()
        for i in range(H2_STREAMS):
            # Taken off the end rather than the front, because every one of
            # them is the same request and shifting a thousand element list is
            # not something to charge to HTTP/2.
            var request = pending.pop()
            driver.send_request(request, Deadline.after(5.0))
            if i == 0:
                _greet(peer)
            _ = _skip_to_headers(peer)
            peer.send_bytes(Span(canned[i]))

            var head = driver.start_response(Deadline.after(5.0))
            if head.status_code != 200:
                raise Error(String("the peer answered ", head.status_code))
            var seen = 0
            while True:
                var chunk = driver.read_chunk(Deadline.after(5.0))
                if len(chunk) == 0:
                    break
                seen += len(chunk)
            if seen != H2_BODY:
                raise Error(String(seen, " octets arrived of ", H2_BODY))
        var spent = Float64(perf_counter_ns() - started)

        var rate = Float64(H2_STREAMS) * NS_PER_SECOND / spent
        if rate > best:
            best = rate
        driver.close()
    _report("h2-streams-1000", "streams_per_s", "stream/s", best)


def _canned_responses(count: Int) raises -> List[List[UInt8]]:
    """Every answer the peer is going to give, encoded up front.

    The header block is encoded once and reused. That is sound rather than a
    shortcut: an encoder that starts fresh never names a dynamic entry, so the
    same octets decode the same way on every stream however full the reader's
    table has become by then.
    """
    var block = _encoded_ok()
    var body = List[UInt8](length=H2_BODY, fill=UInt8(ord("x")))

    var out = List[List[UInt8]]()
    for i in range(count):
        var id = UInt32(1 + 2 * i)
        var frames = Bytes()
        write_frame_header(
            FrameHeader(len(block), FrameType.HEADERS, FLAG_END_HEADERS, id),
            frames,
        )
        frames.extend(Span(block))
        write_frame_header(
            FrameHeader(len(body), FrameType.DATA, FLAG_END_STREAM, id),
            frames,
        )
        frames.extend(Span(body))
        out.append(frames.take_list())
    return out^


def _encoded_ok() raises -> List[UInt8]:
    var fields = List[HeaderField]()
    fields.append(HeaderField(String(":status"), String("200")))
    fields.append(HeaderField(String("content-type"), String("text/plain")))
    fields.append(HeaderField(String("content-length"), String(H2_BODY)))
    var encoder = HpackEncoder()
    var block = Bytes()
    encoder.encode(fields^, block)
    return block.take_list()


def _greet(mut peer: Peer) raises:
    """Take the preface and the client's settings, and answer with ours."""
    var expected = PREFACE.as_bytes()
    var seen = peer.recv_exactly(len(expected))
    if len(seen) != len(expected):
        raise Error("the client did not send the whole preface")
    _ = _read_frame(peer)

    var settings = Bytes()
    write_frame_header(
        FrameHeader(0, FrameType.SETTINGS, UInt8(0), 0), settings
    )
    peer.send_bytes(settings.as_span())


def _skip_to_headers(mut peer: Peer) raises:
    """Read past the acknowledgements and window updates to the next request."""
    while True:
        var read = _read_frame(peer)
        if read[0].type == FrameType.HEADERS:
            return


def _read_frame(mut peer: Peer) raises -> Tuple[FrameHeader, List[UInt8]]:
    var head = peer.recv_exactly(FRAME_HEADER_SIZE)
    if len(head) != FRAME_HEADER_SIZE:
        raise Error("the client did not send a whole frame header")
    var header = parse_frame_header(Span(head), 0)
    var payload = List[UInt8]()
    if header.length > 0:
        payload = peer.recv_exactly(header.length)
    return (header, payload^)


# The parsers, with no socket anywhere near them.

comptime SAMPLE_HEAD = String(
    "HTTP/1.1 200 OK\r\n"
    "Date: Thu, 01 Jan 2026 00:00:00 GMT\r\n"
    "Server: nginx/1.24.0\r\n"
    "Content-Type: application/json; charset=utf-8\r\n"
    "Content-Length: 4096\r\n"
    "Connection: keep-alive\r\n"
    "Vary: Accept-Encoding, Origin\r\n"
    "Cache-Control: private, max-age=0, no-store\r\n"
    "Set-Cookie: session=8f2b1c; Path=/; HttpOnly; SameSite=Lax\r\n"
    "Strict-Transport-Security: max-age=31536000\r\n"
    "X-Request-Id: 6f9d2c41-77aa-4c1e-9b1e-3a5c0d1f2e33\r\n"
    "\r\n"
)
"""A response head of the shape a real server sends, eleven fields and a
cookie. A three field head would be a benchmark of the loop rather than of the
work the loop does."""

comptime SAMPLE_URL = "https://user:pw@example.com:8443/a/b%2Fc/d?x=1&y=two%20words#part"
"""Every piece a URL can have, including two escapes, because the fast path
through a parser is the one where none of them are there."""


def _parse_headers(reps: Int) raises:
    """One response head, parsed out of a buffer, twenty thousand times.

    Filling the buffer is inside the measurement. It is a copy of three hundred
    octets against a parse of the same three hundred, so it is a small part of
    the number, and taking it out would mean a buffer per operation, which is an
    allocation and would cost more than it saved.
    """
    var head = SAMPLE_HEAD.as_bytes()
    var buf = ByteBuffer()
    var best = -1.0

    for _ in range(reps):
        var started = perf_counter_ns()
        for _ in range(MICRO_OPS):
            buf.clear()
            buf.extend(head)
            var found = parse_head(buf)
            if not found:
                raise Error("the sample head did not parse")
        var per = Float64(perf_counter_ns() - started) / Float64(MICRO_OPS)
        if best < 0 or per < best:
            best = per
    _report("parse-headers", "ns_per_head", "ns", best)


def _parse_hpack(reps: Int) raises:
    """One header block, decoded twenty thousand times, by one decoder.

    One decoder and not one per block, because that is what a connection has.
    Every block is a literal or a static table reference, so the answer does not
    depend on how much the dynamic table has grown by, and the table filling up
    and evicting is part of what a real decoder spends its time on.
    """
    var block = _encoded_request_headers()
    var best = -1.0

    for _ in range(reps):
        var decoder = HpackDecoder()
        var started = perf_counter_ns()
        for _ in range(MICRO_OPS):
            var fields = decoder.decode(Span(block))
            if len(fields) != 8:
                raise Error(String(len(fields), " fields came out, wanted 8"))
        var per = Float64(perf_counter_ns() - started) / Float64(MICRO_OPS)
        if best < 0 or per < best:
            best = per
    _report("parse-hpack", "ns_per_block", "ns", best)


def _encoded_request_headers() raises -> List[UInt8]:
    var fields = List[HeaderField]()
    fields.append(HeaderField(String(":method"), String("GET")))
    fields.append(HeaderField(String(":scheme"), String("https")))
    fields.append(HeaderField(String(":authority"), String("example.com")))
    fields.append(HeaderField(String(":path"), String("/a/b/c?x=1")))
    fields.append(
        HeaderField(String("user-agent"), String("mojo-httpx/0.0.1"))
    )
    fields.append(HeaderField(String("accept"), String("*/*")))
    fields.append(
        HeaderField(String("accept-encoding"), String("gzip, deflate"))
    )
    fields.append(HeaderField(String("cookie"), String("session=8f2b1c")))
    var encoder = HpackEncoder()
    var block = Bytes()
    encoder.encode(fields^, block)
    return block.take_list()


def _parse_url(reps: Int) raises:
    """One URL, parsed twenty thousand times.

    Parsing is what `client.get("https://...")` does before anything else
    happens, so on a fast connection to a nearby server it is a real share of
    the cost of a request.
    """
    var best = -1.0
    for _ in range(reps):
        var started = perf_counter_ns()
        for _ in range(MICRO_OPS):
            var url = URL(SAMPLE_URL)
            if url.host() != "example.com":
                raise Error("the sample URL did not parse")
        var per = Float64(perf_counter_ns() - started) / Float64(MICRO_OPS)
        if best < 0 or per < best:
            best = per
    _report("parse-url", "ns_per_url", "ns", best)


def _cold_start(base: String) raises:
    """Build a client, make one request, stop.

    Nothing is timed here. The driver times the whole process and subtracts a
    process that did nothing, which is the only way to count what happens before
    `main` starts as well as after it.

    No TLS in this one, so no trust store is read and OpenSSL is never opened.
    That is the floor: what a first request costs when none of the expensive
    optional parts are involved. The case below is the same measurement with
    them.
    """
    var client = Client()
    var response = client.get(String(base, "/status/200"))
    if response.status_code != 200:
        raise Error(String("the server answered ", response.status_code))
    client.close()


def _cold_start_tls(base: String) raises:
    """The same again over https, which is what a first request usually is.

    The difference between this and the case above is the part of a cold start
    that people actually wait for: opening OpenSSL, reading a certificate store
    and a handshake. Read it as a lower bound on the store, because the anchor
    here is the one file the test server's certificate was signed with, and a
    machine's own bundle is a few hundred kilobytes of PEM rather than one
    certificate.
    """
    var client = Client(verify=SSLVerify.from_file(TEST_CERT))
    var response = client.get(String(base, "/status/200"))
    if response.status_code != 200:
        raise Error(String("the server answered ", response.status_code))
    client.close()


# Statistics, of which there are two.


def _sort(mut values: List[Float64]):
    """Insertion sort, which is the right one for fifty samples and is here so
    that the suite does not depend on a sort the standard library may move."""
    for i in range(1, len(values)):
        var value = values[i]
        var j = i - 1
        while j >= 0 and values[j] > value:
            values[j + 1] = values[j]
            j -= 1
        values[j + 1] = value


def _percentile(values: List[Float64], rank: Int) raises -> Float64:
    """Nearest rank, on a list that is already sorted.

    Nearest rank rather than an interpolation, so that every number reported is
    one that actually happened. With fifty samples the ninety ninth percentile
    is the slowest of them, which is worth knowing when reading the number: it
    is the tail, measured coarsely, and not a smooth estimate of one.
    """
    if len(values) == 0:
        raise Error("no samples to take a percentile of")
    var at = (rank * len(values) + 99) // 100 - 1
    if at < 0:
        at = 0
    if at >= len(values):
        at = len(values) - 1
    return values[at]
