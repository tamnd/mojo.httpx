"""Reading the command line.

Mojo has no argparse, so the parser is written out here. That is a smaller loss
than it sounds. The flags are httpx2's, they are fixed, and a plain loop over
the arguments is easier to follow than a table driven parser whose table would
have six shapes in it.

The forms accepted are the ones people expect from a command line tool, and
they are worth writing down, because a parser that guesses at what was meant is
worse than one that refuses:

    httpx -m POST https://example.com           a short flag and its value
    httpx -mPOST https://example.com            the same, joined
    httpx --method=POST https://example.com     a long flag joined with =
    httpx -h Accept application/json URL        two values, a name and a value
    httpx -vm POST URL                          a cluster, the last one takes
                                                the value
    httpx -- -not-a-flag                        nothing after -- is a flag

`-h` is `--headers` and not help. That surprises people who reach for it out of
habit, and it is that way because it is that way in httpx2, where matching flag
for flag matters more than matching the habit. Help is `--help` only.

Two things are deliberately refused rather than guessed at. An option that
takes a name and a value wants them as two separate arguments, so `-h Name:x`
and `--headers=Name` are errors instead of being split on some character this
file invented. And a switch given a value, as in `--http2=yes`, is an error
rather than a truthiness test on the word.

One thing is deliberately accepted: the value after an option is whatever comes
next, even when it starts with a dash. Header values, passwords and query
parameters really do start with dashes, and a parser that refused them would be
wrong more often than it was helpful.

Nothing here opens a socket or reads a file. Parsing produces `Args` and every
complaint about the command line is raised from this file, which is what lets
the driver turn any error out of `parse` into the usage exit code without
having to work out where it came from.
"""

from std.math import isfinite

from httpx._config import DEFAULT_TIMEOUT_SECONDS

comptime SHOW_DEFAULT = "b"
"""What gets printed when nothing asks for more: the response body, alone.

Body only, because the output of this program is meant to be the input of the
next one. Anything else on stdout by default would mean every user of the tool
learning a flag to turn it off before a pipeline works.
"""

comptime SHOW_VERBOSE = "Hhb"
"""What `-v` asks for: the request headers, the response headers, the body.

The request body is not in the set, because it is usually the thing the caller
just typed and it can be large. `--print HBhb` asks for it when it is wanted.
"""

comptime SHOW_LETTERS = "HBhb"
"""The letters `--print` accepts.

Upper case is the request, lower case is the response, `H` and `h` are the
headers and `B` and `b` are the bodies. It is httpie's notation rather than an
invention, so anybody who has used that tool already knows this one.
"""


struct Pair(ImplicitlyCopyable, Movable):
    """A name and a value, the shape of every two argument option."""

    var name: String
    var value: String

    def __init__(out self, name: String, value: String):
        self.name = name
        self.value = value

    def __init__(out self):
        self.name = String("")
        self.value = String("")


struct Args(Movable):
    """A command line, taken apart.

    Everything is here as it was written, not as it will be used. Values are
    not looked up, files are not opened, and the URL is not parsed. That is the
    line between this file and the driver, and it is what makes the parser
    testable without a network or a filesystem.
    """

    var method: String
    """The method as given, empty when the command line did not say."""

    var url: String
    """The one positional argument."""

    var params: List[Pair]
    var headers: List[Pair]
    var cookies: List[Pair]
    var form: List[Pair]
    var files: List[Pair]

    var content: String
    var has_content: Bool

    var json: String
    var has_json: Bool

    var auth: Pair
    var has_auth: Bool

    var proxy: String
    var has_proxy: Bool

    var timeout: Float64

    var follow_redirects: Bool
    """On by default, unlike the library.

    The library leaves it off because a program that follows a redirect it did
    not ask for can leak a request to somewhere the caller never named, and the
    caller of a library is code that can check. At a shell prompt the caller is
    a person who typed a URL and wants the page, so this follows, the way curl
    -L and every browser do. httpx2 draws the line in the same place.
    """

    var verify: Bool
    var http2: Bool

    var download: String
    var has_download: Bool

    var show: String
    """Which parts to print, as `--print` letters."""

    var fail: Bool
    """Whether an error status should be an exit code rather than output."""

    var wants_help: Bool
    var wants_version: Bool

    def __init__(out self):
        """Every default, which is what parsing starts from."""
        self.method = String("")
        self.url = String("")
        self.params = List[Pair]()
        self.headers = List[Pair]()
        self.cookies = List[Pair]()
        self.form = List[Pair]()
        self.files = List[Pair]()
        self.content = String("")
        self.has_content = False
        self.json = String("")
        self.has_json = False
        self.auth = Pair()
        self.has_auth = False
        self.proxy = String("")
        self.has_proxy = False
        self.timeout = Float64(DEFAULT_TIMEOUT_SECONDS)
        self.follow_redirects = True
        self.verify = True
        self.http2 = False
        self.download = String("")
        self.has_download = False
        self.show = String(SHOW_DEFAULT)
        self.fail = False
        self.wants_help = False
        self.wants_version = False

    def has_body(self) -> Bool:
        """Whether anything on the command line asked for a request body."""
        return (
            self.has_content
            or self.has_json
            or len(self.form) > 0
            or len(self.files) > 0
        )

    def method_or_default(self) -> String:
        """The method to send: what was asked for, or what the body implies.

        GET, unless there is a body, in which case POST. httpx2 does the same,
        and it is the rule that makes `httpx -d name value URL` do what the
        person typing it meant without a `-m POST` they would only ever forget.
        """
        if self.method.byte_length() > 0:
            return self.method
        return String("POST") if self.has_body() else String("GET")

    def shows_request_headers(self) -> Bool:
        """Whether the request line and its headers are wanted."""
        return self.show.find("H") >= 0

    def shows_request_body(self) -> Bool:
        """Whether the body that was sent is wanted."""
        return self.show.find("B") >= 0

    def shows_response_headers(self) -> Bool:
        """Whether the status line and its headers are wanted."""
        return self.show.find("h") >= 0

    def shows_response_body(self) -> Bool:
        """Whether the body that came back is wanted."""
        return self.show.find("b") >= 0


