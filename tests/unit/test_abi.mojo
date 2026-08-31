"""Assertions about the C ABI that the FFI layer is built on.

Every claim here is one the bindings would be quietly wrong without, and none of
them is something the Mojo language promises. They are properties of the
platform and of the compiler's lowering, so they are checked on every platform
on every run rather than written down once in a document that goes stale.

If one of these fails after a toolchain upgrade, stop and read
`01-mojo-baseline.md` section 9 before changing anything else. The failure is
telling you the ground moved, not that a test is flaky.
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
from std.sys import size_of
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from httpx._ffi.c import CStr, Ptr, c_string, cstr_to_string, socklen_t
from httpx._ffi.netdb import ADDRINFO_SIZE, AddrBytes, SOCKADDR_MAX
from httpx._ffi.socket import (
    AF_INET,
    SOCK_STREAM,
    close,
    fcntl_get_flags,
    socket,
)


def test_c_scalar_widths_are_what_the_bindings_assume() raises:
    assert_equal(size_of[c_int](), 4)
    assert_equal(size_of[c_uint](), 4)
    assert_equal(size_of[c_char](), 1)
    # Every platform we support is LP64, which is why a pointer and a size are
    # both eight bytes and why nothing in _ffi ever widens one by hand.
    assert_equal(size_of[c_size_t](), 8)
    assert_equal(size_of[c_ssize_t](), 8)
    assert_equal(size_of[socklen_t](), 4)


def test_a_nullable_c_pointer_is_one_machine_word() raises:
    """`Optional[Ptr[T]]` has to be the same value on the wire as `T *`.

    Mojo's `Pointer` is non-nullable, so every C function that can return null
    is declared as returning an `Optional`. That is only correct if the
    `Optional` is a bare pointer with null as its empty case rather than a
    pointer plus a discriminant, which would be sixteen bytes and would
    misinterpret whatever libc returned.
    """
    assert_equal(size_of[Ptr[UInt8]](), 8)
    assert_equal(size_of[Optional[Ptr[UInt8]]](), 8)
    assert_equal(size_of[Optional[Ptr[c_int]]](), 8)


def test_a_null_return_from_libc_reads_as_the_empty_optional() raises:
    """The same claim again, this time against a real C function.

    `getenv` returns null for a variable that is not set, which makes it the
    cheapest way to prove the representation end to end rather than by
    reasoning about sizes.
    """
    var missing = c_string("HTTPX_MOJO_NOT_A_REAL_VARIABLE")
    var absent = external_call["getenv", Optional[CStr]](CStringSlice(missing))
    assert_false(Bool(absent))

    var present_name = c_string("PATH")
    var present = external_call["getenv", Optional[CStr]](
        CStringSlice(present_name)
    )
    assert_true(Bool(present))
    assert_true(cstr_to_string(present.value()).byte_length() > 0)


def test_the_address_buffer_is_exactly_as_wide_as_declared() raises:
    """`SockAddr` stores its bytes in a SIMD vector rather than an `Array`.

    `Array` is not implicitly copyable and neither is any struct containing
    one, which rules it out for a value that gets passed around freely. The
    substitute is only correct if it is the size it claims and has no padding.
    """
    assert_equal(size_of[AddrBytes](), SOCKADDR_MAX)
    # Twenty eight bytes is `sizeof(struct sockaddr_in6)`, the largest address
    # this library ever holds, so the buffer has to be at least that.
    assert_true(SOCKADDR_MAX >= 28)


def test_the_addrinfo_size_covers_every_offset_we_read() raises:
    # The last field read out of `struct addrinfo` is `ai_next` at offset 40,
    # which is a pointer, so the structure cannot be smaller than 48.
    assert_equal(ADDRINFO_SIZE, 48)


def test_a_mojo_string_is_not_a_c_string() raises:
    """Handing a `String` straight to libc would read past the allocation.

    Mojo strings are not nul terminated. `CStringSlice` refuses rather than
    guessing, which is the behaviour this test is pinning: if a future version
    started accepting an unterminated string the failure would move from a
    compile time exception to a heap overread.
    """
    with assert_raises():
        _ = CStringSlice(String("example.com"))

    # `c_string` is the supported way, and the result is accepted.
    var terminated = c_string("example.com")
    assert_equal(cstr_to_string(CStringSlice(terminated)), "example.com")


def test_an_interior_nul_never_reaches_libc() raises:
    """This one is a security property, not a formality.

    A hostname or a header value carrying an embedded nul is the classic way to
    make a C API see a shorter string than the one that was validated. Mojo
    rejects it at the boundary, so the whole class of bug is closed by the type
    rather than by a check somebody has to remember to write.
    """
    var smuggled = c_string(String("example.com", "\0", "evil.example"))
    with assert_raises():
        _ = CStringSlice(smuggled)


def test_a_variadic_argument_reaches_libc() raises:
    """The canary for the Apple arm64 variadic ABI.

    `fcntl` takes its third argument through `...`, and Apple arm64 passes
    variadic arguments on the stack while Linux passes them in registers. The
    binding satisfies both by passing the value in two positions. Nothing in
    the language guarantees that keeps working, and when it stops, the symptom
    is a socket that stays blocking and a read that hangs forever with no error
    reported anywhere. `F_DUPFD` is used rather than `F_SETFL` because its
    argument comes straight back in the return value.

    See `01-mojo-baseline.md` section 9.9.
    """
    comptime F_DUPFD = c_int(0)
    var fd = socket(AF_INET, SOCK_STREAM, c_int(0))
    assert_true(fd >= 0)

    # `fcntl(fd, F_DUPFD, 50)` duplicates the descriptor onto the lowest free
    # number that is at least 50. If the argument were lost the result would be
    # the lowest free descriptor instead, which is single digit here.
    var duplicate = _fcntl(fd, F_DUPFD, c_int(50))
    assert_true(duplicate >= 50)

    _ = close(duplicate)
    _ = close(fd)


def _fcntl(fd: c_int, cmd: c_int, arg: c_int) -> c_int:
    # Deliberately a copy of the call shape in httpx/_ffi/socket.mojo rather
    # than a call into it. The test is about the shape, so importing the thing
    # under test would only prove it agrees with itself.
    comptime Z = c_int(0)
    return external_call["fcntl", c_int](fd, cmd, arg, Z, Z, Z, Z, Z, arg)


def test_reading_flags_back_is_how_a_broken_setter_is_noticed() raises:
    """`F_SETFL` reports success without checking that it understood itself.

    That is why `set_nonblocking` reads the flags back, and why this test
    asserts the read path works at all: if `F_GETFL` ever started returning a
    constant, the verification in `set_nonblocking` would pass vacuously.
    """
    var fd = socket(AF_INET, SOCK_STREAM, c_int(0))
    var flags = fcntl_get_flags(fd)
    assert_true(flags >= 0)
    # A fresh socket is open for reading and writing, which is `O_RDWR`, 2 on
    # both platforms. A getter stuck at zero would fail here.
    assert_true(Int(flags & 3) == 2)
    _ = close(fd)
