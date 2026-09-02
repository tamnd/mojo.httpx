"""The same TCP socket as `TcpStream`, driven by coroutines instead of blocked
on.

The two streams are deliberately as close to identical as the language allows.
`TcpStream` already loops over a non blocking `recv` and only ever waits by
calling `poll`, so the async version is that loop with the wait replaced and the
result reported through a pointer rather than raised. Nothing else about it
differs, and nothing about the descriptor is reimplemented: this owns a
`TcpStream` and calls the same `try_read` and `try_write` the synchronous path
calls.

Everything that cannot wait, closing, shutting down the write side, asking
whether a byte is already buffered, is a plain method and is forwarded. Only the
calls that can wait are coroutines, which keeps the amount of code that exists
twice down to the loops that genuinely differ.

Every coroutine here is a leaf. None of them awaits another one, they each carry
their own copy of the poll loop, and they each report through a `result` pointer
instead of returning. All three of those are forced by the compiler limits
written up in the docstring of `httpx._io.aio`, and none of them is how this
would be written if the limits went away. A caller drives one of these with
`_run` or hands it to `TaskGroup.create_task`, and cannot call one from inside
another coroutine.

Connecting is split rather than being one call, for the reason on
`finish_connect`: the two ends of a connect raise and only the middle waits.
"""

from std.ffi import c_int

from httpx._exceptions import new_error
from httpx._ffi.c import errno
from httpx._ffi.errno import Op, interrupted, would_block
from httpx._ffi.socket import POLLIN, POLLOUT
from httpx._io.aio import Outcome, poll_slice, slice_for, yield_now
from httpx._io.deadline import Deadline
from httpx._io.socket import PendingConnect, TcpStream


