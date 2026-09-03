"""Bindings to zlib, loaded at run time, for `gzip` and `deflate` bodies.

Mojo has no compression in the standard library, and zlib is on every machine
this library runs on, including inside the Mojo distribution itself at
`<env>/lib/libz.1.dylib` or `libz.so.1`. So the common case needs nothing
installed and this module is binding work.

Opened with `dlopen` rather than linked, for the same two reasons the OpenSSL
module gives. A program that never reads a compressed response should not fail
to start on a machine without zlib, and the version that gets loaded should be
a property of the machine rather than of the build. Every path tried appears in
the failure message.

Three things about this file are load bearing.

`z_stream` is read at explicit byte offsets rather than through a declared Mojo
struct. Mojo makes no promise that its field layout matches the C ABI, and this
structure has a pointer, two four byte integers and two eight byte ones
interleaved, which is exactly the shape where a guess goes wrong quietly. The C
declaration is written out below with the offset beside each field, and they
were checked against `offsetof` on macos-arm64 and linux-x86_64, where all of
them agree. Every platform we support is LP64, which is what makes `uLong`
eight bytes; the same struct on 32 bit Windows is smaller, and there is no
native Windows build to worry about.

`inflateInit2` is a macro in `zlib.h`, not a function. What exists in the
library is `inflateInit2_`, which takes the version string and `sizeof(z_stream)`
so that a header and a library that disagree are caught at initialization rather
than by corrupting memory. That check is why the size above has to be right: get
it wrong and every call returns `Z_VERSION_ERROR`, which is a clear failure
rather than a crash, but it is also the only signal.

The allocator fields are left as zero, which tells zlib to use its own. So a
freshly zeroed buffer is a valid `z_stream` before initialization, and that is
the whole of what `Inflater.__init__` has to arrange.

Only inflation is bound. Nothing in this client compresses anything: request
bodies go out as the caller wrote them, since a server that has not advertised
what it accepts cannot be sent a coding and there is no `Accept-Encoding` for
requests. When there is a reason to deflate something, the deflate half is four
more symbols in the same shape.
"""

from std.ffi import CStringSlice, OwnedDLHandle, _Global, c_int, c_uint
from std.sys import CompilationTarget

from httpx._exceptions import ErrorKind, new_error
from httpx._ffi.c import CStr, Ptr, getenv

comptime ZLIB_PATH_ENV = "HTTPX_ZLIB_PATH"
"""Where to load libz from, when the search order below finds the wrong one.

Takes a full path to the library. Set it and nothing else is tried, so a
mistake here is an error rather than a silent fall through to some other copy.
"""

# `inflate` and friends return one of these. The negative ones are failures and
# the two non negative ones are progress.
comptime Z_OK = 0
comptime Z_STREAM_END = 1
comptime Z_NEED_DICT = 2
comptime Z_ERRNO = -1
comptime Z_STREAM_ERROR = -2
comptime Z_DATA_ERROR = -3
comptime Z_MEM_ERROR = -4
comptime Z_BUF_ERROR = -5
comptime Z_VERSION_ERROR = -6

# The flush modes. A decoder only ever needs the first one: it is told to make
# whatever progress it can with the input it has, and end of stream is something
# the data says rather than something the caller asks for.
comptime Z_NO_FLUSH = 0
comptime Z_SYNC_FLUSH = 2
comptime Z_FINISH = 4

# `windowBits`, which is where the format is chosen. Fifteen is the largest
# window zlib supports and the only size a decoder should ask for, since it has
# to be at least as large as the one the encoder used and there is no way to
# know that in advance. What varies is the sign and the offset on top.
comptime WINDOW_ZLIB = 15
"""A zlib wrapper, RFC 1950. Two header bytes and an Adler-32 at the end."""
comptime WINDOW_RAW = -15
"""No wrapper at all, RFC 1951. Deflate data on its own, with no checksum."""
comptime WINDOW_GZIP = 31
"""A gzip wrapper, RFC 1952. Ten or more header bytes and a CRC-32 at the end."""
comptime WINDOW_AUTO = 47
"""Either wrapper, decided by looking at the first bytes. Never raw."""

