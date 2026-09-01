"""Walking a response body a piece at a time.

```mojo
var chunks = response.iter_bytes(4096)
while chunks.has_next():
    process(chunks.next())
```

Three structs, one per shape the body can be asked for: bytes, text, and lines.
Each one pulls from the one below it, so a line is a decoded chunk is a raw
chunk, and the buffering that makes each transition safe happens once.

## Why this is a while loop and not a for loop

Mojo 1.0 drops an error raised out of `__next__`. A `for` loop over an iterator
whose `__next__` raises stops quietly and the error never reaches the caller, so
a connection that died halfway through a body would look exactly like a body
that ended. For an HTTP client that is the worst possible failure: a truncated
response read as a complete one, with nothing anywhere saying so.

So these do not implement the iterator protocol at all. `has_next` and `next`
are ordinary methods, `next` raises the way any other read does, and the error
goes where it should. tests/unit/test_language.mojo pins the compiler behaviour
that forced this, so we find out if it ever changes.

## Chunk sizes

A size of zero means whatever the source produced, which is what httpx2's
`chunk_size=None` means. Any other size is honoured exactly, with only the last
chunk allowed to be short, which means the iterator holds bytes back until it has
a full chunk. `iter_text` counts characters rather than bytes, again matching
httpx2, so a size of three gives three characters however many bytes they took.

An empty chunk is never handed out. The end of the body is `has_next` returning
false, and a caller who saw an empty chunk would have to guess which of the two
it meant.
"""

from httpx._bytes import utf8_width
from httpx._exceptions import ErrorKind, new_error
from httpx._models.stream import ByteStream, buffered_stream
from httpx._util.charset import (
    UTF_8,
    UTF_16,
    UTF_32,
    complete_prefix,
    decode_by_id,
    mark_length,
    resolved_id,
)

comptime _LF = UInt8(0x0A)
comptime _CR = UInt8(0x0D)


def _exhausted() -> Error:
    return new_error(
        ErrorKind.INVALID_ARGUMENT,
        String(
            "next() was called with nothing left to read, check has_next()"
            " first"
        ),
    )


struct ByteChunks(Movable):
    """Raw or decoded bytes, re-chunked to a size the caller asked for."""

    var _stream: ByteStream
    var _pending: List[UInt8]
    var _size: Int
    var _ended: Bool
    var _downloaded: Int
    """How many bytes have come off the stream so far.

    Counted here rather than on the response, because the response gives the
    stream away when it hands out an iterator and cannot see another byte after
    that. This is the only place that watches them arrive, so it is the only
    place that can answer.
    """

    def __init__(out self, var stream: ByteStream, size: Int = 0) raises:
        self._stream = stream^
        self._pending = List[UInt8]()
        self._size = size
        self._ended = False
        self._downloaded = 0
        self._fill()

    def _fill(mut self) raises:
        """Read until there is a whole chunk waiting, or the body ran out.

        The invariant every method here depends on: after this returns, either
        `_pending` holds something or the body is over. That is what lets
        `has_next` be an ordinary non raising method, which is what lets the
        error from a failed read come out of `next` where a caller can catch it.
        """
        while not self._ended:
            if self._size > 0:
                if len(self._pending) >= self._size:
                    return
            elif len(self._pending) > 0:
                return
            var chunk = self._stream.read_chunk()
            if len(chunk) == 0:
                self._ended = True
                self._stream.close()
                return
            self._downloaded += len(chunk)
            self._pending.extend(Span(chunk))

    def num_bytes_downloaded(self) -> Int:
        """How much of the body has arrived, for a progress report.

        Counted as it comes off the stream, so it moves ahead of what `next` has
        handed back when a chunk size is set and a read pulled more than one
        chunk's worth. That is the number a progress bar wants: it is measuring
        the download, not the caller's loop.
        """
        return self._downloaded

    def has_next(self) -> Bool:
        return len(self._pending) > 0

    def next(mut self) raises -> List[UInt8]:
        if len(self._pending) == 0:
            raise _exhausted()

        var take = len(self._pending)
        if self._size > 0 and self._size < take:
            take = self._size

        var out = List[UInt8](capacity=take)
        for i in range(take):
            out.append(self._pending[i])

        var rest = List[UInt8](capacity=len(self._pending) - take)
        for i in range(take, len(self._pending)):
            rest.append(self._pending[i])
        self._pending = rest^

        self._fill()
        return out^

    def close(mut self):
        self._ended = True
        self._pending.clear()
        self._stream.close()


