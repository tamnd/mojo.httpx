"""The driver: turn a parsed command line into a request, send it, print it.

Everything here is written so that an error is reported once, in one place, and
turned into the right exit code. That is harder than it sounds, because the
same loop is reading from a socket and writing to a pipe, and those two
failures are not the same failure and must not share a code. So the reads and
the writes are caught separately at the point where each happens rather than
together at the top, which is why several of these functions return an exit
code instead of raising.

The output rules that matter, and why:

Only the body goes to stdout unless `--print` or `-v` asks for more, because
the output of this program is meant to be the input of the next one.

The request that is printed is the one that was actually sent, taken back off
the response, so it carries the headers the client added, the cookies from the
jar, and the URL a redirect ended up at. Printing what was built before sending
would have shown something that never went over the wire.

A body that is not text is not written to a terminal. Through a pipe it is
written untouched, byte for byte, because the program on the other end asked
for it.
"""

from httpx import (
    AnyAuth,
    ByteChunks,
    Client,
    Cookies,
    FileUpload,
    Headers,
    Json,
    MultipartData,
    Proxy,
    QueryParams,
    Request,
    Response,
    SSLVerify,
    Timeout,
    basic_auth,
    parse_json,
)
from httpx._bytes import Bytes
from httpx._exceptions import message_of
from httpx._io.files import FileWriter, read_bytes
from httpx._io.stdio import STDERR, STDOUT, is_terminal, write_all, write_text
from httpx.cli.args import Args, parse
from httpx.cli.exits import EXIT_OK, EXIT_STATUS, EXIT_USAGE, code_for
from httpx.cli.help import HELP, version_line
from httpx.cli.progress import Progress
from httpx.cli.render import (
    add_request,
    add_response_head,
    format_json,
    is_json,
)
from httpx.cli.style import Style, style_for


comptime MAX_HELD = 4 * 1024 * 1024
"""How much of a body may be held in memory in order to lay it out.

Only a JSON body on a terminal is ever held, and four megabytes of JSON is
already far more than anybody is going to read off a screen. Past that the
layout is abandoned and the body is streamed as it arrives, because a client
that runs a machine out of memory to indent something is worse than one that
prints a long line.
"""


def _warn(imm e: Error):
    """Report a failure on stderr, as `httpx: what went wrong`.

    The kind name is stripped off. `ConnectError` is a useful thing for a
    caller catching an exception to see and a useless thing to put in front of
    somebody who typed a hostname wrong.

    A failure to write the report is dropped, because a program that cannot
    reach stderr has nothing left to do about it.
    """
    try:
        _ = write_text(STDERR, String("httpx: ", message_of(e), "\n"))
    except:
        pass


def _note(text: StringSpan):
    """Say something on stderr that is not a failure.

    Only when stderr is a terminal. Down a pipe this is somebody's input, and
    a running commentary in it is noise they did not ask for.
    """
    try:
        if is_terminal(STDERR):
            _ = write_text(STDERR, String("httpx: ", text, "\n"))
    except:
        pass


def _basename(path: String) -> String:
    """The last component of a path, which is the name a file is uploaded as.

    Both separators, because the CLI runs on Windows too and a path typed
    there is the one that ends up in the `filename` parameter of the part.
    """
    var cut = -1
    var bytes = path.as_bytes()
    var slash = UInt8(ord("/"))
    var backslash = UInt8(ord("\\"))
    for i in range(len(bytes)):
        if bytes[i] == slash or bytes[i] == backslash:
            cut = i
    if cut < 0:
        return path.copy()
    return String(path[byte = cut + 1 :])


def _client_for(args: Args) raises -> Client:
    """The client the command line describes."""
    var headers = Headers()
    for i in range(len(args.headers)):
        headers.append(args.headers[i].name, args.headers[i].value)

    var cookies = Cookies()
    for i in range(len(args.cookies)):
        cookies.set(args.cookies[i].name, args.cookies[i].value)

    var proxy = Optional[Proxy](None)
    if args.has_proxy:
        proxy = Proxy(args.proxy)

    var auth = Optional[AnyAuth](None)
    if args.has_auth:
        auth = basic_auth(args.auth.name, args.auth.value)

    return Client(
        headers=headers^,
        cookies=cookies^,
        timeout=Timeout.uniform(Optional[Float64](args.timeout)),
        verify=SSLVerify() if args.verify else SSLVerify.off(),
        http2=args.http2,
        proxy=proxy^,
        follow_redirects=args.follow_redirects,
        auth=auth^,
    )


