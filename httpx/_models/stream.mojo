"""Where a response body comes from, before anyone has read it.

A body is either already in memory or still arriving on a socket, and the code
that reads it should not have to know which. `ByteStream` is that boundary: pull
a chunk, get bytes back, get an empty chunk when there is no more. Everything
that walks a body, from `read` to the four iterators, is written against this and
nothing else.

An empty chunk means the end and never means "nothing yet". A source that has no
bytes available blocks until it has some or until its deadline runs out, because
a client that treated a pause as an ending would report a truncated body as a
complete one. The chunked reader below the transport already refuses to call a
zero length chunk anything but the terminator, so there is no legitimate empty
chunk in the middle to confuse this with.

`ByteStream` is an erased vtable for the same reason `AnyTransport` is: the
concrete source for a live response is a pooled connection, which lives several
layers above this file, and Mojo 1.0 has no trait objects to hold it with. The
cost is an indirect call per chunk, against a syscall on the other side of it.
"""

from httpx._util.erase import ErasedBox


trait ByteSource(Movable):
    """Something that can be pulled from until it is empty."""

    def read_chunk(mut self) raises -> List[UInt8]:
        """The next piece of the body. Empty means there is no more.

        May return any size. Callers that want a particular size re-chunk on
        top, because a source that had to honour a size would have to buffer,
        and the buffering belongs in one place rather than in every source.
        """
        ...

    def close(mut self):
        """Release whatever is being held, and be safe to call twice.

        Does not raise, for the same reason `Transport.close` does not: there is
        nothing a caller can do about a close that failed, and a close that can
        fail turns every cleanup path into another error path.
        """
        ...


struct ByteStream(Movable):
    """A source whose type has been forgotten, ready to be stored."""

    var _state: ErasedBox
    var _read_chunk: def(ErasedBox) raises thin -> List[UInt8]
    var _close: def(ErasedBox) thin -> None

    def __init__(
        out self,
        var state: ErasedBox,
        read_chunk: def(ErasedBox) raises thin -> List[UInt8],
        close: def(ErasedBox) thin -> None,
    ):
        self._state = state^
        self._read_chunk = read_chunk
        self._close = close

    def copy(self) -> Self:
        """Another handle on the same source, not a second copy of the body.

        Both handles pull from one place, so a chunk read through one is gone
        for the other. That is what makes it safe for an iterator to take a
        handle and for the response to keep one: whoever reads first gets the
        bytes, and the response marks itself consumed at the moment it hands a
        handle out so that nobody reads second by accident.
        """
        return Self(self._state.copy(), self._read_chunk, self._close)

    def read_chunk(mut self) raises -> List[UInt8]:
        return self._read_chunk(self._state)

    def close(mut self):
        self._close(self._state)


def erase_source[T: ByteSource & Deinitable](var source: T) -> ByteStream:
    """Box `source` and build the vtable that reaches back into it.

    The trampolines capture nothing. They recover the concrete type from `T`,
    which is a compile time parameter, so each one is an ordinary function with
    a nameable type rather than a closure.
    """

    def _read_chunk(state: ErasedBox) raises -> List[UInt8]:
        return state.get[T]().read_chunk()

    def _close(state: ErasedBox) -> None:
        state.get[T]().close()

    return ByteStream(ErasedBox.make[T](source^), _read_chunk, _close)


struct BufferedSource(ByteSource, Movable):
    """Bytes that are already in memory, handed over once.

    What a response built in code gets, and what the transport hands over today
    for a body it read to the end before returning. Yielding the whole thing in
    one chunk rather than in pieces is deliberate: the buffer already exists, so
    slicing it up would allocate for no reason, and any caller that wants a
    particular size asks the iterator for one.
    """

    var _content: List[UInt8]
    var _taken: Bool

    def __init__(out self, var content: List[UInt8]):
        self._content = content^
        self._taken = False

    def read_chunk(mut self) raises -> List[UInt8]:
        if self._taken:
            return List[UInt8]()
        self._taken = True
        var out = self._content.copy()
        self._content.clear()
        return out^

    def close(mut self):
        self._taken = True
        self._content.clear()


def buffered_stream(var content: List[UInt8]) -> ByteStream:
    return erase_source(BufferedSource(content^))


def empty_stream() -> ByteStream:
    """A stream with nothing in it.

    Every response holds a stream even when its body is already read, because a
    field has one type and an `Optional` here would put a check in front of
    every pull for a case that only exists at construction.
    """
    return buffered_stream(List[UInt8]())