struct TextChunks(Movable):
    """The body decoded to text, in chunks of a given number of characters."""

    var _bytes: ByteChunks
    var _held: List[UInt8]
    """Bytes that arrived but cannot be decoded yet.

    The tail of a character whose remaining bytes are in the next chunk. This is
    the whole reason `iter_text` is not `decode(chunk)` in a loop: without it,
    every multi byte character that happened to straddle a network boundary
    would come out as two replacement characters, and which characters those
    were would depend on the size of the server's writes.
    """

    var _text: List[UInt8]
    """Decoded text waiting to be handed out, as UTF-8."""

    var _id: Int
    var _resolved: Bool
    """Whether the byte order has been settled from the opening bytes.

    Only means anything for `utf-16` and `utf-32`. It has to happen once, at the
    front, because the mark is only in the first chunk and a later chunk decoded
    on its own would guess.
    """

    var _size: Int

    def __init__(
        out self,
        var stream: ByteStream,
        encoding_id: Int = UTF_8,
        size: Int = 0,
    ) raises:
        self._bytes = ByteChunks(stream^)
        self._held = List[UInt8]()
        self._text = List[UInt8]()
        self._id = encoding_id
        self._resolved = False
        self._size = size
        self._fill()

    def _resolve(mut self):
        """Settle the byte order and drop the mark, once there is enough to look
        at.

        Only `utf-16` and `utf-32` have anything to settle, and only those two
        wait: two bytes for one and four for the other. Every other encoding
        resolves on the first byte, because holding text back for a mark that
        cannot be there would delay the first chunk of every ordinary body.

        A body that ended before the mark did resolves anyway. There is nothing
        more coming, so the guess has to be made now.
        """
        if self._resolved:
            return
        var need = 0
        if self._id == UTF_16:
            need = 2
        elif self._id == UTF_32:
            need = 4
        if len(self._held) < need and self._bytes.has_next():
            return
        var view = Span(self._held)
        var skip = mark_length(view, self._id)
        self._id = resolved_id(view, self._id)
        if skip > 0:
            var rest = List[UInt8]()
            for i in range(skip, len(self._held)):
                rest.append(self._held[i])
            self._held = rest^
        self._resolved = True

    def _drain(mut self, everything: Bool):
        """Decode as much of `_held` as is safely complete."""
        if not self._resolved:
            return
        var cut = len(self._held)
        if not everything:
            cut = complete_prefix(Span(self._held), self._id)
        if cut == 0:
            return
        var text = decode_by_id(Span(self._held)[:cut], self._id)
        self._text.extend(text.as_bytes())
        var rest = List[UInt8]()
        for i in range(cut, len(self._held)):
            rest.append(self._held[i])
        self._held = rest^

    def _fill(mut self) raises:
        while True:
            if self._size > 0:
                if _characters(self._text) >= self._size:
                    return
            elif len(self._text) > 0:
                return
            if not self._bytes.has_next():
                # The body is over. Whatever is still held back is never going
                # to be completed, so it is decoded now and its broken tail
                # becomes a replacement character rather than disappearing.
                self._resolve()
                self._drain(True)
                return
            self._held.extend(Span(self._bytes.next()))
            self._resolve()
            self._drain(False)

    def num_bytes_downloaded(self) -> Int:
        """How much of the body has arrived, in bytes rather than characters.

        Bytes because that is what a progress report is against: the length the
        server announced is a byte count, and the character count is not known
        until the last one is decoded.
        """
        return self._bytes.num_bytes_downloaded()

    def has_next(self) -> Bool:
        return len(self._text) > 0

    def next(mut self) raises -> String:
        if len(self._text) == 0:
            raise _exhausted()

        var take = len(self._text)
        if self._size > 0:
            take = _byte_offset(self._text, self._size)

        var out = String(StringSpan(from_utf8=Span(self._text)[:take]))
        var rest = List[UInt8]()
        for i in range(take, len(self._text)):
            rest.append(self._text[i])
        self._text = rest^

        self._fill()
        return out^

    def close(mut self):
        self._bytes.close()
        self._held.clear()
        self._text.clear()