def _is_switch(name: String) -> Bool:
    """Whether an option is a switch, meaning it takes no value at all."""
    return (
        name == "--help"
        or name == "--version"
        or name == "--http2"
        or name == "--fail"
        or name == "--verify"
        or name == "--no-verify"
        or name == "--follow-redirects"
        or name == "--no-follow-redirects"
        or name == "--verbose"
    )


def _long_for(letter: String) raises -> String:
    """The long name a short flag stands for.

    Short flags are spelled out into long ones before anything is done with
    them, so there is one list of what each option means rather than two lists
    that can drift apart.
    """
    if letter == "m":
        return String("--method")
    if letter == "p":
        return String("--params")
    if letter == "c":
        return String("--content")
    if letter == "d":
        return String("--data")
    if letter == "f":
        return String("--files")
    if letter == "j":
        return String("--json")
    if letter == "h":
        return String("--headers")
    if letter == "v":
        return String("--verbose")
    raise Error(String("-", letter, " is not an option"))


def _value(
    name: String,
    joined: String,
    has_joined: Bool,
    argv: List[String],
    mut index: Int,
) raises -> String:
    """The single value an option wants, joined to it or following it."""
    if has_joined:
        return joined
    if index >= len(argv):
        raise Error(String(name, " wants a value"))
    var value = argv[index]
    index += 1
    return value


def _pair(
    name: String,
    has_joined: Bool,
    argv: List[String],
    mut index: Int,
) raises -> Pair:
    """The two values an option wants, as the two arguments after it."""
    if has_joined:
        raise Error(
            String(
                name,
                (
                    " wants a name and a value as two separate arguments, not"
                    " joined onto the flag"
                ),
            )
        )
    if index + 1 >= len(argv):
        raise Error(String(name, " wants a name and a value"))
    var pair = Pair(argv[index], argv[index + 1])
    index += 2
    return pair


def _seconds(text: String) raises -> Float64:
    """A `--timeout` value, in seconds.

    Zero is allowed and means a non blocking attempt, which is the same reading
    the library gives it. Negative is not, because it has no reading that
    differs from zero and taking it would hide a sign error in whatever
    produced the command line.
    """
    var seconds: Float64
    try:
        seconds = Float64(text)
    except:
        raise Error(
            String(
                "--timeout wants a number of seconds, and ",
                text,
                " is not one",
            )
        )
    # `nan` and `inf` both parse, and both would reach the client as a timeout
    # that never expires, which is the opposite of what somebody setting a
    # timeout is asking for.
    if not isfinite(seconds):
        raise Error(
            String(
                "--timeout wants a number of seconds, and ",
                text,
                " is not one",
            )
        )
    if seconds < 0.0:
        raise Error(
            String("--timeout cannot be negative, and it was given as ", text)
        )
    return seconds


def _letters(text: String) raises -> String:
    """A `--print` value, checked a letter at a time."""
    var bytes = text.as_bytes()
    if len(bytes) == 0:
        raise Error("--print wants at least one of H, B, h and b")
    for i in range(len(bytes)):
        var one = String(text[byte = i : i + 1])
        if String(SHOW_LETTERS).find(one) < 0:
            raise Error(
                String(
                    "--print takes the letters H, B, h and b, and ",
                    one,
                    " is not one of them",
                )
            )
    return text


