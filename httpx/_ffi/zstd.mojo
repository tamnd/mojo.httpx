"""Bindings to libzstd, loaded at run time, for `Content-Encoding: zstd`.

The same shape as the brotli module next to it, and for the same reason. zstd
is not on every machine, it is opened with `dlopen`, the failure is recorded
rather than raised, and `is_available` below decides whether `zstd` appears in
`Accept-Encoding` at all. A machine without it asks for less and gets plain
bodies.

Only the streaming decoder is bound. `ZSTD_decompress` wants the output size up
front, and for a frame that carries no content size in its header there is no
way to know it, while for one that does the number is written by whoever wrote
the body. Both of those are the wrong question. `ZSTD_decompressStream` fills a
buffer the caller sized, which is what lets the bound in `httpx._codec.decode`
be checked as the body grows.

Two things about the C API shape the code below.

Errors are in the return value rather than in a separate call. Every streaming
function returns a `size_t` that is either a real answer or an error code near
the top of the range, and `ZSTD_isError` is the only way to tell which. So
every call site checks before believing the number.

`ZSTD_inBuffer` and `ZSTD_outBuffer` are three `size_t` fields each, a pointer
and two counts, and the library advances `pos` rather than the pointer. They
are built here as `List[UInt64]` of length three rather than as a declared Mojo
struct, because Mojo makes no promise that its field layout matches the C ABI.
A list of three eight byte integers is that structure on every platform we
support, all of which are LP64, and it is aligned by construction, which a
buffer of bytes would not be.
"""

from std.ffi import CStringSlice, OwnedDLHandle, _Global, c_size_t, c_uint
from std.sys import CompilationTarget

from httpx._exceptions import ErrorKind, new_error
from httpx._ffi.c import CStr, Ptr, getenv

comptime ZSTD_PATH_ENV = "HTTPX_ZSTD_PATH"
"""Where to load libzstd from, when the search order finds the wrong one.

Takes a full path to the library. Set it and nothing else is tried, so a
mistake here is an error rather than a silent fall through to some other copy.
"""

comptime _BUFFER_FIELDS = 3
"""`src`, `size` and `pos`, which is both of the buffer structures."""

comptime _SRC = 0
comptime _SIZE = 1
comptime _POS = 2


def _library_names() -> List[String]:
    """The file names libzstd goes by, best first.

    The versioned name comes first for the same reason it does for libz: that
    is the one a package manager installs, and the bare name is a development
    symlink that a runtime only machine does not have.
    """
    var names = List[String]()
    if CompilationTarget.is_macos():
        names.append(String("libzstd.1.dylib"))
        names.append(String("libzstd.dylib"))
    else:
        names.append(String("libzstd.so.1"))
        names.append(String("libzstd.so"))
    return names^


