"""Content codings, undone, with a bound on what a body is allowed to become.

A `Content-Encoding` is the server compressing a body the client asked it to
compress. Undoing it is the only reason `iter_bytes` and `iter_raw` are two
calls rather than one.

Four codings are undone here: gzip and deflate through zlib, `br` through
libbrotlidec and `zstd` through libzstd. All three libraries are opened at run
time, so which of the four are available is a property of the machine rather
than of the build, and `accept_encoding` below asks for exactly the ones that
loaded. That is the whole of the degradation story: a machine without brotli
asks for less and gets larger responses, rather than failing on one.

The thing that makes this security code rather than plumbing is that the size
of the answer is chosen by whoever wrote the compressed bytes. Deflate reaches
1032 to 1 at its theoretical best, so forty kilobytes on the wire can become
forty megabytes in memory, and a few megabytes can become several gigabytes.
zstd and brotli go an order of magnitude further. That is a memory exhaustion
attack with no exploit in it, just a file, and the only defence against it is a
limit. `DecodeLimits` below is that limit, it is on by default, and every
decoder in this package is built with one whichever coding it is for.

The decoder is a push interface rather than an iterator: bytes go in as they
arrive off the connection and plain bytes come back. That is the shape the
streaming path needs, and the buffered path is the streaming one run to the
end. It also means the bound is checked as the body grows rather than after it
has already been allocated, which is the only check worth having.
"""

from httpx._exceptions import ErrorKind, new_error
from httpx._ffi.brotli import (
    BROTLI_RESULT_ERROR,
    BROTLI_RESULT_NEEDS_MORE_INPUT,
    BROTLI_RESULT_SUCCESS,
    BrotliDecoder,
    result_text,
)
from httpx._ffi.brotli import is_available as brotli_available
from httpx._ffi.brotli import unavailable_reason as brotli_problem
from httpx._ffi.zlib import (
    Inflater,
    WINDOW_AUTO,
    WINDOW_RAW,
    WINDOW_ZLIB,
    Z_BUF_ERROR,
    Z_OK,
    Z_STREAM_END,
    code_text,
    is_available,
)
from httpx._ffi.zlib import unavailable_reason as zlib_problem
from httpx._ffi.zstd import ZstdDecoder
from httpx._ffi.zstd import is_available as zstd_available
from httpx._ffi.zstd import unavailable_reason as zstd_problem

comptime DEFAULT_MAX_OUTPUT = 256 * 1024 * 1024
"""How large one decoded body may become, in bytes.

Two hundred and fifty six megabytes. Large enough that no ordinary response
comes near it, small enough that a machine survives one. httpx2 has no such
bound, which is a deviation and is written down as one: there, a compressed
body is trusted about its own size, and the failure is the process rather than
an exception.

A caller who really is downloading something larger raises it deliberately,
which is the point. The bound being wrong for one caller is a line of
configuration, and the bound being absent is a crash for everyone else.
"""

comptime DEFAULT_MAX_RATIO = 1032
"""How many plain bytes one compressed byte may become.

1032 to 1 is deflate's own ceiling, so for gzip and deflate this bound cannot
fire on data that a real encoder produced and it sits behind the output bound
rather than in front of it.

brotli and zstd have no such ceiling, and for them this is a real bound. A zstd
frame built out of RLE blocks turns four bytes into a hundred and twenty eight
kilobytes and can keep that up for as long as the input lasts, which is about
thirty two thousand to one sustained, and brotli's static dictionary does
better still. The number is the same 1032 for all four codings because it is
already far above anything a document compresses to: text and JSON land between
five and fifty to one, and the bodies that go past a thousand are runs of one
byte repeated, which is what a bomb is made of and what a real response is not.

Both bounds are on, so for an ordinary client the output bound is the one that
fires first and this one never gets a chance. It matters for the caller who
raised `max_output` because they genuinely download large things, which is
exactly the caller who has just turned off the other half of the defence.
"""

comptime RATIO_FLOOR = 64 * 1024
"""How much has to arrive before the ratio is worth measuring.

A ratio over a handful of bytes says nothing. A single deflate match copies up
to 258 bytes out of about ten bits, so the running ratio early in a stream
swings far above where it settles, and a bound applied there would reject
ordinary bodies. Sixty four kilobytes in, the number means something.
"""

