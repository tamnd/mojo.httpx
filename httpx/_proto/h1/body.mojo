"""Reading a response body, once the framing has been decided.

Like the head parser this never blocks and never reads a socket. It is handed a
buffer holding whatever has arrived, takes what it can understand out of it, and
says whether it wants more. Everything that makes streaming work is a
consequence of that shape: the caller decides how much to read at a time, when
to stop, and where the bytes go.

The framing decision is made once, before any of this runs, and is not revisited
while the body is being read. A body whose end is redecided halfway through is
the other way a smuggling bug gets in, so `BodyReader` takes a `Framing` and
never looks at a header again.

Chunked framing is read strictly, with `\\r\\n` required everywhere RFC 9112
section 7.1 asks for it. The head parser accepts a bare newline because real
servers write heads by hand and get it wrong; chunk framing is emitted by
machines that all get it right, so a bare newline in it is either damage or
somebody counting on this end and the next one splitting the stream in different
places.
"""

from httpx._bytes import _CR, _LF, parse_hex
from httpx._exceptions import ErrorKind, new_error
from httpx._io.buffer import ByteBuffer
from httpx._models.headers import Headers
from httpx._proto.h1.framing import BodyMode, Framing
from httpx._proto.h1.head import (
    MAX_HEADERS,
    append_field_line,
    index_of_lf,
    line_without_terminator,
)

comptime MAX_CHUNK_LINE = 1024
"""How long a chunk size line may be, in bytes.

A size is at most sixteen hex digits and the extensions nobody uses are short.
Without a bound a server can hold a client's memory hostage with a size line it
never terminates, which is a denial of service that costs the attacker one open
socket.
"""

comptime MAX_TRAILERS = MAX_HEADERS
"""Trailers get the same bound as headers, for the same reason."""


struct _Step(Equatable, ImplicitlyCopyable, Movable):
    """Where a chunked read has got to.

    Explicit rather than inferred from the counters, because "no bytes left in
    this chunk" and "no chunks left" are different states that would otherwise
    look identical, and confusing them is how a decoder stops one `\\r\\n` early.
    """

    var value: Int

    comptime SIZE = Self(0)
    comptime DATA = Self(1)
    comptime DATA_END = Self(2)
    comptime TRAILERS = Self(3)
    comptime DONE = Self(4)

    def __init__(out self, value: Int):
        self.value = value

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value


def _remote(message: String) -> Error:
    return new_error(ErrorKind.REMOTE_PROTOCOL_ERROR, message)