# typedef struct z_stream_s {
#     z_const Bytef *next_in;   //   0
#     uInt     avail_in;        //   8, four bytes then four of padding
#     uLong    total_in;        //  16
#     Bytef   *next_out;        //  24
#     uInt     avail_out;       //  32, four bytes then four of padding
#     uLong    total_out;       //  40
#     z_const char *msg;        //  48
#     struct internal_state *state;  // 56
#     alloc_func zalloc;        //  64
#     free_func  zfree;         //  72
#     voidpf     opaque;        //  80
#     int     data_type;        //  88, four bytes then four of padding
#     uLong   adler;            //  96
#     uLong   reserved;         // 104
# } z_stream;
comptime _OFF_NEXT_IN = 0
comptime _OFF_AVAIL_IN = 8
comptime _OFF_TOTAL_IN = 16
comptime _OFF_NEXT_OUT = 24
comptime _OFF_AVAIL_OUT = 32
comptime _OFF_TOTAL_OUT = 40
comptime _OFF_MSG = 48

comptime Z_STREAM_SIZE = 112
"""`sizeof(z_stream)`, LP64. See the note in the module docstring."""

comptime _MAX_MSG = 128
"""How far to read zlib's `msg` before giving up on finding a terminator.

The longest string in zlib's own sources is under forty bytes. The bound is
here because the pointer comes from a library rather than from us, and a scan
for a nul with no limit is a scan that can run off the end of the world.
"""


def _library_names() -> List[String]:
    """The file names libz goes by on this platform, best first.

    The versioned name comes first because that is the one that is always
    installed. The bare name is a development symlink, and the copy inside the
    Mojo environment does not have it.
    """
    var names = List[String]()
    if CompilationTarget.is_macos():
        names.append(String("libz.1.dylib"))
        names.append(String("libz.dylib"))
    else:
        names.append(String("libz.so.1"))
        names.append(String("libz.so"))
    return names^


