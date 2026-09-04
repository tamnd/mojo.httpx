"""`multipart/form-data`, the encoding used for file uploads.

```mojo
var form = MultipartData()
form.add("title", "holiday")
form.add_file(FileUpload("photo", "beach.jpg", photo_bytes^))
```

The format is RFC 7578, but what servers actually implement is the WHATWG HTML
form submission algorithm, and where the two differ this follows the browsers.
That is not a shortcut. A client that encodes the way the specification reads
rather than the way browsers do produces bodies that the receiving framework
parses differently from the same form submitted from a page, and the difference
shows up as a filename that is subtly wrong on one path and right on the other.

## Two places this can go wrong

The boundary is the only thing separating one part from the next, and it is not
escaped anywhere. If a part's content contains the boundary, the server sees
parts that were never sent. So the boundary is sixteen bytes from the operating
system's entropy pool rather than a counter or a timestamp, and every part is
checked against it before the body is built. Both, not either: the random
boundary makes a collision impossible to arrange, and the check makes it
impossible to miss.

Field names and filenames go inside a quoted string in a header, and a quote or
a line ending in one of them closes the string early and starts writing headers
the caller did not write. They are escaped, and the escaping is the browsers'
rather than RFC 2231's, because RFC 2231 is the part enough server side form
parsers do not implement.
"""

from httpx._bytes import Bytes, equal_ascii_ci, index_of_span
from httpx._exceptions import ErrorKind, new_error
from httpx._ffi.c import random_bytes
from std.collections.string import StringSpan

comptime _CRLF = StaticString("\r\n")
comptime _DASHES = StaticString("--")

comptime DEFAULT_FILE_TYPE = StaticString("application/octet-stream")
"""What a file gets when nothing better is known.

The same answer `mimetypes.guess_type` gives for an unknown extension, and the
right one. A wrong content type is worse than an unspecific one, because the
receiving side may act on it.
"""


struct FileUpload(Movable):
    """One file in a multipart body.

    `content_type` may be left empty, in which case it is guessed from the
    filename. The filename may be empty too, which produces a part with no
    `filename` parameter at all.

    ```mojo
    from httpx import Client, FileUpload, MultipartData


    def main() raises:
        var form = MultipartData()
        form.add("caption", "the roof")
        form.add_file(FileUpload("photo", "roof.png", "not really a png"))
        with Client() as client:
            print(client.post("https://example.com/upload", files=form^).status_code)
    ```
    """

    var field: String
    var filename: String
    var content_type: String
    var content: Bytes

    def __init__(
        out self,
        field: StringSpan,
        filename: StringSpan,
        var content: Bytes,
        content_type: StringSpan = "",
    ):
        self.field = String(field)
        self.filename = String(filename)
        self.content_type = String(content_type)
        self.content = content^

    def __init__(
        out self,
        field: StringSpan,
        filename: StringSpan,
        content: StringSpan,
        content_type: StringSpan = "",
    ):
        self = Self(field, filename, Bytes(content), content_type)

    def copy(self) -> Self:
        return Self(
            self.field,
            self.filename,
            self.content.copy(),
            self.content_type,
        )

    def resolved_type(self) -> String:
        """The content type to write, guessing from the filename if needed."""
        if self.content_type != "":
            return self.content_type.copy()
        return String(guess_type(self.filename))


struct MultipartData(Boolable, Movable, Sized):
    """The text fields and the files that make up one `multipart/form-data` body.

    Both live in the same body. The fields are written first and then the files,
    each group in the order it was added, which is the order httpx2 writes them
    and matters because some server side parsers hand the application whichever
    part they saw last under a repeated name.

    ```mojo
    from httpx import Client, FileUpload, MultipartData


    def main() raises:
        var form = MultipartData()
        form.add("name", "alice")
        form.add_file(FileUpload("avatar", "me.png", "not really a png"))
        with Client() as client:
            var r = client.post("https://example.com/profile", files=form^)
            print(r.status_code)
    ```
    """

    var names: List[String]
    var values: List[String]
    var files: List[FileUpload]

    def __init__(out self):
        self.names = List[String]()
        self.values = List[String]()
        self.files = List[FileUpload]()

    def copy(self) -> Self:
        var out = Self()
        out.names = self.names.copy()
        out.values = self.values.copy()
        for i in range(len(self.files)):
            out.files.append(self.files[i].copy())
        return out^

    def __len__(self) -> Int:
        return len(self.names) + len(self.files)

    def __bool__(self) -> Bool:
        return len(self) > 0

    def add(mut self, name: StringSpan, value: StringSpan):
        """A text field. Repeating a name is allowed and sends both."""
        self.names.append(String(name))
        self.values.append(String(value))

    def add_file(mut self, var upload: FileUpload):
        self.files.append(upload^)