struct BodyReader(Movable):
    """Turns whatever arrived into body bytes, one call at a time."""

    var framing: Framing
    var trailers: Headers
    """Empty except after a chunked body that carried some."""

    var _remaining: Int
    """Bytes still owed by the current frame. Meaning depends on the mode."""

    var _step: _Step
    var _complete: Bool
    var _saw_trailers: Int

    def __init__(out self, framing: Framing):
        self.framing = framing
        self.trailers = Headers()
        self._remaining = framing.length
        self._step = _Step.SIZE
        self._saw_trailers = 0
        # A body of no bytes is complete before anything is read. Saying so up
        # front is what stops a caller polling a socket for a 204.
        self._complete = not framing.has_body() or (
            framing.mode == BodyMode.LENGTH and framing.length == 0
        )

    def is_complete(self) -> Bool:
        return self._complete

    def take_trailers(mut self) -> Headers:
        """The trailers, leaving the reader with none.

        Swapped out for the same reason the head's are: a field with a
        destructor cannot be moved out of a value that still has to be
        destroyed.
        """
        var out = Headers()
        swap(out, self.trailers)
        return out^

    def read_from(
        mut self, mut buf: ByteBuffer, mut out: List[UInt8]
    ) raises -> Bool:
        """Move what can be decoded from `buf` into `out`.

        Returns whether more bytes from the network are needed. A false return
        means the body ended, and the bytes left in `buf` belong to whatever
        comes next rather than to this message.
        """
        if self._complete:
            return False
        if self.framing.mode == BodyMode.LENGTH:
            return self._read_length(buf, out)
        if self.framing.mode == BodyMode.CHUNKED:
            return self._read_chunked(buf, out)
        return self._read_until_close(buf, out)

    def at_eof(mut self) raises:
        """Tell the reader the peer closed, which for one mode is the ending.

        For every other mode a close is a truncated body. Reporting that rather
        than handing back what arrived is the difference between a caller that
        retries and a caller that silently acts on half a response.
        """
        if self._complete:
            return
        if self.framing.mode == BodyMode.UNTIL_CLOSE:
            self._complete = True
            return
        if self.framing.mode == BodyMode.LENGTH:
            raise _remote(
                String(
                    "the server closed with ",
                    self._remaining,
                    " bytes of the body still to come",
                )
            )
        raise _remote("the server closed in the middle of a chunked body")

    def _read_length(
        mut self, mut buf: ByteBuffer, mut out: List[UInt8]
    ) raises -> Bool:
        var take = len(buf)
        if take > self._remaining:
            # Anything past the declared length is the start of the next
            # message, not part of this one, and taking it would desync the
            # connection for every request after this one.
            take = self._remaining
        if take > 0:
            out.extend(buf.unread()[:take])
            buf.consume(take)
            self._remaining -= take
        if self._remaining == 0:
            self._complete = True
            return False
        return True

    def _read_until_close(
        mut self, mut buf: ByteBuffer, mut out: List[UInt8]
    ) raises -> Bool:
        """Everything is body, and only a close says it ended.

        Which is why `at_eof` has to be called for this mode. There is nothing
        in the bytes that says the body is done.
        """
        var take = len(buf)
        if take > 0:
            out.extend(buf.unread()[:take])
            buf.consume(take)
        return True

    def _read_chunked(
        mut self, mut buf: ByteBuffer, mut out: List[UInt8]
    ) raises -> Bool:
        while True:
            if self._step == _Step.SIZE:
                var line_end = self._line_end(buf, MAX_CHUNK_LINE)
                if line_end < 0:
                    return True
                _require_crlf(buf, line_end)
                var line = line_without_terminator(buf.unread(), 0, line_end)
                self._remaining = _parse_chunk_size(line)
                buf.consume(line_end + 1)
                if self._remaining == 0:
                    self._step = _Step.TRAILERS
                else:
                    self._step = _Step.DATA
                continue

            if self._step == _Step.DATA:
                var take = len(buf)
                if take > self._remaining:
                    take = self._remaining
                if take > 0:
                    out.extend(buf.unread()[:take])
                    buf.consume(take)
                    self._remaining -= take
                if self._remaining > 0:
                    return True
                self._step = _Step.DATA_END
                continue

            if self._step == _Step.DATA_END:
                # The `\r\n` after the data is framing, not body. Checked byte
                # by byte rather than by finding the next line, because a chunk
                # whose data ran past its declared size has to be an error right
                # here. A decoder that instead resynchronised on the next `\r\n`
                # would happily read an attacker's bytes as the next chunk.
                if len(buf) == 0:
                    return True
                if buf.peek(0) != _CR:
                    raise _remote(
                        "the server sent a chunk longer than its size"
                    )
                if len(buf) < 2:
                    return True
                if buf.peek(1) != _LF:
                    raise _remote(
                        "the server sent a chunk longer than its size"
                    )
                buf.consume(2)
                self._step = _Step.SIZE
                continue

            if self._step == _Step.TRAILERS:
                var line_end = self._line_end(buf, MAX_CHUNK_LINE)
                if line_end < 0:
                    return True
                _require_crlf(buf, line_end)
                var line = line_without_terminator(buf.unread(), 0, line_end)
                if line.__len__() == 0:
                    buf.consume(line_end + 1)
                    self._step = _Step.DONE
                    self._complete = True
                    return False
                self._saw_trailers += 1
                if self._saw_trailers > MAX_TRAILERS:
                    raise _remote(
                        String(
                            "the server sent more than ",
                            MAX_TRAILERS,
                            " trailers",
                        )
                    )
                append_field_line(self.trailers, line)
                buf.consume(line_end + 1)
                continue

            return False

    def _line_end(self, buf: ByteBuffer, limit: Int) raises -> Int:
        """Where the next line ends, or -1, refusing to wait past `limit`.

        The bound is checked whether or not the line has arrived. Checking only
        complete lines would mean a server that sends a megabyte and no newline
        gets a megabyte of our memory before anybody objects.
        """
        var found = index_of_lf(buf.unread(), 0)
        if found < 0:
            if len(buf) > limit:
                raise _remote(
                    String(
                        "the server sent a chunked framing line longer than ",
                        limit,
                        " bytes",
                    )
                )
            return -1
        if found > limit:
            raise _remote(
                String(
                    "the server sent a chunked framing line longer than ",
                    limit,
                    " bytes",
                )
            )
        return found


def _require_crlf(buf: ByteBuffer, line_end: Int) raises:
    """A chunked framing line has to end with `\\r\\n` and nothing shorter.

    The leniency the head parser allows is not extended down here. In a head a
    bare newline is a server that was written by a person. In chunk framing it
    is a line whose end this parser and the reference one disagree about, and
    every byte of that disagreement is body to one of them and framing to the
    other.
    """
    if line_end == 0 or buf.peek(line_end - 1) != _CR:
        raise _remote(
            "the server ended a chunked framing line with a bare newline"
        )


def _parse_chunk_size[o: ImmOrigin](line: Span[UInt8, o]) raises -> Int:
    """The size at the front of a chunk header line.

    Extensions after a semicolon are allowed by RFC 9112 section 7.1.1 and are
    discarded. Nothing in the wild uses them, and a client that tried to act on
    one would be acting on something the server has no reason to think it read.

    Nothing else is allowed around the size, not even a space. The grammar in
    section 7.1 is `1*HEXDIG` and the chunk extension rule permits some bad
    whitespace before the semicolon, but a size line with a stray space is not a
    server being sloppy in a way that has one meaning. It is a line that one
    parser reads as a size and another reads as an error, and on a chunked body
    that disagreement is where the next request goes.
    """
    var end = line.__len__()
    for i in range(line.__len__()):
        if line[i] == UInt8(ord(";")):
            end = i
            break
    var digits = line[:end]
    if digits.__len__() == 0:
        raise _remote("the server sent a chunk with no size")
    try:
        var size = parse_hex(digits)
        return size
    except:
        raise _remote("the server sent a chunk size that is not a hex number")
