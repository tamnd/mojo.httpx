"""Putting a header block back together across `CONTINUATION` frames.

RFC 9113 section 6.10. A header block is one HPACK sequence that may have been
cut into a `HEADERS` frame and any number of `CONTINUATION` frames, and it
cannot be decoded until all of it has arrived, because HPACK is stateful and a
field can straddle a frame boundary. So the whole thing is buffered first and
handed to the decoder once.

That buffer is the attack. Everything in this file exists because of it.

A peer can open a header block and never close it. Each frame is small, legal
and cheap to send, and a receiver with no bound keeps allocating until it dies.
This is CVE-2024-27316 and the family around it, and the important detail is
that bounding the total size is not enough on its own: a `CONTINUATION` frame
may carry an empty fragment, so an attacker can send an unbounded number of
frames that add nothing to the buffer at all. That costs the receiver a read and
a parse each time and costs the sender nine octets, and a size bound never
fires. Both bounds are therefore here, and each has a test that provokes it.

The third rule is section 6.10's own: while a block is open, a frame of any other
type, or a `CONTINUATION` on any other stream, is a connection error. That is
not a bound, it is what makes the two bounds meaningful, since without it a peer
could hold a block open on one stream while doing whatever it liked on others.
"""

from httpx._bytes import Bytes
from httpx._exceptions import ErrorKind, new_error
from httpx._proto.h2.frames import FLAG_END_HEADERS, FrameHeader, FrameType

comptime DEFAULT_MAX_BLOCK_SIZE = 65536
"""How many octets of one header block will be buffered before giving up.

Not a number RFC 9113 gives. It is the compressed size, so it is smaller than
`SETTINGS_MAX_HEADER_LIST_SIZE` bounds after decoding, and it is large enough
that no real request or response comes near it.
"""

comptime DEFAULT_MAX_CONTINUATIONS = 64
"""How many `CONTINUATION` frames may follow one `HEADERS`.

At the default `SETTINGS_MAX_FRAME_SIZE` of 16384 the size bound above is
reached in five frames, so this only ever fires on frames that are mostly or
entirely empty, which is exactly the case it is here for.
"""


def _remote(message: String) -> Error:
    return new_error(ErrorKind.REMOTE_PROTOCOL_ERROR, message)


struct HeaderBlock(Movable):
    """One header block being reassembled, or nothing in progress.

    There is one of these per connection and not one per stream, because RFC
    9113 section 6.10 allows only one block to be open at a time across the
    whole connection.
    """

    var _data: Bytes
    var _stream_id: UInt32
    var _open: Bool
    var _frames: Int

    var max_size: Int
    var max_continuations: Int

    def __init__(
        out self,
        max_size: Int = DEFAULT_MAX_BLOCK_SIZE,
        max_continuations: Int = DEFAULT_MAX_CONTINUATIONS,
    ):
        self._data = Bytes()
        self._stream_id = 0
        self._open = False
        self._frames = 0
        self.max_size = max_size
        self.max_continuations = max_continuations

    def is_open(self) -> Bool:
        """True between a `HEADERS` without `END_HEADERS` and the frame that
        finishes it."""
        return self._open

    def stream_id(self) -> UInt32:
        """Which stream the block in progress belongs to. Zero when none is."""
        return self._stream_id

    def check_allows(self, header: FrameHeader) raises:
        """`PROTOCOL_ERROR`. Refuse anything that may not arrive right now.

        RFC 9113 section 6.10. Called for every frame the connection reads,
        before anything else is done with it. While a block is open the only
        frame that may arrive is a `CONTINUATION` on the same stream, and while
        one is not open a `CONTINUATION` may not arrive at all.
        """
        if self._open:
            if header.type != FrameType.CONTINUATION:
                raise _remote(
                    String(
                        "the server sent a ",
                        header.type.name(),
                        " frame in the middle of a header block on stream ",
                        self._stream_id,
                    )
                )
            if header.stream_id != self._stream_id:
                raise _remote(
                    String(
                        "the server sent a CONTINUATION on stream ",
                        header.stream_id,
                        " in the middle of a header block on stream ",
                        self._stream_id,
                    )
                )
            return

        if header.type == FrameType.CONTINUATION:
            raise _remote(
                String(
                    "the server sent a CONTINUATION on stream ",
                    header.stream_id,
                    " with no header block open",
                )
            )

    def begin[
        o: ImmOrigin
    ](mut self, header: FrameHeader, fragment: Span[UInt8, o]) raises -> Bool:
        """Start a block from a `HEADERS` or `PUSH_PROMISE` fragment.

        True when `END_HEADERS` was set and the block is already complete, which
        is the common case: a request or a response that fits in one frame never
        touches the buffer bounds at all.
        """
        self._data = Bytes()
        self._stream_id = header.stream_id
        self._frames = 0
        self._data.extend(fragment)
        self._check_size(header)

        self._open = not header.has(FLAG_END_HEADERS)
        return not self._open

    def extend[
        o: ImmOrigin
    ](mut self, header: FrameHeader, fragment: Span[UInt8, o]) raises -> Bool:
        """Add a `CONTINUATION` fragment. True when this one finished the block.

        `check_allows` has already established that this frame belongs here, so
        the only things left to refuse are the two bounds.
        """
        self._frames += 1
        if self._frames > self.max_continuations:
            raise _remote(
                String(
                    "the server sent more than ",
                    self.max_continuations,
                    " CONTINUATION frames in one header block on stream ",
                    self._stream_id,
                )
            )

        self._data.extend(fragment)
        self._check_size(header)

        self._open = not header.has(FLAG_END_HEADERS)
        return not self._open

    def take(mut self) raises -> Bytes:
        """The finished block, and reset for the next one.

        Raises if the block is still open, which is our own mistake rather than
        the peer's: `begin` and `extend` both say when they have finished, so
        reaching here early means a caller ignored them.
        """
        if self._open:
            raise new_error(
                ErrorKind.LOCAL_PROTOCOL_ERROR,
                "tried to decode a header block that is still arriving",
            )
        self._stream_id = 0
        self._frames = 0
        var block = self._data^
        self._data = Bytes()
        return block^

    def _check_size(self, header: FrameHeader) raises:
        if len(self._data) > self.max_size:
            raise _remote(
                String(
                    "the server sent a header block of over ",
                    self.max_size,
                    " bytes on stream ",
                    header.stream_id,
                )
            )
