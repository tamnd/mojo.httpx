"""Colour, and the several ways of deciding there should not be any.

Colour is decoration. It goes on the descriptor it decorates, and nothing about
it is allowed to change what a byte of the response turns into, because the
output of this program is somebody else's input. So the decision is made once
per descriptor, before anything is written, and a `Style` that is off writes no
escape sequences at all rather than writing empty ones.

Three things turn it off. A descriptor that is not a terminal, which covers
`httpx URL > file` and `httpx URL | jq` without either of them needing a flag.
`NO_COLOR` set to something, which is the convention at no-color.org and is
honoured by enough tools now that a user who sets it expects it everywhere. And
`TERM=dumb`, which is a terminal saying it cannot do this; Emacs shell buffers
and a handful of CI logs set it.

The sequences here are the eight colour SGR codes from ECMA-48 and nothing
else. No 256 colour, no true colour and no terminfo lookup, because a client
that has to be told what a terminal can do in order to print a header name in
cyan has taken on a dependency to solve a problem nobody has.
"""

from httpx._ffi.c import getenv
from httpx._io.stdio import is_terminal

comptime BOLD = "1"
comptime DIM = "2"
comptime RED = "31"
comptime GREEN = "32"
comptime YELLOW = "33"
comptime BLUE = "34"
comptime MAGENTA = "35"
comptime CYAN = "36"

comptime RESET = "\x1b[0m"
"""Back to whatever the terminal was doing before.

Exported because the JSON printer writes its escapes around raw bytes it must
not copy into a `String` first, so it cannot go through `paint`.
"""


struct Style(Copyable, ImplicitlyCopyable, Movable):
    """Whether to colour, and how to do it.

    Carried around as a value rather than read from the environment at each
    call site, so that one run cannot decide differently in two places, and so
    that a test can ask for either answer without setting an environment
    variable and putting it back.
    """

    var on: Bool

    def __init__(out self, on: Bool):
        self.on = on

    def paint(self, code: StringSpan, text: StringSpan) -> String:
        """`text` wrapped in an SGR code, or `text` when colour is off."""
        if not self.on:
            return String(text)
        return String("\x1b[", code, "m", text, RESET)


def style_for(fd: Int) -> Style:
    """The colour decision for one descriptor.

    Never raises. Reading the environment can fail, and a client that could not
    print a response because it could not find out what `TERM` was would be an
    absurd thing to have written, so a failure here means no colour.
    """
    try:
        if not is_terminal(fd):
            return Style(False)
        var no_color = getenv("NO_COLOR")
        # Set but empty is not set, which is what no-color.org asks for. The
        # distinction matters because an unset variable and one cleared by a
        # wrapper script both arrive here, and only the first was a decision.
        if no_color and no_color.value().byte_length() > 0:
            return Style(False)
        var term = getenv("TERM")
        if term and term.value() == "dumb":
            return Style(False)
        return Style(True)
    except:
        return Style(False)