def _apply(
    mut args: Args,
    name: String,
    joined: String,
    has_joined: Bool,
    argv: List[String],
    mut index: Int,
) raises:
    """Act on one option, having already found its name."""
    if _is_switch(name) and has_joined:
        raise Error(String(name, " is a switch and takes no value"))

    if name == "--help":
        args.wants_help = True
    elif name == "--version":
        args.wants_version = True
    elif name == "--http2":
        args.http2 = True
    elif name == "--fail":
        args.fail = True
    elif name == "--verify":
        args.verify = True
    elif name == "--no-verify":
        args.verify = False
    elif name == "--follow-redirects":
        args.follow_redirects = True
    elif name == "--no-follow-redirects":
        args.follow_redirects = False
    elif name == "--verbose":
        # Exactly `--print Hhb`, so there is one field saying what gets
        # printed and the last of the two flags on the line wins.
        args.show = String(SHOW_VERBOSE)
    elif name == "--method":
        args.method = _value(name, joined, has_joined, argv, index)
    elif name == "--content":
        args.content = _value(name, joined, has_joined, argv, index)
        args.has_content = True
    elif name == "--json":
        args.json = _value(name, joined, has_joined, argv, index)
        args.has_json = True
    elif name == "--proxy":
        args.proxy = _value(name, joined, has_joined, argv, index)
        args.has_proxy = True
    elif name == "--download":
        args.download = _value(name, joined, has_joined, argv, index)
        args.has_download = True
    elif name == "--print":
        args.show = _letters(_value(name, joined, has_joined, argv, index))
    elif name == "--timeout":
        args.timeout = _seconds(_value(name, joined, has_joined, argv, index))
    elif name == "--params":
        args.params.append(_pair(name, has_joined, argv, index))
    elif name == "--data":
        args.form.append(_pair(name, has_joined, argv, index))
    elif name == "--files":
        args.files.append(_pair(name, has_joined, argv, index))
    elif name == "--headers":
        args.headers.append(_pair(name, has_joined, argv, index))
    elif name == "--cookies":
        args.cookies.append(_pair(name, has_joined, argv, index))
    elif name == "--auth":
        args.auth = _pair(name, has_joined, argv, index)
        args.has_auth = True
    else:
        raise Error(String(name, " is not an option"))


def _cluster(
    mut args: Args,
    arg: String,
    argv: List[String],
    mut index: Int,
) raises:
    """Act on a run of short flags, which may be one flag or several.

    Switches can be piled up, and the first flag that wants a value takes the
    rest of the cluster as that value if there is any left, or the arguments
    after it if there is not. So `-vv`, `-vmPOST` and `-vm POST` all mean what
    they look like they mean.
    """
    var at = 1
    var n = arg.byte_length()
    while at < n:
        var letter = String(arg[byte = at : at + 1])
        at += 1
        var name = _long_for(letter)
        if _is_switch(name):
            _apply(args, name, String(""), False, argv, index)
            continue
        # An option wanting two values refuses an attached one, so `-hName`
        # is named as a mistake rather than guessed at as a first value.
        var joined = String(arg[byte=at:])
        _apply(args, name, joined, joined.byte_length() > 0, argv, index)
        return


def _looks_like_option(arg: String) -> Bool:
    """Whether an argument is a flag rather than the URL.

    A lone dash is not, because it is a filename in every tool that has one and
    a URL is the only positional argument here. An empty argument is not
    either, and it will be caught later as a URL that cannot be parsed.
    """
    if arg.byte_length() < 2:
        return False
    return arg.startswith("-")


def parse(argv: List[String]) raises -> Args:
    """Take a command line apart, or say what is wrong with it.

    `argv` is the arguments only, with the program name already dropped, so a
    test can hand it a list without building one.

    Everything raised from here is a usage error and nothing else is, which is
    the whole reason the parser does no work beyond parsing. The driver catches
    around this one call and exits with the usage code, and it does not have to
    ask what kind of failure it caught.
    """
    var args = Args()
    var seen_url = False
    var flags_are_over = False
    var index = 0

    while index < len(argv):
        # `--help` and `--version` stop the parse where they stand. Somebody
        # asking for the help is often somebody who could not get the rest of
        # the line right, and answering a mistake instead of the question would
        # be unkind.
        if args.wants_help or args.wants_version:
            return args^

        var arg = argv[index]
        index += 1

        if flags_are_over or not _looks_like_option(arg):
            if seen_url:
                raise Error(
                    String(
                        "one URL at a time, and both ",
                        args.url,
                        " and ",
                        arg,
                        " were given",
                    )
                )
            args.url = arg
            seen_url = True
            continue

        if arg == "--":
            flags_are_over = True
            continue

        if arg.startswith("--"):
            var name = arg
            var joined = String("")
            var has_joined = False
            var eq = arg.find("=")
            if eq >= 0:
                name = String(arg[byte=0:eq])
                joined = String(arg[byte = eq + 1 :])
                has_joined = True
            _apply(args, name, joined, has_joined, argv, index)
            continue

        _cluster(args, arg, argv, index)

    if not seen_url and not args.wants_help and not args.wants_version:
        raise Error("no URL, and there is nothing to request without one")

    return args^