comptime _SINK = 32 * 1024
"""How much the decoder asks zlib for at a time.

Big enough that a body comes out in a few passes rather than hundreds, small
enough that it is not worth thinking about. Nothing depends on the value.
"""

comptime _SNIFF = 2
"""How many bytes are held back to tell a zlib wrapper from raw deflate."""


struct Coding(Equatable, ImplicitlyCopyable, Movable, Writable):
    """One content coding, as a `Content-Encoding` header names it."""

    var value: Int

    def __init__(out self, value: Int):
        self.value = value

    comptime IDENTITY = Self(0)
    """No coding. The body is what came off the wire."""
    comptime GZIP = Self(1)
    """RFC 1952, which is deflate with a header and a CRC-32 around it."""
    comptime DEFLATE = Self(2)
    """RFC 1950 in theory and RFC 1951 in practice. See `_deflate_window`."""
    comptime BROTLI = Self(3)
    """RFC 7932, spelled `br` in a header. Needs libbrotlidec on the machine."""
    comptime ZSTD = Self(4)
    """RFC 8878. Needs libzstd on the machine."""
    comptime UNKNOWN = Self(-1)
    """A name we do not implement. Never produced by a decoder, only by
    `coding_for`, so that a caller can say something specific about it."""

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value

    def name(self) -> String:
        """The token this coding goes by in a header."""
        if self == Self.GZIP:
            return String("gzip")
        if self == Self.DEFLATE:
            return String("deflate")
        if self == Self.BROTLI:
            return String("br")
        if self == Self.ZSTD:
            return String("zstd")
        if self == Self.IDENTITY:
            return String("identity")
        return String("unknown")

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.name())


def coding_for(name: StringSpan) -> Coding:
    """Read one `Content-Encoding` token.

    Case insensitive, because the grammar says these are tokens and tokens are
    compared case insensitively, and servers do send `GZIP`.

    An empty token is identity. That is not in the grammar, it is what a header
    like `Content-Encoding: gzip, ` produces once it has been split, and
    treating it as nothing is kinder than failing on a stray comma.

    Anything else comes back as `UNKNOWN` rather than raising, so that the
    caller can put the name it did not recognise into its own message.
    """
    var lowered = String(name).lower()
    if lowered == "" or lowered == "identity":
        return Coding.IDENTITY
    if lowered == "gzip" or lowered == "x-gzip":
        return Coding.GZIP
    if lowered == "deflate":
        return Coding.DEFLATE
    if lowered == "br":
        return Coding.BROTLI
    if lowered == "zstd":
        return Coding.ZSTD
    return Coding.UNKNOWN


def missing_library(coding: Coding) -> String:
    """Why this coding cannot be undone here, or the empty string if it can.

    Three of the four codings come from a library loaded at run time, so
    whether one is supported is a property of the machine rather than of the
    build. Everything that has to decide anything about a coding asks this,
    which is what keeps `Accept-Encoding` and the decoder from disagreeing
    about what this process can do.
    """
    if coding == Coding.GZIP or coding == Coding.DEFLATE:
        return zlib_problem()
    if coding == Coding.BROTLI:
        return brotli_problem()
    if coding == Coding.ZSTD:
        return zstd_problem()
    return String()


def accept_encoding() -> String:
    """What to put in `Accept-Encoding`, given what this process can undo.

    A client must not ask for a coding it cannot decode. Doing so gets a body
    back that it has to hand over compressed, or fail on, and both of those are
    worse than the slightly larger response that comes of not asking. So the
    header is built from what actually loaded rather than from what was
    compiled in, and a machine with none of the three libraries sends
    `identity` and gets plain bodies.

    The order is the one httpx2 sends, which is also roughly worst to best, and
    no `q` values. A server picks whichever of these it likes and the order in
    the header is not how it is told to prefer one, so writing preferences here
    would be decoration.
    """
    var out = String()
    if is_available():
        out += "gzip, deflate"
    if brotli_available():
        if out != "":
            out += ", "
        out += "br"
    if zstd_available():
        if out != "":
            out += ", "
        out += "zstd"
    if out == "":
        return String("identity")
    return out^


