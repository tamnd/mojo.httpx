"""Reading and writing whole files, and finding the ones in a home directory.

Two callers: the `.netrc` reader, and the CLI, which uploads files and writes
downloads. It sits here rather than beside either of them because opening a
file is I/O and this is the layer where I/O lives, which leaves the parsing
above as something that can be tested on a string.
"""

from httpx._ffi.c import getenv


def read_text(path: StringSpan) raises -> String:
    """The whole file as text.

    Whole rather than streamed because the one caller is a `.netrc`, which is a
    handful of lines. A file that did not fit in memory would not be one anybody
    put their credentials in.
    """
    with open(String(path), "r") as handle:
        return handle.read()


def read_bytes(path: StringSpan) raises -> List[UInt8]:
    """The whole file as bytes.

    For an upload, where the file is a part of a multipart body that is built
    in memory anyway, so streaming it would buy nothing.
    """
    with open(String(path), "r") as handle:
        return handle.read_bytes()


struct FileWriter(Movable):
    """A file being written a chunk at a time.

    A download can be larger than memory, so this exists rather than a
    `write_bytes(path, data)` that would need all of it at once. Opening is
    separate from writing on purpose: the CLI opens before it sends, so that a
    path that cannot be written is reported before a request goes out rather
    than after a gigabyte has arrived.
    """

    var _handle: FileHandle

    def __init__(out self, path: StringSpan) raises:
        """Open `path` for writing, truncating whatever was there."""
        self._handle = open(String(path), "w")

    def write[o: ImmOrigin](mut self, data: Span[UInt8, o]) raises:
        self._handle.write_bytes(data)

    def close(mut self) raises:
        """Close the file, reporting anything the last write ran into.

        Raising rather than swallowing, because a close is where a buffered
        write finds out that the disk is full, and a download that quietly
        ended up short is worse than one that says so.
        """
        self._handle.close()


def home_file(name: StringSpan) raises -> String:
    """The path to `name` in the user's home directory.

    Raises when there is no home directory to look in, which happens in some
    containers and in a few daemon contexts. The caller decides whether that is
    a problem, since a missing home is the same as a missing file for anything
    that was only going to fall back anyway.
    """
    var found = getenv("HOME")
    if not found or found.value() == "":
        # Windows names it differently, and this is cheap enough to check even
        # where the first one usually works.
        found = getenv("USERPROFILE")
    if not found or found.value() == "":
        raise Error("RuntimeError: no HOME to look for a file in")
    var home = found.value()
    if home.endswith("/"):
        return String(home, name)
    return String(home, "/", name)