def escape_form_param(name: StringSpan) -> Bytes:
    """Make a name safe to put between the quotes in a `Content-Disposition`.

    A quote or a line ending in a field name or a filename is the whole attack.
    Unescaped, a filename of `x"` followed by a carriage return and a line feed
    closes the quoted string, ends the header block, and starts a body of the
    caller's choosing inside a part the application believes it controls.

    Three characters are escaped as percent sequences and nothing else is
    touched. That is what browsers do, and matching browsers is the point: a
    server parses the body this produces exactly the way it parses the same form
    submitted from a page, so there is no path where a filename means one thing
    to the validator and another to the storage layer.

    RFC 2231 has a proper mechanism for this, `filename*=UTF-8''...`, and it is
    the better design and not what enough server side parsers implement. Using
    it would mean correct bodies that some frameworks read as having no filename
    at all.
    """
    var out = Bytes()
    for byte in name.as_bytes():
        if byte == UInt8(ord('"')):
            out.extend("%22".as_bytes())
        elif byte == UInt8(ord("\r")):
            out.extend("%0D".as_bytes())
        elif byte == UInt8(ord("\n")):
            out.extend("%0A".as_bytes())
        else:
            out.append(byte)
    return out^


def _extension[o: ImmOrigin](filename: Span[UInt8, o]) -> Span[UInt8, o]:
    """What follows the last dot, or nothing.

    The last dot rather than the first, so `archive.tar.gz` is a gzip and not a
    tar, which is what every other implementation says and what the file
    actually is.
    """
    var dot = -1
    for i in range(filename.__len__()):
        if filename[i] == UInt8(ord(".")):
            dot = i
    if dot < 0:
        return filename[0:0]
    return filename[dot + 1 :]


def _is[
    o: ImmOrigin
](extension: Span[UInt8, o], candidate: StaticString) -> Bool:
    return equal_ascii_ci(extension, candidate.as_bytes())


def guess_type(filename: StringSpan) -> StaticString:
    """A content type from a filename extension.

    A short table rather than a full mime database. Mojo has no `mimetypes`,
    reading the platform's copy means opening a file at a path that differs per
    system, and a wrong guess is worse than `application/octet-stream` because
    the receiving side may act on it. So this covers what people upload and says
    nothing about anything else.

    A caller who knows better passes `content_type` and skips this entirely.
    """
    var ext = _extension(filename.as_bytes())
    if ext.__len__() == 0:
        return DEFAULT_FILE_TYPE

    if _is(ext, "txt") or _is(ext, "text") or _is(ext, "log"):
        return "text/plain"
    if _is(ext, "html") or _is(ext, "htm"):
        return "text/html"
    if _is(ext, "css"):
        return "text/css"
    if _is(ext, "csv"):
        return "text/csv"
    if _is(ext, "md"):
        return "text/markdown"
    if _is(ext, "js") or _is(ext, "mjs"):
        return "text/javascript"
    if _is(ext, "json"):
        return "application/json"
    if _is(ext, "xml"):
        return "application/xml"
    if _is(ext, "pdf"):
        return "application/pdf"
    if _is(ext, "zip"):
        return "application/zip"
    if _is(ext, "gz") or _is(ext, "tgz"):
        return "application/gzip"
    if _is(ext, "tar"):
        return "application/x-tar"
    if _is(ext, "png"):
        return "image/png"
    if _is(ext, "jpg") or _is(ext, "jpeg"):
        return "image/jpeg"
    if _is(ext, "gif"):
        return "image/gif"
    if _is(ext, "webp"):
        return "image/webp"
    if _is(ext, "svg"):
        return "image/svg+xml"
    if _is(ext, "ico"):
        return "image/vnd.microsoft.icon"
    if _is(ext, "mp3"):
        return "audio/mpeg"
    if _is(ext, "wav"):
        return "audio/wav"
    if _is(ext, "mp4"):
        return "video/mp4"
    if _is(ext, "webm"):
        return "video/webm"
    return DEFAULT_FILE_TYPE


