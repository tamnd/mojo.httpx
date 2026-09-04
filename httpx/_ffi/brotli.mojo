"""Bindings to libbrotlidec, loaded at run time, for `Content-Encoding: br`.

Brotli is not on every machine the way zlib is, which is the whole reason this
module is shaped the way it is. It is opened with `dlopen`, the failure is
recorded rather than raised, and `is_available` below is what decides whether
`br` appears in `Accept-Encoding` at all. A machine without brotli asks for
less and gets plain bodies, which is the only degradation worth having: asking
for a coding you cannot undo means handing the caller compressed bytes and
calling them the body.

Only the decoder is bound, and only the streaming half of it. Nothing in this
client compresses anything, and the one shot `BrotliDecoderDecompress` needs
the output size up front, which is exactly the number an attacker gets to
choose. The streaming call fills a buffer the caller sized and says whether
there is more, so the bound in `httpx._codec.decode` can be checked as the body
grows.

`libbrotlidec` depends on `libbrotlicommon` and does not stand alone. Nothing
here loads the second one, because it is a `DT_NEEDED` entry on the first and
the system loader resolves it. A machine that has one and not the other is
broken in a way this module should report rather than paper over.

Two things about the C API are worth knowing before reading the calls below.

`BrotliDecoderDecompressStream` takes pointers to the input and output
positions and advances them itself, rather than taking lengths and returning
how far it got. So every argument is an out parameter, including the two that
look like inputs, and how much moved is a subtraction on the Mojo side.

`BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT` is not an error and neither is
`NEEDS_MORE_INPUT`. They are the two ordinary ways a call ends, and only the
caller knows which of them it was expecting, which is why `DecodeStep` below is
a record rather than a raise.
"""

from std.ffi import (
    CStringSlice,
    OwnedDLHandle,
    _Global,
    c_int,
    c_size_t,
    c_uint,
)
from std.sys import CompilationTarget

from httpx._exceptions import ErrorKind, new_error
from httpx._ffi.c import CStr, Ptr, getenv

comptime BROTLI_PATH_ENV = "HTTPX_BROTLI_PATH"
"""Where to load libbrotlidec from, when the search order finds the wrong one.

Takes a full path to the library. Set it and nothing else is tried, so a
mistake here is an error rather than a silent fall through to some other copy.
"""

# What one call to `BrotliDecoderDecompressStream` returns.
comptime BROTLI_RESULT_ERROR = 0
comptime BROTLI_RESULT_SUCCESS = 1
comptime BROTLI_RESULT_NEEDS_MORE_INPUT = 2
comptime BROTLI_RESULT_NEEDS_MORE_OUTPUT = 3


def _library_names() -> List[String]:
    """The file names libbrotlidec goes by, best first.

    The versioned name comes first for the same reason it does for libz: that
    is the one a package manager installs, and the bare name is a development
    symlink that a runtime only machine does not have.
    """
    var names = List[String]()
    if CompilationTarget.is_macos():
        names.append(String("libbrotlidec.1.dylib"))
        names.append(String("libbrotlidec.dylib"))
    else:
        names.append(String("libbrotlidec.so.1"))
        names.append(String("libbrotlidec.so"))
    return names^


def _directories() -> List[String]:
    """Where to look, in the order the answers get less certain.

    The same list libz uses, with Homebrew on macOS carrying more weight than
    it does there: brotli is not part of the base system on either platform, so
    on macOS the Homebrew copy is usually the only one.
    """
    var dirs = List[String]()
    try:
        var prefix = getenv("CONDA_PREFIX")
        if prefix and prefix.value() != "":
            dirs.append(String(prefix.value(), "/lib/"))
    except:
        # An environment we cannot read is an environment with nothing in it.
        pass
    dirs.append(String())
    if CompilationTarget.is_macos():
        dirs.append(String("/opt/homebrew/lib/"))
        dirs.append(String("/usr/local/lib/"))
        dirs.append(String("/usr/lib/"))
    else:
        dirs.append(String("/usr/lib/"))
        dirs.append(String("/lib/x86_64-linux-gnu/"))
        dirs.append(String("/lib/aarch64-linux-gnu/"))
        dirs.append(String("/usr/lib/x86_64-linux-gnu/"))
        dirs.append(String("/usr/lib/aarch64-linux-gnu/"))
    return dirs^


def _candidates() -> List[String]:
    """Every path to try, in order, first one that opens wins."""
    var out = List[String]()
    try:
        var override = getenv(BROTLI_PATH_ENV)
        if override and override.value() != "":
            out.append(override.value())
            return out^
    except:
        pass
    var dirs = _directories()
    var names = _library_names()
    for d in range(len(dirs)):
        for n in range(len(names)):
            out.append(String(dirs[d], names[n]))
    return out^