def _trimmed(piece: StringSpan) raises -> String:
    """One header token with the optional whitespace around it removed.

    Only space and tab, because those are the two the grammar allows between a
    comma and the next token. A newline cannot be here: the header was already
    unfolded by the parser.
    """
    var bytes = piece.as_bytes()
    var start = 0
    var end = len(bytes)
    while start < end and (bytes[start] == 0x20 or bytes[start] == 0x09):
        start += 1
    while end > start and (bytes[end - 1] == 0x20 or bytes[end - 1] == 0x09):
        end -= 1
    return String(StringSpan(from_utf8=bytes[start:end]))


def codings_for(value: StringSpan) raises -> List[Coding]:
    """Read a whole `Content-Encoding` header, in the order the server applied.

    Identity tokens are dropped rather than kept, because they say that nothing
    was done and a decoder for nothing is a decoder that only costs a copy. An
    empty header produces an empty list, which is the ordinary case and is why
    `Headers.get` returning `""` for an absent header is enough here.

    A coding we cannot undo raises. Handing the body over still compressed would
    be worse: the caller asked for content and would get bytes that are not it,
    with `text` and `json` both quietly wrong. We only ever ask for what we can
    decode, so a server sending something else has ignored `Accept-Encoding`,
    and that is worth saying out loud.

    A coding we know the name of but have no library for raises too, and says
    which library is missing. That is a different problem from a name nobody
    recognises, and it is the one somebody can fix.
    """
    var out = List[Coding]()
    for piece in value.split(","):
        var name = _trimmed(piece)
        var coding = coding_for(name)
        if coding == Coding.IDENTITY:
            continue
        if coding == Coding.UNKNOWN:
            raise new_error(
                ErrorKind.PROTOCOL_ERROR,
                String(
                    "the server answered with Content-Encoding: ",
                    name,
                    ", which this client cannot decode and did not ask for",
                ),
            )
        var problem = missing_library(coding)
        if problem != "":
            raise new_error(
                ErrorKind.PROTOCOL_ERROR,
                String(
                    "the server answered with Content-Encoding: ",
                    name,
                    ", which was not asked for on this machine. ",
                    problem,
                ),
            )
        out.append(coding)
    return out^


def decoders_for(
    value: StringSpan, limits: DecodeLimits = DecodeLimits()
) raises -> List[Decoder]:
    """One decoder per coding in a `Content-Encoding` header, ready to run.

    Reversed, because the header lists the codings in the order they were
    applied and undoing them means starting with the last one. A body sent as
    `Content-Encoding: gzip, gzip` was gzipped and then gzipped again, so the
    bytes on the wire are the outer gzip and that is what comes off first.

    Stacked codings are rare enough that refusing them would be tempting, but
    httpx2 handles them and they are legal, so they work here too.
    """
    var codings = codings_for(value)
    var out = List[Decoder]()
    for i in range(len(codings) - 1, -1, -1):
        out.append(Decoder(codings[i], limits))
    return out^


struct DecodeLimits(ImplicitlyCopyable, Movable):
    """What a decoded body is allowed to grow to.

    Zero means no bound, for either of the first two fields, and is what
    `unbounded` produces. It exists for a caller who knows the source, and it
    is not the default, because the whole point of the type is that the source
    is usually a stranger.
    """

    var max_output: Int
    """Bytes of output, over the whole body."""
    var max_ratio: Int
    """Output bytes per input byte, measured once `ratio_floor` has arrived."""
    var ratio_floor: Int
    """Input bytes that have to arrive before the ratio is judged at all."""

    def __init__(
        out self,
        max_output: Int = DEFAULT_MAX_OUTPUT,
        max_ratio: Int = DEFAULT_MAX_RATIO,
        ratio_floor: Int = RATIO_FLOOR,
    ):
        self.max_output = max_output
        self.max_ratio = max_ratio
        self.ratio_floor = ratio_floor

    @staticmethod
    def unbounded() -> Self:
        """No limit on either axis. For a body whose origin is trusted."""
        return Self(0, 0)