def generate_boundary() raises -> String:
    """Sixteen random bytes written as thirty two hexadecimal characters.

    Hexadecimal because the boundary goes into a header value unquoted, so every
    character has to be one RFC 2046 allows. Thirty two characters because the
    limit is seventy and the entropy is what matters. The same shape httpx2
    produces, so a body from either library looks the same to a server and to
    anybody comparing the two on the wire.
    """
    comptime DIGITS = StaticString("0123456789abcdef")
    var bytes = random_bytes(16)
    var out = String()
    for byte in bytes:
        out += chr(Int(DIGITS.as_bytes()[Int(byte >> 4)]))
        out += chr(Int(DIGITS.as_bytes()[Int(byte & 0xF)]))
    return out^


def _collides(data: MultipartData, boundary: StringSpan) -> Bool:
    """Whether the boundary appears anywhere it would be read as one.

    Names and filenames as well as content, because all three end up in the body
    and a boundary in any of them splits the part just the same.
    """
    var needle = boundary.as_bytes()
    for i in range(len(data.names)):
        if index_of_span(data.names[i].as_bytes(), needle) >= 0:
            return True
        if index_of_span(data.values[i].as_bytes(), needle) >= 0:
            return True
    for i in range(len(data.files)):
        ref file = data.files[i]
        if index_of_span(file.field.as_bytes(), needle) >= 0:
            return True
        if index_of_span(file.filename.as_bytes(), needle) >= 0:
            return True
        if index_of_span(file.content.as_span(), needle) >= 0:
            return True
    return False


def choose_boundary(data: MultipartData) raises -> String:
    """A boundary that does not appear in what is about to be sent.

    Both halves matter. Sixteen bytes of real entropy means nobody can arrange a
    collision, because arranging one means including a value they cannot
    predict. Checking anyway means that if one somehow happens the body is not
    built rather than built wrong, and a body built wrong here is a server
    reading parts that were never sent.

    With 128 bits the retry never runs. It is here so that the failure mode is a
    second draw rather than a silently corrupt upload.
    """
    comptime ATTEMPTS = 8
    for _ in range(ATTEMPTS):
        var boundary = generate_boundary()
        if not _collides(data, boundary):
            return boundary^
    raise new_error(
        ErrorKind.INVALID_ARGUMENT,
        String(
            "could not find a multipart boundary absent from the data after ",
            ATTEMPTS,
            (
                " tries. With a working random source this is not possible, so"
                " treat it as the machine being broken rather than the data"
                " being unusual."
            ),
        ),
    )


def render_multipart(data: MultipartData, boundary: StringSpan) -> Bytes:
    """The body bytes, given a boundary that has already been checked.

    Separate from `encode_multipart` so that a test can pin the boundary and
    compare the whole body byte for byte. A random boundary makes that
    impossible, and a body nobody can write an exact expectation for is a body
    whose format drifts.
    """
    var out = Bytes()

    for i in range(len(data.names)):
        out.extend(_DASHES.as_bytes())
        out.extend(boundary.as_bytes())
        out.extend(_CRLF.as_bytes())
        out.extend('Content-Disposition: form-data; name="'.as_bytes())
        out.extend(escape_form_param(data.names[i]).as_span())
        out.extend('"'.as_bytes())
        out.extend(_CRLF.as_bytes())
        out.extend(_CRLF.as_bytes())
        out.extend(data.values[i].as_bytes())
        out.extend(_CRLF.as_bytes())

    for i in range(len(data.files)):
        ref file = data.files[i]
        out.extend(_DASHES.as_bytes())
        out.extend(boundary.as_bytes())
        out.extend(_CRLF.as_bytes())
        out.extend('Content-Disposition: form-data; name="'.as_bytes())
        out.extend(escape_form_param(file.field).as_span())
        out.extend('"'.as_bytes())
        # No `filename` parameter at all when there is no filename, rather than
        # an empty one. `filename=""` is what a browser sends for a file input
        # nobody chose a file for, and several frameworks read it as exactly
        # that, so writing it for a caller who deliberately sent bytes without a
        # name would lose the part.
        if file.filename != "":
            out.extend('; filename="'.as_bytes())
            out.extend(escape_form_param(file.filename).as_span())
            out.extend('"'.as_bytes())
        out.extend(_CRLF.as_bytes())
        out.extend("Content-Type: ".as_bytes())
        out.extend(file.resolved_type().as_bytes())
        out.extend(_CRLF.as_bytes())
        out.extend(_CRLF.as_bytes())
        out.extend(file.content.as_span())
        out.extend(_CRLF.as_bytes())

    out.extend(_DASHES.as_bytes())
    out.extend(boundary.as_bytes())
    out.extend(_DASHES.as_bytes())
    out.extend(_CRLF.as_bytes())
    return out^
