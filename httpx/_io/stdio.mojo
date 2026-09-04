"""Writing to the standard streams, byte for byte.

The CLI is the only caller and it needs two things the standard library's
`print` does not give it. Bytes, because a response body is not necessarily
text, and a body that gained a newline or lost an invalid byte on the way to
stdout is not the body the server sent. And a descriptor, because the rule that
decides whether output is decorated is a question about the descriptor rather
than about the program.

The reader going away is not an error here. `httpx URL | head -1` closes the
pipe as soon as it has its line, and a tool that answered that with a failure
message would be wrong in the same way a tool that printed a stack trace for it
would be. On a machine where SIGPIPE still has its default disposition the
process is simply killed, which is what every other command line tool does. On
one where something has already turned SIGPIPE off, and OpenSSL does exactly
that on Linux, the write comes back with EPIPE instead, so `write_all` reports
that as a result rather than raising and the caller stops writing.
"""

from std.ffi import c_int

from httpx._exceptions import ErrorKind, new_error
from httpx._ffi.c import errno, isatty, strerror, write_fd
from httpx._ffi.errno import EPIPE, interrupted

comptime STDOUT = 1
comptime STDERR = 2


def is_terminal(fd: Int) -> Bool:
    """Whether the descriptor is a terminal rather than a file or a pipe."""
    return isatty(c_int(fd)) == c_int(1)


def write_all[o: ImmOrigin](fd: Int, data: Span[UInt8, o]) raises -> Bool:
    """Write all of `data`, looping over short writes.

    True when it was all written. False when the far end of a pipe has closed,
    which is the one failure that is not a failure and which the caller answers
    by writing no more.
    """
    var written = 0
    while written < data.__len__():
        var n = write_fd(
            fd, Pointer(to=data[written]), data.__len__() - written
        )
        if n > 0:
            written += n
            continue
        var code = errno()
        if interrupted(code):
            # A signal arrived part way through. Nothing was lost, so go round
            # again from where it stopped.
            continue
        if code == EPIPE:
            return False
        raise new_error(
            ErrorKind.WRITE_ERROR,
            String("could not write to the output: ", strerror(code)),
        )
    return True


def write_text(fd: Int, text: StringSpan) raises -> Bool:
    """The same, for something already known to be text."""
    return write_all(fd, text.as_bytes())
