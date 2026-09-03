"""Content codings, undone, with a bound on what a body is allowed to become.

A `Content-Encoding` is the server compressing a body the client asked it to
compress. Undoing it is the only reason `iter_bytes` and `iter_raw` are two
calls rather than one.

The thing that makes this security code rather than plumbing is that the size
of the answer is chosen by whoever wrote the compressed bytes. Deflate reaches
1032 to 1 at its theoretical best, so forty kilobytes on the wire can become
forty megabytes in memory, and a few megabytes can become several gigabytes.
That is a memory exhaustion attack with no exploit in it, just a file, and the
only defence against it is a limit. `DecodeLimits` below is that limit, it is
on by default, and every decoder in this package is built with one.

The decoder is a push interface rather than an iterator: bytes go in as they
arrive off the connection and plain bytes come back. That is the shape the
streaming path needs, and the buffered path is the streaming one run to the
end. It also means the bound is checked as the body grows rather than after it
has already been allocated, which is the only check worth having.
"""

from httpx._exceptions import ErrorKind, new_error
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
rather than in front of it. It is here because brotli and zstd have no such
ceiling, they reach into the thousands and the tens of thousands, and when they
land they need a real number rather than a new field.
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
    return Coding.UNKNOWN


def accept_encoding() -> String:
    """What to put in `Accept-Encoding`, given what this process can undo.

    A client must not ask for a coding it cannot decode. Doing so gets a body
    back that it has to hand over compressed, or fail on, and both of those are
    worse than the slightly larger response that comes of not asking. So the
    header is built from what actually loaded rather than from what was
    compiled in, and a machine without zlib sends `identity` and gets plain
    bodies.
    """
    if is_available():
        return String("gzip, deflate")
    return String("identity")


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


struct Decoder(Movable):
    """One body being decoded, with its bounds and its running totals.

    Not copyable, because it owns the state zlib allocated for it. One decoder
    belongs to one response body and dies with it, including when the body is
    dropped half read, which is the case the destructor in `Inflater` exists
    for.
    """

    var _coding: Coding
    var _limits: DecodeLimits
    var _inflater: Optional[Inflater]
    var _window: Int
    var _pending: List[UInt8]
    var _consumed: Int
    var _produced: Int
    var _started: Bool
    var _ended: Bool

    def __init__(
        out self, coding: Coding, limits: DecodeLimits = DecodeLimits()
    ) raises:
        """A decoder for `coding`, which must be one this package implements.

        The zlib state is not built here. For `deflate` it cannot be, since
        which of two formats to ask for is a question the first two bytes
        answer, and for `gzip` it is left until the first bytes arrive so that
        an empty body costs nothing.
        """
        if coding == Coding.UNKNOWN:
            raise new_error(
                ErrorKind.PROTOCOL_ERROR,
                String("no decoder for this content coding"),
            )
        self._coding = coding
        self._limits = limits.copy()
        self._inflater = None
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
            # A gzip body may be several members one after another, and this is
            # the start of the next one. Anything that is not a member makes
            # the new decoder fail on its own header, which is the right
            # answer for trailing rubbish.
            self._restart()

        if not self._inflater:
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
            self._window = WINDOW_AUTO
            self._inflater = Inflater(self._window)

        self._run(chunk, out)
        return out^

    def finish(mut self) raises:
        """Say that no more bytes are coming, and check that the body was whole.

        A body that stops in the middle is refused rather than accepted for as
        far as it got. The end of a gzip member carries a CRC-32 and a length,
        so a truncated one is a body nobody checked, and handing that back as
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

    def _restart(mut self) raises:
        """Begin a second member of the same stream, in the same format."""
        self._inflater = Inflater(self._window)
        self._ended = False

    def _run[
        o: ImmOrigin
    ](mut self, data: Span[UInt8, o], mut out: List[UInt8]) raises:
        """Push `data` through zlib until it stops giving anything back."""
        var sink = List[UInt8](length=_SINK, fill=0)
        var at = 0
        while True:
            ref inflater = self._inflater.value()
            var step = inflater.step(data, at, sink)
            at += step.consumed
            for i in range(step.produced):
                out.append(sink[i])
            self._produced += step.produced
            self._check_bounds()

            if step.code == Z_STREAM_END:
                self._ended = True
                if at >= len(data):
                    return
                self._restart()
                continue
            if step.code == Z_BUF_ERROR:
                # zlib could not move. That is what it says when the input ran
                # out on a boundary, so it is the normal way a chunk ends.
                return
            if step.code != Z_OK:
                raise self._corrupt(step.code)
            if step.consumed == 0 and step.produced == 0:
                return
            if at >= len(data) and step.produced < len(sink):
                # Everything given has been taken and the last pass did not
                # fill the buffer, so there is nothing left inside zlib.
                return

    def _corrupt(mut self, code: Int) -> Error:
        var detail = String()
        if self._inflater:
            ref inflater = self._inflater.value()
            detail = inflater.message()
        var message = String(
            "this ",
            self._coding.name(),
            " body is not valid: ",
            code_text(code),
        )
        if detail != "":
            message += String(" (", detail, ")")
        return new_error(ErrorKind.PROTOCOL_ERROR, message)

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