struct AsyncTcpStream(Movable):
    """One connected TCP socket, waited on by giving the worker back.

    Not copyable, for the same reason `TcpStream` is not: two copies would both
    close the same descriptor, and the second close lands on whatever
    connection the number was reused for.
    """

    var _inner: TcpStream

    def __init__(out self, var inner: TcpStream):
        self._inner = inner^

    def fd(self) -> c_int:
        """The raw descriptor. Nothing outside this layer may close it."""
        return self._inner.fd()

    def peer(self) -> String:
        return self._inner.peer()

    def is_open(self) -> Bool:
        return self._inner.is_open()

    def has_data_waiting(self) raises -> Bool:
        """Whether a read right now would return something.

        Not a coroutine, because it does not wait: the poll behind it is
        explicitly zero milliseconds. The pool asks this to tell a reusable idle
        connection from one the server closed underneath it.
        """
        return self._inner.has_data_waiting()

    def is_closed_by_peer(self) raises -> Bool:
        """Whether the far end hung up on an idle connection. Does not wait."""
        return self._inner.is_closed_by_peer()

    def try_read[o: MutOrigin](mut self, buf: Span[UInt8, o]) -> Int:
        """One `recv`, with no waiting. Negative means errno has the reason.

        Exposed so that a driver above this layer can carry its own poll loop.
        The whole of an HTTP exchange has to be one coroutine, because Mojo will
        not let one coroutine await another that suspends in a loop, so the loop
        that reads a response cannot be `read` above and has to be this call
        plus a wait the driver writes out itself.
        """
        return self._inner.try_read(buf)

    def try_write[
        o: ImmOrigin
    ](mut self, data: Span[UInt8, o], offset: Int = 0) -> Int:
        """One `send` from `offset` on, with no waiting. See `try_read`."""
        return self._inner.try_write(data, offset)

    def shutdown_write(mut self):
        """Send a FIN, leaving the socket readable."""
        self._inner.shutdown_write()

    def close(mut self):
        """Release the descriptor. Safe to call more than once."""
        self._inner.close()

    async def read[
        b: MutOrigin, r: MutOrigin
    ](
        mut self,
        buf: Span[UInt8, b],
        deadline: Deadline,
        result: Pointer[Outcome, r],
    ):
        """Read into `buf`, giving way until the deadline for the first byte.

        A count of zero is end of stream and not a failure, the same as on the
        synchronous path.

        The answer goes through `result` rather than coming back as a return
        value because `TaskGroup.create_task` only accepts a coroutine that
        returns nothing, and a read that cannot go in a task group is a read that
        cannot run alongside another one. `_run` callers pass a pointer to a
        local and read it afterwards.

        The wait is written out here rather than delegated to `wait_ready`
        because a coroutine that suspends in a loop cannot be awaited at all. See
        the docstring of `httpx._io.aio`.
        """
        var fd = self._inner.fd()
        var rounds = 0
        result[] = Outcome.waiting()
        while True:
            if deadline.expired():
                result[] = Outcome.from_deadline(deadline, Op.READ)
                break
            var n = self._inner.try_read(buf)
            if n >= 0:
                result[] = Outcome(n)
                break
            var code = errno()
            if interrupted(code):
                continue
            if not would_block(code):
                result[] = Outcome.from_errno(code, Op.READ)
                break
            var got = poll_slice(fd, POLLIN, deadline, slice_for(rounds))
            if got.failed():
                result[] = got
                break
            rounds += 1
            await yield_now()

    async def write[
        d: ImmOrigin, r: MutOrigin
    ](
        mut self,
        data: Span[UInt8, d],
        deadline: Deadline,
        result: Pointer[Outcome, r],
    ):
        """Write all of `data`, looping over short writes.

        A short write is normal rather than an error, so the loop keeps going
        until everything is gone. Treating the return value as all or nothing is
        how a large request body gets silently truncated.

        Reports through `result` and carries its own wait, for the two reasons
        given on `read`. The count that comes back is how much went out, which
        equals the length of `data` unless something failed part way.
        """
        var fd = self._inner.fd()
        var sent = 0
        var rounds = 0
        result[] = Outcome(0)
        while sent < data.__len__():
            if deadline.expired():
                result[] = Outcome.from_deadline(deadline, Op.WRITE)
                break
            var n = self._inner.try_write(data, sent)
            if n > 0:
                sent += n
                result[] = Outcome(sent)
                continue
            var code = errno()
            if interrupted(code):
                continue
            if not would_block(code):
                result[] = Outcome.from_errno(code, Op.WRITE)
                break
            var got = poll_slice(fd, POLLOUT, deadline, slice_for(rounds))
            if got.failed():
                result[] = got
                break
            rounds += 1
            await yield_now()

    async def wait_readable[
        r: MutOrigin
    ](mut self, deadline: Deadline, result: Pointer[Outcome, r]):
        """Give way until a read would return something, or the deadline passes.

        Public for the same reason the synchronous one is: TLS drives its own
        read loop, because OpenSSL asks for more socket data by returning
        WANT_READ rather than by waiting, so the waiting happens one level up.

        The body is `wait_ready` written out again, for the reason on `read`.
        """
        var fd = self._inner.fd()
        var rounds = 0
        result[] = Outcome.waiting()
        while True:
            if deadline.expired():
                break
            var got = poll_slice(fd, POLLIN, deadline, slice_for(rounds))
            if got.is_ready() or got.failed():
                result[] = got
                break
            rounds += 1
            await yield_now()

    async def wait_writable[
        r: MutOrigin
    ](mut self, deadline: Deadline, result: Pointer[Outcome, r]):
        """The same for a write. See `wait_readable`."""
        var fd = self._inner.fd()
        var rounds = 0
        result[] = Outcome.waiting()
        while True:
            if deadline.expired():
                break
            var got = poll_slice(fd, POLLOUT, deadline, slice_for(rounds))
            if got.is_ready() or got.failed():
                result[] = got
                break
            rounds += 1
            await yield_now()


def finish_connect(
    var pending: PendingConnect, got: Outcome, deadline: Deadline
) raises -> AsyncTcpStream:
    """Turn a finished connect wait into a stream, or raise why not.

    The wait itself is `httpx._io.aio.wait_ready` on the pending descriptor with
    POLLOUT, because a non blocking connect finishes by making the socket
    writable and there is nothing else to watch for. Whether it finished by
    connecting or by being refused is in SO_ERROR, and reading that is
    `PendingConnect.finished`, which raises.

    That is why there is no async `open_stream`. Starting a connect and
    finishing one both raise and only the middle waits, so the middle is the
    only part that is a coroutine, and this puts the two ends back together. A
    caller with one connect to make runs the wait with `_run`. Happy Eyeballs
    starts several, waits on all of them in one `TaskGroup`, and finishes
    whichever one won.

    Synchronous, because reading SO_ERROR raises and a coroutine cannot. The
    peer name for the message comes off `pending`, which has carried it since
    the attempt started.

    A wait that came back neither ready nor failed ran out of deadline, and the
    deadline is what words that, so the two ways of running out of time produce
    the same sentence.
    """
    var what = String("connect to ", pending.peer())
    _ = got.check(what)
    if not got.is_ready():
        raise new_error(deadline.kind, deadline.timeout_message(what))
    if not pending.finished():
        raise new_error(deadline.kind, deadline.timeout_message(what))
    return AsyncTcpStream(pending.take_stream())