def _directories() -> List[String]:
    """Where to look for libz, in the order the answers get less certain.

    The Mojo environment first, because that copy is the one this project is
    tested against. Then the loader's own search path, spelled as a bare file
    name, which is what finds the system copy on either platform. Then the
    places a system copy lives, for a program running outside a pixi shell.
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
        dirs.append(String("/usr/lib/"))
        dirs.append(String("/opt/homebrew/lib/"))
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
        var override = getenv(ZLIB_PATH_ENV)
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
    process global, which is initialized once by code that cannot raise. Every
    accessor checks `problem` first, so the diagnostic reaches the caller who
    asked to decode something rather than the caller who happened to run first.
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
                "no usable zlib was found, so the gzip and deflate content"
                " codings are not available. Tried "
            ),
            tried,
            ". Set ",
            ZLIB_PATH_ENV,
            " to the full path of libz if it lives somewhere else.",
        )

    def _read_version(mut self) raises -> String:
        """`zlibVersion()`, which doubles as a check that this is really zlib.

        A library that opened but does not export this is one whose name
        matched and whose contents did not, and finding that out here means the
        search moves on to the next candidate instead of failing later at the
        first `inflateInit2_`.
        """
        var f = self.handle.value().get_function[CStr]("zlibVersion")
        return String(StringSpan(unsafe_from_utf8=f()))


def _load() -> _Loaded:
    return _Loaded()


comptime _LOADED = _Global["httpx_zlib", _load]


def _libz() raises -> ref[ImmStaticOrigin] OwnedDLHandle:
    """The libz handle, opened on first use and kept for the process.

    One handle for the whole program, because an `Inflater` holds state that
    zlib allocated and unloading the library underneath it would be a use after
    free. Nothing ever closes it.
    """
    ref loaded = _LOADED.get_or_create_ptr()[]
    if loaded.problem != "":
        raise new_error(ErrorKind.UNSUPPORTED_PROTOCOL, loaded.problem)
    return loaded.handle.value()


def library_path() raises -> String:
    """Which libz got loaded, for diagnostics and for the CLI to print."""
    ref loaded = _LOADED.get_or_create_ptr()[]
    if loaded.problem != "":
        raise new_error(ErrorKind.UNSUPPORTED_PROTOCOL, loaded.problem)
    return loaded.path.copy()


def version_text() raises -> String:
    """`1.3.1`, straight from the library."""
    ref loaded = _LOADED.get_or_create_ptr()[]
    if loaded.problem != "":
        raise new_error(ErrorKind.UNSUPPORTED_PROTOCOL, loaded.problem)
    return loaded.version.copy()


def is_available() -> Bool:
    """Whether gzip and deflate can be decoded at all in this process.

    Read once when the client builds its default headers, because a coding it
    cannot undo must not be asked for. Everything else should just decode and
    let the failure carry the explanation.
    """
    try:
        _ = _libz()
        return True
    except:
        return False


def unavailable_reason() -> String:
    """Why zlib could not be loaded, or the empty string if it was.

    For the places that want to say something about it without raising, which
    is the CLI and the diagnostics in the tests.
    """
    try:
        ref loaded = _LOADED.get_or_create_ptr()[]
        return loaded.problem.copy()
    except:
        # Unreachable: building the global cannot raise, since `_Loaded`
        # records its failure rather than throwing it. Answering with a
        # sentence beats making this the one accessor that raises.
        return String("zlib could not be loaded")


def code_text(code: Int) -> String:
    """The zlib return codes in words.

    Written out rather than taken from the library because `zError` returns the
    same generic sentence for every one of them, and the number is what a
    reader needs to look anything up.
    """
    if code == Z_OK:
        return String("Z_OK")
    if code == Z_STREAM_END:
        return String("Z_STREAM_END")
    if code == Z_NEED_DICT:
        return String("Z_NEED_DICT, a preset dictionary is required")
    if code == Z_ERRNO:
        return String("Z_ERRNO")
    if code == Z_STREAM_ERROR:
        return String("Z_STREAM_ERROR, the stream state is inconsistent")
    if code == Z_DATA_ERROR:
        return String("Z_DATA_ERROR, the compressed data is corrupt")
    if code == Z_MEM_ERROR:
        return String("Z_MEM_ERROR, zlib could not allocate")
    if code == Z_BUF_ERROR:
        return String("Z_BUF_ERROR, no progress was possible")
    if code == Z_VERSION_ERROR:
        return String("Z_VERSION_ERROR, the library and this binding disagree")
    return String("zlib error ", code)


struct InflateStep(ImplicitlyCopyable, Movable):
    """What one call to `inflate` did.

    A plain record of three numbers rather than a raised error, because
    `Z_BUF_ERROR` and `Z_STREAM_END` are both normal and only the caller knows
    which of them was expected. The codec layer above turns the rest into
    errors with the coding's name attached.
    """

    var code: Int
    """The zlib return code, one of the `Z_` constants above."""
    var consumed: Int
    """How many input bytes were taken."""
    var produced: Int
    """How many output bytes were written."""

    def __init__(out self, code: Int, consumed: Int, produced: Int):
        self.code = code
        self.consumed = consumed
        self.produced = produced


struct Inflater(Movable):
    """One decompression in progress, owning the state zlib allocated for it.

    The `z_stream` lives in a `List[UInt8]` this object owns, so the memory
    stays put for as long as the object does and zlib's internal state, which
    holds a pointer back to it, stays valid. That is also why the type is
    `Movable` and not copyable: two copies would both call `inflateEnd` on one
    allocation.
    """

    var _stream: List[UInt8]
    var _open: Bool

    def __init__(out self, window_bits: Int) raises:
        """Start a decompression in the format `window_bits` selects.

        Raises if zlib is not on the machine, or if it refuses the parameters,
        which at this point can only mean the struct size below is wrong for
        the library that got loaded.
        """
        self._stream = List[UInt8](length=Z_STREAM_SIZE, fill=0)
        self._open = False
        var version = _libz().get_function[CStr]("zlibVersion")()
        var init = _libz().get_function[c_int]("inflateInit2_")
        # Sound because the buffer is `Z_STREAM_SIZE` bytes long and owned by
        # this object, which outlives every call zlib makes through the pointer,
        # and because it was zero filled, which is the documented way to say
        # that zlib should use its own allocator.
        var code = Int(
            init(
                Ptr[UInt8](unsafe_from_address=Int(self._stream.unsafe_ptr())),
                c_int(window_bits),
                version,
                c_int(Z_STREAM_SIZE),
            )
        )
        if code != Z_OK:
            raise new_error(
                ErrorKind.PROTOCOL_ERROR,
                String("zlib would not start a decoder: ", code_text(code)),
            )
        self._open = True

    def __deinit__(deinit self):
        try:
            if self._open:
                # Frees everything zlib allocated for this stream. Safe to
                # call whatever state the decoder is in, including partway
                # through a truncated body, which is the case that matters
                # since a dropped response is exactly that.
                var end = _libz().get_function[c_int]("inflateEnd")
                _ = end(
                    Ptr[UInt8](
                        unsafe_from_address=Int(self._stream.unsafe_ptr())
                    )
                )
        except:
            # Unreachable: the handle that started this decoder is still open,
            # because it is never closed. A destructor cannot raise anyway.
            pass

    def step[
        o: ImmOrigin
    ](
        mut self, source: Span[UInt8, o], from_index: Int, mut sink: List[UInt8]
    ) raises -> InflateStep:
        """Push what is left of `source` through, writing into all of `sink`.

        `from_index` rather than a slice of the caller's own, because the
        caller loops over one input buffer filling a fixed output buffer
        several times, and re-slicing on every pass would be a new span for
        every chunk of output.

        `sink` is written from the start each time and `produced` says how much
        of it is real. The caller copies that out before calling again.

        Returns the raw result. `Z_BUF_ERROR` is not a failure here: it is what
        zlib says when it could not move, which happens whenever the input ran
        out on a boundary, and the caller is the one that knows whether more
        input is coming.
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

        # All four writes are sound for the same reason: the buffer is
        # `Z_STREAM_SIZE` bytes and owned here, and the offsets are the ones
        # named at the top of this file with the C declaration beside them.
        var s = Ptr[UInt8](unsafe_from_address=Int(self._stream.unsafe_ptr()))
        # Sound because `sink` is non empty by the check above and a list's
        # elements are contiguous, so `len(sink)` bytes from its start stay
        # inside it. It is borrowed for the duration of the call and nothing
        # resizes it here.
        var out_ptr = Ptr[UInt8](unsafe_from_address=Int(sink.unsafe_ptr()))
        s.unsafe_offset(_OFF_NEXT_OUT).unsafe_bitcast[Ptr[UInt8]]()[] = out_ptr
        s.unsafe_offset(_OFF_AVAIL_OUT).unsafe_bitcast[c_uint]()[] = c_uint(
            len(sink)
        )
        if available > 0:
            # Sound for the same contiguity reason, offset by `from_index`,
            # which the check above keeps inside the span.
            s.unsafe_offset(_OFF_NEXT_IN).unsafe_bitcast[Ptr[UInt8]]()[] = Ptr[
                UInt8
            ](unsafe_from_address=Int(source.unsafe_ptr()) + from_index)
        else:
            # zlib is told there are no input bytes, so it never reads through
            # this pointer. It still has to be an address rather than null,
            # because `Ptr` cannot hold null, and the output buffer is the one
            # address in scope that is certainly valid.
            s.unsafe_offset(_OFF_NEXT_IN).unsafe_bitcast[
                Ptr[UInt8]
            ]()[] = out_ptr
        s.unsafe_offset(_OFF_AVAIL_IN).unsafe_bitcast[c_uint]()[] = c_uint(
            available
        )

        var inflate = _libz().get_function[c_int]("inflate")
        var code = Int(inflate(s, c_int(Z_NO_FLUSH)))

        # And the two reads, at the same offsets in the same buffer. zlib
        # advanced both pointers and decremented both counts by however much it
        # moved, which is the only way to find out how far it got.
        var in_left = Int(
            s.unsafe_offset(_OFF_AVAIL_IN).unsafe_bitcast[c_uint]()[]
        )
        var out_left = Int(
            s.unsafe_offset(_OFF_AVAIL_OUT).unsafe_bitcast[c_uint]()[]
        )
        return InflateStep(code, available - in_left, len(sink) - out_left)

    def message(self) -> String:
        """The zlib message for what went wrong, or the empty string.

        Worth carrying into the error because "incorrect header check" and
        "invalid distance too far back" say different things about a body, and
        `Z_DATA_ERROR` alone says neither.
        """
        # Sound because the buffer is owned here and `msg` is a `char *` that
        # zlib either left as null or pointed at a string constant in its own
        # image. The scan is bounded, so even a pointer at something that is
        # not a string cannot run away.
        var s = Ptr[UInt8](unsafe_from_address=Int(self._stream.unsafe_ptr()))
        var msg = s.unsafe_offset(_OFF_MSG).unsafe_bitcast[
            Optional[Ptr[UInt8]]
        ]()[]
        if not msg:
            return String()
        var text = msg.value()
        var out = List[UInt8]()
        for i in range(_MAX_MSG):
            var byte = text.unsafe_offset(i)[]
            if byte == 0:
                break
            out.append(byte)
        return String(StringSpan(unsafe_from_utf8=Span(out)))

    def total_out(self) -> Int:
        """How many bytes this decoder has produced since it started.

        zlib's own running total rather than one kept alongside, because it is
        already there and a second counter is a second thing to get wrong.
        """
        # Sound for the same reason as every other access in this file.
        var s = Ptr[UInt8](unsafe_from_address=Int(self._stream.unsafe_ptr()))
        return Int(s.unsafe_offset(_OFF_TOTAL_OUT).unsafe_bitcast[UInt64]()[])

    def total_in(self) -> Int:
        """How many bytes this decoder has been given since it started."""
        # Sound for the same reason as every other access in this file.
        var s = Ptr[UInt8](unsafe_from_address=Int(self._stream.unsafe_ptr()))
        return Int(s.unsafe_offset(_OFF_TOTAL_IN).unsafe_bitcast[UInt64]()[])