struct LineChunks(Movable):
    """The body decoded to text and split into lines, without the terminators.
    """

    var _text: TextChunks
    var _pending: List[UInt8]
    var _lines: List[String]
    var _at: Int
    """How many of `_lines` have been handed out.

    A cursor rather than removing from the front, because a chunk of text often
    holds a hundred lines and shifting the list down for each one turns a scan
    into a quadratic one.
    """

    def __init__(
        out self, var stream: ByteStream, encoding_id: Int = UTF_8
    ) raises:
        self._text = TextChunks(stream^, encoding_id)
        self._pending = List[UInt8]()
        self._lines = List[String]()
        self._at = 0
        self._fill()

    def _fill(mut self) raises:
        while self._at >= len(self._lines):
            self._lines.clear()
            self._at = 0
            if not self._text.has_next():
                # End of body. A line that never got a terminator is still a
                # line, but an empty remainder is not: a body ending in a
                # newline has no trailing blank line, which is what `splitlines`
                # gives and therefore what httpx2 gives.
                self._split(True)
                if len(self._pending) > 0:
                    self._lines.append(
                        String(StringSpan(from_utf8=Span(self._pending)))
                    )
                    self._pending.clear()
                return
            self._pending.extend(self._text.next().as_bytes())
            self._split(False)

    def _split(mut self, ended: Bool) raises:
        var n = len(self._pending)
        var start = 0
        var at = 0
        while at < n:
            var width = _break_width(self._pending, at, n, ended)
            if width == 0:
                at += 1
                continue
            var line = List[UInt8]()
            for i in range(start, at):
                line.append(self._pending[i])
            self._lines.append(String(StringSpan(from_utf8=Span(line))))
            at += width
            start = at
        if start > 0:
            var rest = List[UInt8]()
            for i in range(start, n):
                rest.append(self._pending[i])
            self._pending = rest^

    def num_bytes_downloaded(self) -> Int:
        """How much of the body has arrived, in bytes rather than lines."""
        return self._text.num_bytes_downloaded()

    def has_next(self) -> Bool:
        return self._at < len(self._lines)

    def next(mut self) raises -> String:
        if self._at >= len(self._lines):
            raise _exhausted()
        var out = self._lines[self._at].copy()
        self._at += 1
        self._fill()
        return out^

    def close(mut self):
        self._text.close()
        self._pending.clear()
        self._lines.clear()
        self._at = 0


def _break_width(text: List[UInt8], at: Int, n: Int, ended: Bool) -> Int:
    """How many bytes the line break at `at` takes, or zero if there is none.

    The separators are the ones Python's `str.splitlines` uses, because that is
    what httpx2's line decoder reproduces and parity is the point. So a form
    feed, a file separator and U+2028 all end a line here, not only the three
    everybody thinks of.

    A carriage return at the very end of what has arrived so far is not a break
    yet. Its partner may be the first byte of the next chunk, and calling it a
    break now would turn one `\\r\\n` into two lines the moment a server split
    its writes between them.
    """
    var byte = text[at]

    if byte == _CR:
        if at + 1 < n:
            if text[at + 1] == _LF:
                return 2
            return 1
        if ended:
            return 1
        return 0

    if byte == _LF or byte == 0x0B or byte == 0x0C:
        return 1
    if byte >= 0x1C and byte <= 0x1E:
        return 1

    # U+0085, the next line character, which is two bytes in UTF-8.
    if byte == 0xC2 and at + 1 < n and text[at + 1] == 0x85:
        return 2

    # U+2028 and U+2029, the line and paragraph separators, three bytes each.
    if byte == 0xE2 and at + 2 < n and text[at + 1] == 0x80:
        if text[at + 2] == 0xA8 or text[at + 2] == 0xA9:
            return 3

    return 0


def _characters(text: List[UInt8]) -> Int:
    """How many characters are in a run of valid UTF-8."""
    var count = 0
    var at = 0
    while at < len(text):
        at += _step(text[at])
        count += 1
    return count


def _byte_offset(text: List[UInt8], characters: Int) -> Int:
    """Where the character at index `characters` starts.

    The end of the run if there are fewer characters than that, so a caller
    asking for more than is there gets everything rather than an error.
    """
    var count = 0
    var at = 0
    while at < len(text) and count < characters:
        at += _step(text[at])
        count += 1
    if at > len(text):
        return len(text)
    return at


def _step(lead: UInt8) -> Int:
    """How many bytes the character starting with `lead` takes.

    Never zero. The buffers this walks were produced by the decoder and are
    valid UTF-8, but a step of zero would be an infinite loop rather than a
    wrong answer, so a byte that cannot be a lead advances by one anyway.
    """
    var width = Int(utf8_width(lead))
    if width < 1:
        return 1
    return width
