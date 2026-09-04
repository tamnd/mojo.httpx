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
from httpx._proto.h1.writer import (
    TargetForm,
    host_header_value,
    request_target,
)
from httpx.cli.args import Args, parse
from httpx.cli.exits import EXIT_OK, EXIT_STATUS, EXIT_USAGE, code_for
from httpx.cli.help import HELP, version_line


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


def _add[o: ImmOrigin](mut buf: List[UInt8], data: Span[UInt8, o]):
    buf.extend(data)


def _add_text(mut buf: List[UInt8], text: StringSpan):
    buf.extend(text.as_bytes())


def _add_headers(mut buf: List[UInt8], headers: Headers):
    """Field lines as they were supplied, one per line, then a blank one."""
    for i in range(len(headers)):
        _add(buf, headers.raw_name(i))
        _add_text(buf, ": ")
        _add(buf, headers.raw_value(i))
        _add_text(buf, "\r\n")
    _add_text(buf, "\r\n")


def _add_request(
    mut buf: List[UInt8], mut response: Response, args: Args
) raises:
    """The request that went out, in wire form.

    The version comes off the response, because it is the exchange that decides
    whether this was HTTP/1.1 or HTTP/2 and the request does not know until it
    has been sent. An HTTP/2 exchange is shown in this shape too, with its
    pseudo-headers written out as an ordinary request line, which is what every
    other tool does and is the only form most people can read. That shape shows
    the hop-by-hop headers an HTTP/2 connection does not actually carry, which
    is the one place this is a rendering of the request rather than a copy of
    the bytes.

    `Host` is not in the request's own headers, because it is written from the
    URL as the message goes out. It is put back here from the same function the
    writer uses, so that what is printed is what was sent rather than what was
    left in the struct.
    """
    if not response.has_request():
        return
    ref request = response.request()
    if args.shows_request_headers():
        _add_text(buf, request.method)
        _add_text(buf, " ")
        _add_text(buf, request_target(request.url, TargetForm.ORIGIN))
        _add_text(buf, " ")
        _add_text(buf, response.http_version)
        _add_text(buf, "\r\n")
        if "host" not in request.headers:
            _add_text(buf, "Host: ")
            _add_text(buf, host_header_value(request.url))
            _add_text(buf, "\r\n")
        _add_headers(buf, request.headers)
    if args.shows_request_body():
        _add(buf, Span(request.content))
        _add_text(buf, "\r\n")


def _add_response_head(mut buf: List[UInt8], response: Response):
    """The status line and the response headers, in wire form."""
    _add_text(buf, response.http_version)
    _add_text(buf, " ")
    _add_text(buf, String(response.status_code))
    _add_text(buf, " ")
    _add_text(buf, response.reason_phrase)
    _add_text(buf, "\r\n")
    _add_headers(buf, response.headers)


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


def _to_stdout(mut response: Response, forced: Bool) -> Int:
    """Write the body to stdout, a chunk at a time.

    `forced` is `--download -`, which is somebody saying they want the bytes on
    stdout whatever they are, so the terminal check is skipped.
    """
    try:
        if not forced and is_terminal(STDOUT) and _looks_binary(response):
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
    except e:
        _warn(e)
        return EXIT_USAGE

    var chunks: ByteChunks
    try:
        chunks = response.iter_bytes()
    except e:
        _warn(e)
        return code_for(e)

    while chunks.has_next():
        var chunk: List[UInt8]
        try:
            chunk = chunks.next()
        except e:
            _warn(e)
            return code_for(e)
        try:
            if not write_all(STDOUT, Span(chunk)):
                # The reader went away. That is how `httpx URL | head -1`
                # ends and it is not a failure of this program.
                return EXIT_OK
        except e:
            _warn(e)
            return EXIT_USAGE
    return EXIT_OK


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


def _to_file(
    mut response: Response, mut writer: FileWriter, path: String
) -> Int:
    """Write the body to a file, a chunk at a time.

    The file was opened before the request went out, so a path that cannot be
    written is a usage error reported without a request being made at all. The
    cost is that the file is truncated before anything has arrived, which is
    what curl does with `-o` and for the same reason: there is no way to find
    out whether a path can be written except by writing to it.
    """
    var chunks: ByteChunks
    try:
        chunks = response.iter_bytes()
    except e:
        _warn(e)
        _ = _shut(writer)
        return code_for(e)

    var written = 0
    while chunks.has_next():
        var chunk: List[UInt8]
        try:
            chunk = chunks.next()
        except e:
            _warn(e)
            _ = _shut(writer)
            return code_for(e)
        try:
            writer.write(Span(chunk))
            written += len(chunk)
        except e:
            _warn(e)
            _ = _shut(writer)
            return EXIT_USAGE

    if not _shut(writer):
        return EXIT_USAGE
    _note(String("wrote ", written, " bytes to ", path))
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
    var head = List[UInt8]()
    try:
        if args.shows_request_headers() or args.shows_request_body():
            _add_request(head, response, args)
        if args.shows_response_headers():
            _add_response_head(head, response)
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
        return _to_stdout(response, True)

    if not args.shows_response_body():
        return EXIT_OK
    return _to_stdout(response, False)


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