def _directories() -> List[String]:
    """Where to look, in the order the answers get less certain.

    The Mojo environment first, because zstd ships inside it: conda uses zstd
    for its own package format, so a pixi environment has a copy whether or not
    the machine does.
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
        var override = getenv(ZSTD_PATH_ENV)
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
    also the ordinary case here rather than a disaster: a machine without zstd
    is a machine that never asks for it.
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
                "no usable zstd was found, so the zstd content coding is not"
                " available and is not asked for. Tried "
            ),
            tried,
            ". Set ",
            ZSTD_PATH_ENV,
            " to the full path of libzstd if it lives somewhere else.",
        )

    def _read_version(mut self) raises -> String:
        """`ZSTD_versionString()`, which doubles as a check on the library.

        A library whose name matched and whose contents did not is found here,
        so the search moves to the next candidate rather than failing later on
        the first body.
        """
        var f = self.handle.value().get_function[CStr]("ZSTD_versionString")
        return String(StringSpan(unsafe_from_utf8=f()))


def _load() -> _Loaded:
    return _Loaded()


comptime _LOADED = _Global["httpx_zstd", _load]


def _libzstd() raises -> ref[ImmStaticOrigin] OwnedDLHandle:
    """The libzstd handle, opened on first use and kept for the process.

    One handle for the whole program, because a `ZstdDecoder` holds state the
    library allocated and unloading it underneath would be a use after free.
    Nothing ever closes it.
    """
    ref loaded = _LOADED.get_or_create_ptr()[]
    if loaded.problem != "":
        raise new_error(ErrorKind.UNSUPPORTED_PROTOCOL, loaded.problem)
    return loaded.handle.value()


def library_path() raises -> String:
    """Which libzstd got loaded, for diagnostics."""
    ref loaded = _LOADED.get_or_create_ptr()[]
    if loaded.problem != "":
        raise new_error(ErrorKind.UNSUPPORTED_PROTOCOL, loaded.problem)
    return loaded.path.copy()


def version_text() raises -> String:
    """`1.5.5`, straight from the library."""
    ref loaded = _LOADED.get_or_create_ptr()[]
    if loaded.problem != "":
        raise new_error(ErrorKind.UNSUPPORTED_PROTOCOL, loaded.problem)
    return loaded.version.copy()


def is_available() -> Bool:
    """Whether `zstd` can be decoded at all in this process.

    Read when the client builds its default headers, because a coding it cannot
    undo must not be asked for. This is the switch that makes a machine without
    zstd work rather than fail.
    """
    try:
        _ = _libzstd()
        return True
    except:
        return False


def unavailable_reason() -> String:
    """Why zstd could not be loaded, or the empty string if it was.

    For the places that want to say something about it without raising, which
    is the error a server gets when it sends `zstd` to a client that never
    asked.
    """
    try:
        ref loaded = _LOADED.get_or_create_ptr()[]
        return loaded.problem.copy()
    except:
        # Unreachable: building the global cannot raise, since `_Loaded`
        # records its failure rather than throwing it. Answering with a
        # sentence beats making this the one accessor that raises.
        return String("zstd could not be loaded")


def is_error(code: Int) raises -> Bool:
    """Whether a `size_t` that came back from zstd is an error code.

    zstd reserves the top of the range for these, so a plain comparison would
    be this binding deciding where the boundary is. The library is asked.
    """
    var f = _libzstd().get_function[c_uint]("ZSTD_isError")
    return Int(f(c_size_t(code))) != 0


def error_text(code: Int) -> String:
    """What zstd calls that error code, for putting in a message."""
    try:
        var f = _libzstd().get_function[CStr]("ZSTD_getErrorName")
        return String(StringSpan(unsafe_from_utf8=f(c_size_t(code))))
    except:
        # Unreachable: nothing asks for the name of an error it did not get
        # from a library that is open. A caller building a message should not
        # get a second error out of it.
        return String("zstd error ", code)


struct DecodeStep(ImplicitlyCopyable, Movable):
    """What one call to `ZSTD_decompressStream` did.

    A plain record rather than a raised error, because a call that ran out of
    input and a call that finished a frame are both normal and only the caller
    knows which one it expected.
    """

    var ended: Bool
    """Whether a whole frame came to an end on this call."""
    var consumed: Int
    """How many input bytes were taken."""
    var produced: Int
    """How many output bytes were written."""

    def __init__(out self, ended: Bool, consumed: Int, produced: Int):
        self.ended = ended
        self.consumed = consumed
        self.produced = produced


struct ZstdDecoder(Movable):
    """One zstd stream being decoded, owning the state the library made.

    Not copyable, because two copies would both call `ZSTD_freeDStream` on one
    allocation. The state is an opaque pointer rather than a struct read at
    byte offsets, so this module never has to know zstd's layout, only the
    layout of the two buffer descriptors it is handed.
    """

    var _state: Ptr[NoneType]
    var _open: Bool

    def __init__(out self) raises:
        """Start a decoder, or raise saying zstd is not on this machine."""
        var made = _libzstd().get_function[Optional[Ptr[NoneType]]](
            "ZSTD_createDStream"
        )()
        if not made:
            raise new_error(
                ErrorKind.PROTOCOL_ERROR,
                String("zstd would not allocate a decoder"),
            )
        self._state = made.value()
        self._open = True
        self.reset()

    def __deinit__(deinit self):
        try:
            if self._open:
                # Frees everything zstd allocated for this stream. Safe in any
                # state, including partway through a truncated body, which is
                # what a dropped response leaves behind.
                var free = _libzstd().get_function[c_size_t]("ZSTD_freeDStream")
                _ = free(self._state)
        except:
            # Unreachable: the handle that made this decoder is still open,
            # because it is never closed. A destructor cannot raise anyway.
            pass

    def reset(mut self) raises:
        """Put the decoder back at the start of a frame.

        Called once when it is built and again between frames. A zstd body may
        be several frames one after another, which is legal and is what the
        command line tool produces when it is given several inputs.
        """
        var f = _libzstd().get_function[c_size_t]("ZSTD_initDStream")
        var code = Int(f(self._state))
        if is_error(code):
            raise new_error(
                ErrorKind.PROTOCOL_ERROR,
                String("zstd would not start a decoder: ", error_text(code)),
            )

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

        Raises when the frame is corrupt. That is the one case zstd reports in
        the return value rather than in the buffer positions, and there is
        nothing a caller can do with it other than fail.
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
        var out_address = Int(sink.unsafe_ptr())
        var in_address = out_address
        if available > 0:
            # Sound for the same contiguity reason, offset by `from_index`,
            # which the check above keeps inside the span.
            in_address = Int(source.unsafe_ptr()) + from_index
        # With a size of zero zstd never reads through the input pointer, and
        # it is still given a real address because a descriptor holding a null
        # is not something the library documents an answer for.

        var output = List[UInt64](length=_BUFFER_FIELDS, fill=0)
        output[_SRC] = UInt64(out_address)
        output[_SIZE] = UInt64(len(sink))
        var input = List[UInt64](length=_BUFFER_FIELDS, fill=0)
        input[_SRC] = UInt64(in_address)
        input[_SIZE] = UInt64(available)

        # Sound because both lists are three eight byte integers, owned here,
        # and outlive the call, which is exactly `ZSTD_outBuffer` and
        # `ZSTD_inBuffer` on an LP64 platform. See the module docstring.
        var f = _libzstd().get_function[c_size_t]("ZSTD_decompressStream")
        var code = Int(
            f(
                self._state,
                Ptr[UInt64](unsafe_from_address=Int(output.unsafe_ptr())),
                Ptr[UInt64](unsafe_from_address=Int(input.unsafe_ptr())),
            )
        )
        if is_error(code):
            raise new_error(
                ErrorKind.PROTOCOL_ERROR,
                String("this zstd body is not valid: ", error_text(code)),
            )
        # zstd advanced `pos` on both descriptors by however much it moved,
        # which is the only way to find out how far it got. A return of zero
        # means a frame ended on this call; anything else is a hint about how
        # much input the next call would like, and is not an answer to keep.
        return DecodeStep(code == 0, Int(input[_POS]), Int(output[_POS]))
