"""C types and the errno plumbing that every other `_ffi` module builds on.

Mojo 1.0 has no networking in the standard library, so the whole transport
layer sits on libc. This module is the bottom of that stack. It owns the type
aliases, the errno access, and the handful of utilities that every syscall
wrapper needs.

Nothing here is public API. Everything is reachable from `httpx._ffi` and
nowhere else, and the layering lint enforces that.

Three conventions are worth knowing before reading any other `_ffi` module,
because all three are places where Mojo 1.0 differs from what a C programmer
expects.

Pointers. `Pointer` carries an origin and C has none, so every pointer crossing
the boundary uses `MutAnyOrigin` through the `Ptr` alias below and the compiler
stops helping. That is the reason these pointers are confined to this
directory.

Null. `Pointer` is non-nullable and the compiler enforces it. A C function that
can return null is declared as returning `Optional[Ptr[T]]`, which is exactly
eight bytes with null as the empty case, so it is the same value on the wire
and a real `if` on the Mojo side.

C strings. A Mojo `String` is not nul terminated. Passing one straight to libc
reads off the end of the allocation. Use `c_string` below, which appends the
terminator and rejects an interior nul. That rejection is not a formality: a
header value or a hostname carrying an embedded nul is the classic way to make
a C API see a shorter string than the one that was validated.
"""

from std.ffi import (
    CStringSlice,
    c_char,
    c_int,
    c_size_t,
    c_ssize_t,
    c_uint,
    external_call,
)
from std.sys import CompilationTarget, size_of

from httpx._exceptions import ErrorKind, new_error


# The one unsafe primitive the rest of this directory is built on. Sound only
# because every pointer spelled this way is confined to `_ffi`, points at a
# buffer whose lifetime the caller keeps alive across the call, and is checked
# for null on the C side by being declared `Optional[Ptr[T]]`. See below.
comptime Ptr[T: AnyType] = Pointer[T, MutUntrackedOrigin]
"""A raw C pointer. Write `Ptr[c_int]` where C would write `int *`.

Use `Optional[Ptr[T]]` wherever C could hand back null.

The origin is `MutUntrackedOrigin` rather than `MutAnyOrigin` because a struct
field is not allowed to expose `AnyOrigin`, and several of these pointers are
held in a struct that frees them. Untracked is the compiler's way of being told
that the lifetime is managed by hand, which for memory the C library allocated
is simply true.
"""

comptime CStr = CStringSlice[ImmStaticOrigin]
"""A `const char *` that libc owns for the life of the process.

Only for strings the C library owns, like the return of `strerror` or
`gai_strerror`. For a string we built, keep the allocation alive yourself and
pass a `CStringSlice` over it.
"""

comptime socklen_t = c_uint
"""`socklen_t` is `unsigned int` on both platforms we support."""

comptime _ERRNO_LOCATION = "__error" if CompilationTarget.is_macos() else "__errno_location"
"""glibc and the BSD libc disagree on the name of the thread local errno slot."""


def c_string(out result: String, s: StringSpan):
    """Copy `s` into a buffer that is safe to hand to libc.

    The result must stay alive for as long as C is looking at it, so bind it to
    a variable rather than passing `c_string(x)` straight into `external_call`.
    Pass it as `CStringSlice(buf)`, which is where an interior nul is caught.
    """
    result = String(s, "\0")


def errno() -> c_int:
    """The current value of errno on this thread.

    Only meaningful straight after a libc call that reported failure. libc is
    free to clobber errno on success, so never read it without first checking
    the return value.
    """
    return external_call[_ERRNO_LOCATION, Ptr[c_int]]()[]


def set_errno(code: c_int):
    """Write errno directly.

    Only for a wrapper that detected a failure libc did not report, so that the
    caller can read the result the same way it reads every other one instead of
    learning a second convention. See `set_nonblocking`.
    """
    external_call[_ERRNO_LOCATION, Ptr[c_int]]()[] = code


def clear_errno():
    """Set errno to zero.

    A few calls, `getaddrinfo` among them, report failure through their return
    value and only sometimes touch errno. Clearing first makes a stale value
    from an earlier call impossible to misread.
    """
    set_errno(c_int(0))


def strerror(code: c_int) -> String:
    """The libc description of an errno value.

    We copy the bytes out immediately, because `strerror` may return a pointer
    into a static buffer that the next call overwrites.
    """
    return cstr_to_string(external_call["strerror", CStr](code))


def getenv(name: StringSpan) raises -> Optional[String]:
    """One environment variable, or nothing when it is not set.

    An empty variable comes back as an empty string rather than as nothing,
    because `SSL_CERT_DIR=` set to empty is a user saying something different
    from not setting it, and the caller is entitled to tell the two apart.

    The value is copied straight away. `getenv` returns a pointer into the
    process environment block, which any later `setenv` from any thread is free
    to move.
    """
    var key = c_string(name)
    var found = external_call["getenv", Optional[Ptr[c_char]]](
        CStringSlice(key)
    )
    if not found:
        return None
    return cstr_to_string(CStringSlice(unsafe_from_ptr=found.value()))