def _looks_like_zlib[o: ImmOrigin](head: Span[UInt8, o]) -> Bool:
    """Whether these first two bytes are an RFC 1950 header.

    The low nibble of the first byte is the compression method, which is always
    eight, the high nibble is the window size and never exceeds seven, and the
    two bytes together are a multiple of thirty one. Raw deflate data satisfies
    all three about once in a few thousand streams, which is why this is only
    ever used where the alternative is guessing anyway.
    """
    if len(head) < 2:
        return False
    var cmf = Int(head[0])
    var flg = Int(head[1])
    if cmf & 0x0F != 8:
        return False
    if cmf >> 4 > 7:
        return False
    return (cmf * 256 + flg) % 31 == 0


def _invalid(coding: Coding, reason: String, detail: String) -> Error:
    """The error for a body that its own library would not read.

    Two halves because they answer different questions. `reason` is the
    library's classification, which is what a reader looks up, and `detail` is
    its sentence about this particular body, which is what says whether the
    problem is the header, the checksum or the middle.
    """
    var message = String("this ", coding.name(), " body is not valid: ", reason)
    if detail != "":
        message += String(" (", detail, ")")
    return new_error(ErrorKind.PROTOCOL_ERROR, message)


struct _Step(ImplicitlyCopyable, Movable):
    """What one pass over one of the three libraries did, in shared terms.

    The libraries report themselves differently. zlib returns a code, brotli
    returns one of four results, and zstd returns a byte count that is
    sometimes an error. Reducing all three to these four numbers is what lets
    `_run` below be one loop rather than three, and the loop is the part with
    the bounds check and the member handling in it, which is the part worth
    having once.
    """

    var consumed: Int
    """How many input bytes were taken."""
    var produced: Int
    """How many output bytes were written."""
    var ended: Bool
    """Whether a whole member or frame came to an end on this pass."""
    var stalled: Bool
    """Whether nothing more can happen until more input arrives."""

    def __init__(
        out self, consumed: Int, produced: Int, ended: Bool, stalled: Bool
    ):
        self.consumed = consumed
        self.produced = produced
        self.ended = ended
        self.stalled = stalled


