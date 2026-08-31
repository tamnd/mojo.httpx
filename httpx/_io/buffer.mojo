"""A read buffer with a cursor, which is what incremental parsing needs.

An HTTP/1.1 response arrives in whatever sized pieces the network felt like
delivering. The parser has to be able to look at everything that has arrived so
far, decide it does not yet have a whole message, and be called again when more
turns up without having lost anything or copied it twice. That is the entire job
of this type.

One buffer lives on each connection and is reused across requests, which is what
makes the steady state free of allocation once the connection has warmed up. The
cost of that is a cursor that has to be moved and a tail that has to be moved to
the front, and getting the compaction rule wrong is how a client ends up
quadratic on a large body.

The rule here is to compact only when the consumed prefix is at least half the
buffer. That bounds the total bytes moved to twice the bytes read, whatever
pattern the reads arrive in, because each compaction moves at most as many bytes
as were consumed to earn it.
"""

from httpx._bytes import index_of_span

comptime DEFAULT_CAPACITY = 8192
"""One buffer's starting size.

Large enough for a response head in a single read on nearly every real server,
small enough that a pool holding a hundred idle connections is not carrying a
megabyte of empty buffers.
"""


struct ByteBuffer(Movable, Sized, Writable):
    """Bytes that have arrived, and how far the parser has read into them."""

    var _data: List[UInt8]
    var _start: Int
    """Where the unread bytes begin. Everything before this has been consumed.
    """

    def __init__(out self, capacity: Int = DEFAULT_CAPACITY):
        self._data = List[UInt8](capacity=capacity)
        self._start = 0

    def copy(self) -> Self:
        var out = Self(capacity=len(self._data))
        out._data = self._data.copy()
        out._start = self._start
        return out^

    def __len__(self) -> Int:
        """How many bytes are unread. The consumed prefix does not count."""
        return len(self._data) - self._start

    def is_empty(self) -> Bool:
        return len(self._data) == self._start

    def unread(ref self) -> Span[UInt8, origin_of(self._data)]:
        """Everything that has arrived and not yet been consumed.

        The parser works on this and never on the whole allocation, so a
        compaction that has not happened yet is invisible to it.
        """
        return Span(self._data)[self._start : len(self._data)]

    def peek(self, offset: Int) -> UInt8:
        """The unread byte at `offset`, which the caller has bounds checked.

        Returns zero past the end rather than trapping, because every caller is
        a parser that has already asked `__len__` and a trap here would turn a
        parser bug into a crash rather than into a failing test.
        """
        var at = self._start + offset
        return self._data[at] if at < len(self._data) else UInt8(0)

    def extend[o: ImmOrigin](mut self, source: Span[UInt8, o]):
        """Add bytes that just arrived off the wire."""
        self._data.extend(source)

    def consume(mut self, count: Int):
        """Mark `count` unread bytes as read.

        Compaction happens here rather than on the next read, so that a parser
        that consumes a head and then asks for the body sees the body at the
        front of the buffer and the next read into it has room.
        """
        self._start += count
        if self._start > len(self._data):
            self._start = len(self._data)
        self._maybe_compact()

    def take(mut self, count: Int) -> List[UInt8]:
        """Consume `count` bytes and hand them back as their own list.

        A copy, deliberately. The alternative is a span into a buffer that the
        next read is about to move, which is the kind of API that works in every
        test and fails on the first response that arrives in two pieces.
        """
        var n = count if count <= len(self) else len(self)
        var out = List[UInt8](capacity=n)
        out.extend(Span(self._data)[self._start : self._start + n])
        self.consume(n)
        return out^

    def find[o: ImmOrigin](self, needle: Span[UInt8, o]) -> Int:
        """Where `needle` starts in the unread bytes, or -1.

        The offset is relative to the unread region, so it can be passed
        straight to `consume` or `take` without the caller knowing where the
        cursor happens to be.
        """
        return index_of_span(Span(self._data)[self._start :], needle)

    def clear(mut self):
        """Drop everything, keeping the allocation for the next request."""
        self._data.clear()
        self._start = 0

    def _maybe_compact(mut self):
        """Move the unread tail to the front when the prefix has earned it.

        The half the buffer threshold is what keeps this amortised. Compacting
        on every consume would copy the remaining bytes once per parsed line,
        which on a response with many headers is quadratic in the size of the
        head.
        """
        if self._start == 0:
            return
        if self._start == len(self._data):
            self._data.clear()
            self._start = 0
            return
        if self._start * 2 < len(self._data):
            return
        var remaining = len(self._data) - self._start
        for i in range(remaining):
            self._data[i] = self._data[self._start + i]
        self._data.resize(remaining, UInt8(0))
        self._start = 0

    def write_to[W: Writer](self, mut writer: W):
        writer.write(
            len(self._data) - self._start,
            " unread of ",
            len(self._data),
            " buffered",
        )