def _request_for(client: Client, args: Args) raises -> Request:
    """The request the command line describes.

    Every file named by `-f` is read here, before anything is sent, so that a
    path that does not exist is reported as the usage error it is rather than
    part way through a multipart body.
    """
    var params = QueryParams()
    for i in range(len(args.params)):
        params = params.add(args.params[i].name, args.params[i].value)

    var form = QueryParams()
    for i in range(len(args.form)):
        form = form.add(args.form[i].name, args.form[i].value)

    var files = MultipartData()
    for i in range(len(args.files)):
        var field = args.files[i].name
        var path = args.files[i].value
        var content: List[UInt8]
        # The flag and the field are named, because the standard library's
        # message is about a path and a command line with three uploads on it
        # is a command line where knowing which one is the point.
        try:
            content = read_bytes(path)
        except e:
            raise Error(String("--files ", field, ": ", message_of(e)))
        files.add_file(FileUpload(field, _basename(path), Bytes(content^)))

    var json = Optional[Json](None)
    if args.has_json:
        # Parsed rather than passed through, so that a typo in a body typed at
        # a prompt is caught here instead of by the server. The flag is named
        # on the way out, because the parser reports a position and a reason
        # and cannot know which of the arguments it was reading.
        try:
            json = parse_json(args.json.as_bytes())
        except e:
            raise Error(String("--json: ", message_of(e)))

    return client.build_request(
        args.method_or_default(),
        args.url,
        text=args.content,
        data=form^,
        files=files^,
        json=json^,
        params=params^,
    )


def _looks_binary(response: Response) raises -> Bool:
    """Whether the body would make a mess of a terminal.

    Decided from `Content-Type` rather than from the bytes. Sniffing would mean
    holding the first chunk back to look at it, and a server that says what it
    is sending should be believed about this much.

    A response with no `Content-Type` at all is treated as text, because that
    is nearly always a small error page from something that did not bother.
    """
    # A list of what is text rather than a list of what is not, because the set
    # of binary types is open and a new one appearing should not be the case
    # that dumps a megabyte of it into somebody's shell.
    var textual: List[String] = [
        "text/",
        "application/json",
        "application/xml",
        "application/javascript",
        "application/x-www-form-urlencoded",
        "+json",
        "+xml",
    ]
    var lowered = response.headers.get("content-type", "text/plain").lower()
    for i in range(len(textual)):
        if lowered.find(textual[i]) >= 0:
            return False
    return True


def _push[o: ImmOrigin](data: Span[UInt8, o], mut stopped: Bool) -> Int:
    """Write to stdout, and say separately whether the reader is still there.

    A closed pipe is not a failure, so it comes back as `stopped` rather than
    as an exit code. That is how `httpx URL | head -1` ends and answering it
    with a message would be wrong in the same way a stack trace would be.
    """
    try:
        if not write_all(STDOUT, data):
            stopped = True
        return EXIT_OK
    except e:
        _warn(e)
        return EXIT_USAGE


def _to_stdout(mut response: Response, forced: Bool, style: Style) -> Int:
    """Write the body to stdout, a chunk at a time.

    `forced` is `--download -`, which is somebody saying they want the bytes on
    stdout whatever they are, so both the terminal check and the layout are
    skipped and the bytes go out as they arrived.

    A JSON body on a terminal is held and laid out. Nowhere else is anything
    held: down a pipe or into a file the chunks go straight out, so a body
    larger than memory is still a body this can print and the bytes on the
    other side are the server's own.
    """
    var terminal: Bool
    var holding: Bool
    try:
        terminal = is_terminal(STDOUT)
        if not forced and terminal and _looks_binary(response):
            _note(
                String(
                    "the body is ",
                    response.headers.get("content-type", "of unknown type"),
                    (
                        " and is not being written to a terminal. Redirect it,"
                        " or use --download to save it."
                    ),
                )
            )
            return EXIT_OK
        holding = terminal and not forced and is_json(response)
    except e:
        _warn(e)
        return EXIT_USAGE

    var chunks: ByteChunks
    try:
        chunks = response.iter_bytes()
    except e:
        _warn(e)
        return code_for(e)

    var held = List[UInt8]()
    var stopped = False
    while chunks.has_next() and not stopped:
        var chunk: List[UInt8]
        try:
            chunk = chunks.next()
        except e:
            _warn(e)
            return code_for(e)
        if holding and len(held) + len(chunk) <= MAX_HELD:
            held.extend(chunk.copy())
            continue
        if holding:
            # Bigger than the bound, so give up on laying it out and become an
            # ordinary stream from here on. What has been held goes out first,
            # in order, and nothing has been changed on the way.
            holding = False
            var flushed = _push(Span(held), stopped)
            if flushed != EXIT_OK:
                return flushed
            held.clear()
            if stopped:
                return EXIT_OK
        var wrote = _push(Span(chunk), stopped)
        if wrote != EXIT_OK:
            return wrote
    if not holding:
        return EXIT_OK

    var shaped = List[UInt8]()
    var laid_out = False
    try:
        shaped = format_json(Span(held), style)
        laid_out = True
    except:
        # It said JSON and it is not. Print what arrived: it is usually an
        # error page from something in the middle, and that page is the answer.
        pass
    if laid_out:
        return _push(Span(shaped), stopped)
    return _push(Span(held), stopped)


def _shut(mut writer: FileWriter) -> Bool:
    """Close a download, reporting a failure rather than raising it.

    Separate from the writing so that the error paths below can close the file
    on the way out without each of them growing a second `try`.
    """
    try:
        writer.close()
        return True
    except e:
        _warn(e)
        return False