struct Decoder(Movable):
    """One body being decoded, with its bounds and its running totals.

    Not copyable, because it owns the state a compression library allocated for
    it. One decoder belongs to one response body and dies with it, including
    when the body is dropped half read, which is the case the destructors in
    the `_ffi` modules exist for.

    Exactly one of the three backend fields is ever set, chosen by `_coding`.
    Three fields rather than one behind a trait, because a trait object would
    have to be boxed and the alternative is three lines.
    """

    var _coding: Coding
    var _limits: DecodeLimits
    var _inflater: Optional[Inflater]
    var _brotli: Optional[BrotliDecoder]
    var _zstd: Optional[ZstdDecoder]
    var _window: Int
    var _pending: List[UInt8]
    var _consumed: Int
    var _produced: Int
    var _started: Bool
    var _ended: Bool

    def __init__(
        out self, coding: Coding, limits: DecodeLimits = DecodeLimits()
    ) raises:
        """A decoder for `coding`, which must be one this machine can undo.

        The library state is not built here. For `deflate` it cannot be, since
        which of two formats to ask for is a question the first two bytes
        answer, and for the rest it is left until the first bytes arrive so
        that an empty body costs nothing.

        A coding whose library is not on the machine raises, naming the
        library. Reaching this with one of those means something asked for a
        decoder directly, because a response never can: `Accept-Encoding` does
        not name it and `codings_for` refuses it first.
        """
        if coding == Coding.UNKNOWN:
            raise new_error(
                ErrorKind.PROTOCOL_ERROR,
                String("no decoder for this content coding"),
            )
        var problem = missing_library(coding)
        if problem != "":
            raise new_error(ErrorKind.UNSUPPORTED_PROTOCOL, problem)
        self._coding = coding
        self._limits = limits.copy()
        self._inflater = None
        self._brotli = None
        self._zstd = None
        self._window = WINDOW_AUTO
        self._pending = List[UInt8]()
        self._consumed = 0
        self._produced = 0
        self._started = False
        self._ended = False

    def coding(self) -> Coding:
        return self._coding

    def num_bytes_produced(self) -> Int:
        """Plain bytes handed back so far, which is what the bound counts."""
        return self._produced

    def push[
        o: ImmOrigin
    ](mut self, chunk: Span[UInt8, o]) raises -> List[UInt8]:
        """Feed compressed bytes in, take plain bytes out.

        The answer is everything the decoder could produce from everything it
        has been given, which is usually more bytes than went in and is
        sometimes none at all, because a chunk can land entirely inside a
        header or inside a match that is not finished yet.

        Raises when the body is corrupt, when it is not the format its header
        claimed, or when it grew past what the limits allow.
        """
        var out = List[UInt8]()
        if self._coding == Coding.IDENTITY:
            # Not bounded. The output is the input, and whatever produced the
            # input already decided how much of it there was going to be.
            out.extend(chunk)
            return out^
        if len(chunk) == 0:
            return out^
        self._consumed += len(chunk)
        self._started = True

        if self._ended:
            # A gzip body may be several members one after another, and a zstd
            # body several frames, and this is the start of the next one.
            # Anything that is not one makes the restarted decoder fail on its
            # own header, which is the right answer for trailing rubbish.
            self._restart()

        if not self._ready():
            if self._coding == Coding.DEFLATE:
                self._pending.extend(chunk)
                if len(self._pending) < _SNIFF:
                    return out^
                self._window = _deflate_window(Span(self._pending))
                self._inflater = Inflater(self._window)
                # Moved out so that the run below borrows a local rather than a
                # field of the same object it is mutating.
                var held = self._pending^
                self._pending = List[UInt8]()
                self._run(Span(held), out)
                return out^
            self._begin()

        self._run(chunk, out)
        return out^

    def finish(mut self) raises:
        """Say that no more bytes are coming, and check that the body was whole.

        A body that stops in the middle is refused rather than accepted for as
        far as it got. The end of a gzip member carries a CRC-32 and a length,
        a zstd frame carries an XXH64, and brotli carries a last block flag, so
        a truncated one is a body nobody checked, and handing that back as
        content would make a dropped connection look like a short document.

        A body with nothing in it at all is fine. An empty response with a
        `Content-Encoding` on it is what a 204 or a conditional request
        produces, and there is nothing there to be truncated.
        """
        if self._coding == Coding.IDENTITY:
            return
        if not self._started:
            return
        if not self._ended:
            raise new_error(
                ErrorKind.PROTOCOL_ERROR,
                String(
                    "the ",
                    self._coding.name(),
                    " body ended in the middle, after ",
                    self._consumed,
                    " bytes in and ",
                    self._produced,
                    " out",
                ),
            )

    def _ready(self) -> Bool:
        """Whether the backend for this coding has been made yet."""
        if self._coding == Coding.BROTLI:
            return Bool(self._brotli)
        if self._coding == Coding.ZSTD:
            return Bool(self._zstd)
        return Bool(self._inflater)

    def _begin(mut self) raises:
        """Make the backend for this coding, positioned at the start.

        Not reached for `deflate`, which cannot be started until the first two
        bytes have said which of the two formats it is in.
        """
        if self._coding == Coding.BROTLI:
            self._brotli = BrotliDecoder()
            return
        if self._coding == Coding.ZSTD:
            self._zstd = ZstdDecoder()
            return
        self._window = WINDOW_AUTO
        self._inflater = Inflater(self._window)

    def _restart(mut self) raises:
        """Begin a second member or frame of the same stream, same format."""
        if self._coding == Coding.BROTLI:
            self._brotli = BrotliDecoder()
        elif self._coding == Coding.ZSTD:
            # Reset rather than remade. zstd concatenates frames by design, so
            # the library has a call for exactly this and the allocation it
            # already made is worth keeping across it.
            ref decoder = self._zstd.value()
            decoder.reset()
        else:
            self._inflater = Inflater(self._window)
        self._ended = False

    def _step[
        o: ImmOrigin
    ](
        mut self, data: Span[UInt8, o], at: Int, mut sink: List[UInt8]
    ) raises -> _Step:
        """One pass over whichever of the three libraries this coding uses.

        Corruption raises here rather than coming back as a number, because no
        caller has anything to do with it other than fail, and the message
        wants the library's own words in it.
        """
        var coding = self._coding
        if coding == Coding.BROTLI:
            ref decoder = self._brotli.value()
            var got = decoder.step(data, at, sink)
            if got.code == BROTLI_RESULT_ERROR:
                raise _invalid(coding, result_text(got.code), decoder.message())
            return _Step(
                got.consumed,
                got.produced,
                got.code == BROTLI_RESULT_SUCCESS,
                got.code == BROTLI_RESULT_NEEDS_MORE_INPUT,
            )
        if coding == Coding.ZSTD:
            ref decoder = self._zstd.value()
            var got = decoder.step(data, at, sink)
            # zstd reports a bad frame by raising from inside `step`, so
            # anything that comes back here is progress. Nothing having moved
            # is how it says it wants more input.
            return _Step(
                got.consumed,
                got.produced,
                got.ended,
                got.consumed == 0 and got.produced == 0,
            )
        ref decoder = self._inflater.value()
        var got = decoder.step(data, at, sink)
        if got.code == Z_STREAM_END:
            return _Step(got.consumed, got.produced, True, False)
        if got.code == Z_BUF_ERROR:
            # zlib could not move. That is what it says when the input ran out
            # on a boundary, so it is the normal way a chunk ends.
            return _Step(got.consumed, got.produced, False, True)
        if got.code != Z_OK:
            raise _invalid(coding, code_text(got.code), decoder.message())
        return _Step(got.consumed, got.produced, False, False)

    def _run[
        o: ImmOrigin
    ](mut self, data: Span[UInt8, o], mut out: List[UInt8]) raises:
        """Push `data` through the library until it gives nothing back."""
        var sink = List[UInt8](length=_SINK, fill=0)
        var at = 0
        while True:
            var step = self._step(data, at, sink)
            at += step.consumed
            for i in range(step.produced):
                out.append(sink[i])
            self._produced += step.produced
            self._check_bounds()

            if step.ended:
                self._ended = True
                if at >= len(data):
                    return
                self._restart()
                continue
            if step.stalled:
                return
            if step.consumed == 0 and step.produced == 0:
                return
            if at >= len(data) and step.produced < len(sink):
                # Everything given has been taken and the last pass did not
                # fill the buffer, so there is nothing left inside the library.
                return

    def _check_bounds(mut self) raises:
        """Refuse a body that has grown past what it was allowed to.

        Checked after every pass rather than at the end, because the point is
        to stop before the memory is committed, and a check that runs once the
        body is in hand is a check that has already lost.
        """
        if (
            self._limits.max_output > 0
            and self._produced > self._limits.max_output
        ):
            raise new_error(
                ErrorKind.PROTOCOL_ERROR,
                String(
                    "this ",
                    self._coding.name(),
                    " body expanded past the ",
                    self._limits.max_output,
                    " byte limit, from ",
                    self._consumed,
                    " bytes on the wire",
                ),
            )
        if (
            self._limits.max_ratio <= 0
            or self._consumed < self._limits.ratio_floor
        ):
            return
        if self._produced > self._consumed * self._limits.max_ratio:
            raise new_error(
                ErrorKind.PROTOCOL_ERROR,
                String(
                    "this ",
                    self._coding.name(),
                    " body expanded ",
                    self._produced // self._consumed,
                    " times, past the limit of ",
                    self._limits.max_ratio,
                ),
            )


def _deflate_window[o: ImmOrigin](head: Span[UInt8, o]) -> Int:
    """Which of the two deflate formats a body is in, from its first bytes.

    RFC 7230 says `deflate` means RFC 1950, a zlib wrapper around the
    compressed data. A meaningful number of servers send RFC 1951 instead, the
    compressed data with no wrapper at all, because the name says deflate and
    that is what deflate is called. Every browser copes with both and so does
    every other client, so this one does too.

    Sniffing rather than trying and retrying, because a retry means holding on
    to the whole first chunk in case it has to be replayed, and the header is
    two bytes with three constraints on it.
    """
    if _looks_like_zlib(head):
        return WINDOW_ZLIB
    return WINDOW_RAW


def decode_all[
    o: ImmOrigin
](
    coding: Coding,
    source: Span[UInt8, o],
    limits: DecodeLimits = DecodeLimits(),
) raises -> List[UInt8]:
    """Decode a whole body that is already in memory.

    The streaming decoder run to the end, because a second implementation of
    the same thing is a second thing to get wrong. For the buffered path and
    for tests.
    """
    var decoder = Decoder(coding, limits)
    var out = decoder.push(source)
    decoder.finish()
    return out^
