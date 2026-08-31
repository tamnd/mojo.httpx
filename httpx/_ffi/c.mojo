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