def _expected_size(response: Response) -> Int:
    """How many bytes the body should come to, or a negative number.

    `Content-Length` counts the bytes on the wire, so a compressed response is
    a different number from the one that ends up in the file and the bar would
    run past its own end. Rather than guess a ratio, a response with a
    `Content-Encoding` is treated as one of unknown size, which is what a
    chunked response without a length is anyway.
    """
    try:
        if "content-encoding" in response.headers:
            return -1
        var stated = response.headers.get("content-length", "")
        if stated.byte_length() == 0:
            return -1
        return Int(stated)
    except:
        return -1


def _to_file(
    mut response: Response, mut writer: FileWriter, path: String
) -> Int:
    """Write the body to a file, a chunk at a time, with a bar on stderr.

    The file was opened before the request went out, so a path that cannot be
    written is a usage error reported without a request being made at all. The
    cost is that the file is truncated before anything has arrived, which is
    what curl does with `-o` and for the same reason: there is no way to find
    out whether a path can be written except by writing to it.

    The bar draws itself only when stderr is a terminal, so `httpx --download
    f URL 2>log` writes a log with nothing in it rather than one full of
    carriage returns.
    """
    var chunks: ByteChunks
    try:
        chunks = response.iter_bytes()
    except e:
        _warn(e)
        _ = _shut(writer)
        return code_for(e)

    var bar = Progress(path, _expected_size(response))
    bar.start()
    while chunks.has_next():
        var chunk: List[UInt8]
        try:
            chunk = chunks.next()
        except e:
            # The bar is ended before the message is written, so that the
            # message lands on a line of its own rather than on top of a bar
            # that stopped halfway.
            bar.finish()
            _warn(e)
            _ = _shut(writer)
            return code_for(e)
        try:
            writer.write(Span(chunk))
            bar.advance(len(chunk))
        except e:
            bar.finish()
            _warn(e)
            _ = _shut(writer)
            return EXIT_USAGE

    bar.finish()
    if not _shut(writer):
        return EXIT_USAGE
    return EXIT_OK


def _deliver(
    mut response: Response, mut download: Optional[FileWriter], args: Args
) -> Int:
    """Print what was asked for and say how it went.

    `download` is the already opened file when `--download` named one, and
    nothing otherwise. It is opened by the caller rather than here, because a
    path that cannot be written should be found out before a request is made
    and not after a body has arrived.
    """
    # One decision about colour for the whole run, taken before anything is
    # written, so that the heads and the body cannot disagree about it.
    var style = style_for(STDOUT)

    var head = List[UInt8]()
    try:
        if args.shows_request_headers() or args.shows_request_body():
            add_request(head, response, args, style)
        if args.shows_response_headers():
            add_response_head(head, response, style)
    except e:
        _warn(e)
        return EXIT_USAGE

    if len(head) > 0:
        try:
            if not write_all(STDOUT, Span(head)):
                return EXIT_OK
        except e:
            _warn(e)
            return EXIT_USAGE

    if args.fail and response.is_error():
        # The heads are printed first, because somebody who asked for them with
        # -v asked for them in order to find out why this happened.
        _warn(
            Error(
                String(
                    "the server answered ",
                    response.status_code,
                    " ",
                    response.reason_phrase,
                )
            )
        )
        return EXIT_STATUS

    if download:
        ref writer = download.value()
        return _to_file(response, writer, args.download)

    # `--download -` has no file, and is somebody asking for the bytes on
    # stdout whatever they are, so it skips the terminal check.
    if args.has_download:
        return _to_stdout(response, True, style)

    if not args.shows_response_body():
        return EXIT_OK
    return _to_stdout(response, False, style)


def _exchange(args: Args) -> Int:
    """Everything from building the client to closing the response.

    Failures are split by where they happened. Anything before the send is the
    command line being wrong about something, whatever it was raised as: a URL
    that will not parse, a proxy that is not a proxy, a `--json` body that is
    not JSON, a file to upload that is not there. Anything from the send
    onwards goes through the exit code table.
    """
    var client: Client
    var request: Request
    var download = Optional[FileWriter](None)
    try:
        client = _client_for(args)
        request = _request_for(client, args)
        if args.has_download and args.download != "-":
            download = FileWriter(args.download)
    except e:
        _warn(e)
        return EXIT_USAGE

    var response: Response
    try:
        # Streamed, so that a download starts writing before the whole body has
        # arrived and a body larger than memory is still a body this can print.
        response = client.send(request^, stream=True)
    except e:
        _warn(e)
        return code_for(e)

    var code = _deliver(response, download, args)
    response.close()
    return code


def run(argv: List[String]) -> Int:
    """Run one command line and return the exit code. Never raises.

    `argv` is the arguments with the program name already dropped, which is the
    same shape `parse` takes, so a test can drive the whole program without a
    process.
    """
    var args: Args
    try:
        args = parse(argv)
    except e:
        _warn(e)
        return EXIT_USAGE

    if args.wants_help or args.wants_version:
        try:
            _ = write_text(STDOUT, HELP if args.wants_help else version_line())
        except e:
            _warn(e)
            return EXIT_USAGE
        return EXIT_OK

    return _exchange(args)