struct _Loaded(Movable):
    """The handle, or the reason there is none.

    Failure is recorded rather than raised because this is built inside a
    process global, which is initialized once by code that cannot raise. It is
    also the ordinary case here rather than a disaster: a machine without
    brotli is a machine that never asks for it.
    """

    var handle: Optional[OwnedDLHandle]
    var path: String
    var version: String
    var problem: String

    def __init__(out self):
        self.handle = None
        self.path = String()
        self.version = String()
        self.problem = String()
        var tried = String()
        var candidates = _candidates()
        for i in range(len(candidates)):
            ref candidate = candidates[i]
            try:
                var opened = OwnedDLHandle(candidate)
                self.handle = Optional(opened^)
                self.path = candidate.copy()
                self.version = self._read_version()
                return
            except e:
                self.handle = None
                if tried != "":
                    tried += ", "
                tried += "'" + candidate + "'"
        self.problem = String(
            (
                "no usable brotli was found, so the br content coding is not"
                " available and is not asked for. Tried "
            ),
            tried,
            ". Set ",
            BROTLI_PATH_ENV,
            " to the full path of libbrotlidec if it lives somewhere else.",
        )

    def _read_version(mut self) raises -> String:
        """`BrotliDecoderVersion()`, which doubles as a check on the library.

        The number is packed as major in the top eight bits, minor in the next
        twelve and patch in the low twelve. Reading it here means a library
        whose name matched and whose contents did not is found now, so the
        search moves to the next candidate rather than failing later on the
        first body.
        """
        var f = self.handle.value().get_function[c_uint]("BrotliDecoderVersion")
        var packed = Int(f())
        return String(
            packed >> 24, ".", (packed >> 12) & 0xFFF, ".", packed & 0xFFF
        )


def _load() -> _Loaded:
    return _Loaded()


comptime _LOADED = _Global["httpx_brotli", _load]


def _libbrotli() raises -> ref[ImmStaticOrigin] OwnedDLHandle:
    """The libbrotlidec handle, opened on first use and kept for the process.

    One handle for the whole program, because a `BrotliDecoder` holds state the
    library allocated and unloading it underneath would be a use after free.
    Nothing ever closes it.
    """
    ref loaded = _LOADED.get_or_create_ptr()[]
    if loaded.problem != "":
        raise new_error(ErrorKind.UNSUPPORTED_PROTOCOL, loaded.problem)
    return loaded.handle.value()


def library_path() raises -> String:
    """Which libbrotlidec got loaded, for diagnostics."""
    ref loaded = _LOADED.get_or_create_ptr()[]
    if loaded.problem != "":
        raise new_error(ErrorKind.UNSUPPORTED_PROTOCOL, loaded.problem)
    return loaded.path.copy()


def version_text() raises -> String:
    """`1.1.0`, assembled from the number the library reports."""
    ref loaded = _LOADED.get_or_create_ptr()[]
    if loaded.problem != "":
        raise new_error(ErrorKind.UNSUPPORTED_PROTOCOL, loaded.problem)
    return loaded.version.copy()


def is_available() -> Bool:
    """Whether `br` can be decoded at all in this process.

    Read when the client builds its default headers, because a coding it cannot
    undo must not be asked for. This is the switch that makes a machine without
    brotli work rather than fail.
    """
    try:
        _ = _libbrotli()
        return True
    except:
        return False


def unavailable_reason() -> String:
    """Why brotli could not be loaded, or the empty string if it was.

    For the places that want to say something about it without raising, which
    is the error a server gets when it sends `br` to a client that never asked.
    """
    try:
        ref loaded = _LOADED.get_or_create_ptr()[]
        return loaded.problem.copy()
    except:
        # Unreachable: building the global cannot raise, since `_Loaded`
        # records its failure rather than throwing it. Answering with a
        # sentence beats making this the one accessor that raises.
        return String("brotli could not be loaded")


def result_text(code: Int) -> String:
    """The four `BrotliDecoderResult` values in words."""
    if code == BROTLI_RESULT_SUCCESS:
        return String("BROTLI_DECODER_RESULT_SUCCESS")
    if code == BROTLI_RESULT_NEEDS_MORE_INPUT:
        return String("BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT")
    if code == BROTLI_RESULT_NEEDS_MORE_OUTPUT:
        return String("BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT")
    if code == BROTLI_RESULT_ERROR:
        return String("BROTLI_DECODER_RESULT_ERROR")
    return String("brotli result ", code)


struct DecodeStep(ImplicitlyCopyable, Movable):
    """What one call to `BrotliDecoderDecompressStream` did.

    A plain record rather than a raised error, because three of the four
    results are normal and only the caller knows which one it expected.
    """

    var code: Int
    """One of the `BROTLI_RESULT_` constants above."""
    var consumed: Int
    """How many input bytes were taken."""
    var produced: Int
    """How many output bytes were written."""

    def __init__(out self, code: Int, consumed: Int, produced: Int):
        self.code = code
        self.consumed = consumed
        self.produced = produced


