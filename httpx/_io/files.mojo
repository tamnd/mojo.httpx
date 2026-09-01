"""Reading a file, and finding the ones a user keeps in their home directory.

Only `.netrc` needs this today. It sits here rather than beside the auth code
because opening a file is I/O and this is the layer where I/O lives, which
leaves the parsing above as something that can be tested on a string.
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