def setenv(name: StringSpan, value: StringSpan) raises:
    """Set one environment variable for this process.

    The library never calls this. It is here because the code that reads
    `HTTP_PROXY` and `NO_PROXY` has to be tested against a real environment, and
    a reader that is only exercised through an injected table is a reader whose
    lookup rules are not tested at all. Since the tests set variables the
    process really has, the calls belong in the same shim as `getenv` rather
    than in a corner of the test suite reaching for libc on its own.

    Overwrites, because a test that has to remember whether it is the first
    caller is a test that will one day be second.
    """
    var key = c_string(name)
    var held = c_string(value)
    _ = external_call["setenv", c_int](
        CStringSlice(key), CStringSlice(held), c_int(1)
    )


def unsetenv(name: StringSpan) raises:
    """Remove one environment variable. See `setenv` for why this exists."""
    var key = c_string(name)
    _ = external_call["unsetenv", c_int](CStringSlice(key))


def random_bytes(count: Int) raises -> List[UInt8]:
    """`count` bytes from the operating system's entropy pool.

    `getentropy` rather than `std.random`, because the caller is a multipart
    boundary and a boundary that can be guessed is a boundary an attacker who
    controls one part can write into another. `std.random` is seeded from the
    clock and is fine for a shuffle and not for this.

    Present on macOS since 10.12 and in glibc since 2.25, and in musl, which
    covers every platform this builds for. There is no fallback on purpose: a
    quiet downgrade to a weak source is worse than a failure that says the
    machine cannot produce randomness.
    """
    comptime CHUNK = 256
    """What `getentropy` accepts in one call. Asking for more fails with EIO
    rather than returning short, so the loop is not optional."""

    var out = List[UInt8](length=count, fill=0)
    var at = 0
    while at < count:
        var want = min(CHUNK, count - at)
        clear_errno()
        # Writing into `out` from `at` onwards. The buffer was allocated at the
        # full length above, so `want` bytes from `at` are in bounds on every
        # pass, and the loop advances by exactly what it asked for.
        var rc = external_call["getentropy", c_int](
            Pointer(to=out[at]), c_size_t(want)
        )
        if rc != 0:
            # `UnknownError` because there is no httpx2 exception for this and
            # inventing a name would break the rule that every kind here is one
            # httpx2 also has. The message carries the whole story anyway, and
            # a machine that cannot produce sixteen random bytes has a problem
            # no HTTP client is going to classify usefully.
            raise new_error(
                ErrorKind.UNKNOWN,
                String(
                    "the operating system would not produce ",
                    want,
                    " bytes of randomness: ",
                    strerror(errno()),
                ),
            )
        at += want
    return out^


def write_fd[o: ImmOrigin](fd: Int, buf: Pointer[UInt8, o], count: Int) -> Int:
    """Write to a descriptor. Returns what libc returned.

    A short write is normal and is not an error, exactly as it is for `send`,
    so the caller loops. Negative means errno has the reason.

    This exists because the standard library's `print` is not a way to put a
    body on stdout. It appends a newline, it wants text rather than bytes, and
    a response body is neither guaranteed to be text nor allowed to gain a byte
    on the way through.

    The types here are `Int` rather than the `c_int` and `c_size_t` the C
    declaration uses. That is not a slip. The standard library declares `write`
    for its own file handles, a second declaration of the same symbol with
    different types is rejected before it ever reaches the linker, and these
    are the types it picked. Both are pointer sized on every platform this
    builds for, so it is the same call either way.
    """
    return external_call["write", Int](fd, buf, count)


def isatty(fd: c_int) -> c_int:
    """Whether a descriptor is a terminal. One if it is, zero if it is not.

    The whole of the CLI's decoration policy hangs off this call. Anything that
    is not a terminal is something's input, and something's input does not want
    colour, or a progress bar, or a body that has been made pretty.
    """
    return external_call["isatty", c_int](fd)


def cstr_to_string[o: ImmOrigin](s: CStringSlice[o]) -> String:
    """Copy a C string into a `String` we control.

    Generic over the origin rather than fixed to `CStr`, because the argument
    is as often a buffer we built as one libc owns, and the copy makes the
    distinction stop mattering the moment it returns.

    Skipping UTF-8 validation is sound because every caller is reading a string
    libc produced from ASCII input: an errno description, a numeric address, or
    a name we passed in ourselves. A C string that could hold arbitrary bytes
    from the network must go through `String(StringSpan(from_utf8=...))`
    instead, which reports a decoding failure rather than producing a `String`
    that is not valid UTF-8.
    """
    return String(StringSpan(unsafe_from_utf8=s))