struct BrotliDecoder(Movable):
    """One brotli stream being decoded, owning the state the library made.

    Not copyable, because two copies would both call
    `BrotliDecoderDestroyInstance` on one allocation. The state is an opaque
    pointer rather than a struct read at byte offsets, which is what makes this
    module shorter than the zlib one: brotli never asks the caller to know its
    layout.
    """

    var _state: Ptr[NoneType]
    var _open: Bool

    def __init__(out self) raises:
        """Start a decoder, or raise saying brotli is not on this machine.

        The three arguments are the custom allocator hooks, all null, which is
        how the library is told to use its own.
        """
        var no_alloc: Optional[Ptr[NoneType]] = None
        var no_free: Optional[Ptr[NoneType]] = None
        var no_opaque: Optional[Ptr[NoneType]] = None
        var made = _libbrotli().get_function[Optional[Ptr[NoneType]]](
            "BrotliDecoderCreateInstance"
        )(no_alloc, no_free, no_opaque)
        if not made:
            raise new_error(
                ErrorKind.PROTOCOL_ERROR,
                String("brotli would not allocate a decoder"),
            )
        self._state = made.value()
        self._open = True

    def __deinit__(deinit self):
        try:
            if self._open:
                # Frees everything brotli allocated for this stream. Safe in
                # any state, including partway through a truncated body, which
                # is what a dropped response leaves behind.
                var free = _libbrotli().get_function[NoneType](
                    "BrotliDecoderDestroyInstance"
                )
                _ = free(self._state)
        except:
            # Unreachable: the handle that made this decoder is still open,
            # because it is never closed. A destructor cannot raise anyway.
            pass

    def step[
        o: ImmOrigin
    ](
        mut self, source: Span[UInt8, o], from_index: Int, mut sink: List[UInt8]
    ) raises -> DecodeStep:
        """Push what is left of `source` through, writing into all of `sink`.

        `from_index` rather than a slice of the caller's own, because the
        caller loops over one input buffer filling a fixed output buffer
        several times, and re-slicing on every pass would be a new span for
        every chunk of output.

        `sink` is written from the start each time and `produced` says how much
        of it is real. The caller copies that out before calling again.
        """
        if len(sink) == 0:
            raise new_error(
                ErrorKind.PROTOCOL_ERROR,
                String("a decoder was given nowhere to write"),
            )
        if not self._open:
            raise new_error(
                ErrorKind.PROTOCOL_ERROR,
                String("this decoder has already been finished"),
            )
        var available = len(source) - from_index
        if available < 0:
            available = 0

        # Sound because `sink` is non empty by the check above and a list's
        # elements are contiguous, so `len(sink)` bytes from its start stay
        # inside it. It is borrowed for the call and nothing resizes it here.
        var out_ptr = Ptr[UInt8](unsafe_from_address=Int(sink.unsafe_ptr()))
        var next_out = out_ptr
        var avail_out = c_size_t(len(sink))
        var next_in = out_ptr
        if available > 0:
            # Sound for the same contiguity reason, offset by `from_index`,
            # which the check above keeps inside the span.
            next_in = Ptr[UInt8](
                unsafe_from_address=Int(source.unsafe_ptr()) + from_index
            )
        # With no input bytes brotli never reads through this pointer. It still
        # has to be an address rather than null, because `Ptr` cannot hold one,
        # and the output buffer is the address in scope that is certainly good.
        var avail_in = c_size_t(available)
        var total_out = c_size_t(0)

        var f = _libbrotli().get_function[c_int](
            "BrotliDecoderDecompressStream"
        )
        var code = Int(
            f(
                self._state,
                Pointer(to=avail_in),
                Pointer(to=next_in),
                Pointer(to=avail_out),
                Pointer(to=next_out),
                Pointer(to=total_out),
            )
        )
        # brotli advanced both pointers and decremented both counts by however
        # much it moved, which is the only way to find out how far it got.
        return DecodeStep(
            code, available - Int(avail_in), len(sink) - Int(avail_out)
        )

    def is_finished(self) raises -> Bool:
        """Whether the stream reached its end, as brotli itself sees it."""
        var f = _libbrotli().get_function[c_int]("BrotliDecoderIsFinished")
        return Int(f(self._state)) != 0

    def message(self) -> String:
        """What brotli says went wrong, or the empty string.

        Worth carrying into the error, because the codes distinguish a bad
        window size from a truncated ring buffer and the result value alone
        says neither.

        brotli builds these names by pasting two macro arguments together, so
        every one of them comes back with a leading underscore, as
        `_ERROR_FORMAT_CL_SPACE`. That underscore is an artefact of how the
        table is written rather than part of the name, and it is dropped here
        because a message that starts with punctuation reads like a bug in this
        library.
        """
        try:
            var code = _libbrotli().get_function[c_int](
                "BrotliDecoderGetErrorCode"
            )(self._state)
            var text = _libbrotli().get_function[CStr](
                "BrotliDecoderErrorString"
            )(code)
            var name = String(StringSpan(unsafe_from_utf8=text))
            if name.startswith("_"):
                var tail = String(name[byte=1:])
                name = tail^
            return name^
        except:
            # Unreachable for the same reason as the destructor: the handle is
            # open. A caller building an error message should not get a second
            # error out of it.
            return String()
