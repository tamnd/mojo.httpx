"""Parsing, normalizing and comparing the bytes each client sent.

Three things happen here and they are kept apart on purpose.

Parsing splits a recorded request into a request line, a list of headers in the
order they arrived, and the body. Nothing is decided at this stage.

Normalizing rewrites the parts that cannot be equal no matter how close the two
clients get. There are exactly two: the product token in `User-Agent`, and the
random tokens in a multipart boundary and a digest client nonce. Every rewrite
is listed in `NORMALIZED` with the reason, and nothing else is touched, because
a normalizer that quietly smoothed over a real difference would turn this suite
into a test that always passes.

Comparing produces one `Difference` per disagreement, each with an aspect naming
what disagreed. The driver matches those against a table of differences we have
decided to accept. Anything not in that table fails the run.
"""

import re

NORMALIZED = [
    (
        "user-agent",
        "The product token is the library's name and version, so it is"
        " different by definition.",
    ),
    (
        "multipart boundary",
        "Random per request on both sides. The length is compared instead, so a"
        " boundary of a different size still shows up as a Content-Length"
        " difference.",
    ),
    (
        "digest cnonce, nc and response",
        "A qop challenge makes the client pick a nonce, so the digest built"
        " from it cannot match. The no qop case has no client nonce and is"
        " compared byte for byte.",
    ),
]

_BOUNDARY = re.compile(rb"boundary=([0-9A-Za-z'()+_,./:=?-]+)")
_CNONCE = re.compile(rb'cnonce="[^"]*"')
_NC = re.compile(rb"\bnc=[0-9a-fA-F]+")
_DIGEST_RESPONSE = re.compile(rb'response="[0-9a-f]+"')


class Request:
    def __init__(self, line, headers, body):
        self.line = line
        self.headers = headers
        self.body = body

    def header(self, name):
        """Every value sent under this name, in order."""
        return [v for n, v in self.headers if n == name]

    def names(self):
        return [n for n, _ in self.headers]


class Difference:
    def __init__(self, case, aspect, ours, theirs):
        self.case = case
        self.aspect = aspect
        self.ours = ours
        self.theirs = theirs

    def __str__(self):
        return "%s / %s\n    mojo.httpx: %s\n    httpx2:     %s" % (
            self.case,
            self.aspect,
            _show(self.ours),
            _show(self.theirs),
        )


def _show(value):
    if isinstance(value, bytes):
        try:
            return repr(value.decode("utf-8"))
        except UnicodeDecodeError:
            return repr(value)
    return repr(value)


def parse(raw):
    head, _, body = raw.partition(b"\r\n\r\n")
    lines = head.split(b"\r\n")
    headers = []
    for line in lines[1:]:
        if b":" not in line:
            continue
        name, _, value = line.partition(b":")
        # The name is lowercased for matching and the value is left exactly as
        # it arrived. Casing of a header name carries no meaning and the two
        # libraries capitalize differently; casing of a value can carry a great
        # deal.
        headers.append((name.strip().lower().decode("latin-1"), value.strip()))
    return Request(lines[0], headers, body)


def normalize(request):
    """Rewrite the parts that cannot be equal, and nothing else."""
    headers = []
    boundary = None
    for name, value in request.headers:
        if name == "user-agent":
            value = b"<product>"
        elif name == "content-type":
            found = _BOUNDARY.search(value)
            if found:
                boundary = found.group(1)
                value = _BOUNDARY.sub(b"boundary=" + b"b" * len(boundary), value)
        elif name == "authorization" and value.lower().startswith(b"digest "):
            value = _CNONCE.sub(b'cnonce="<nonce>"', value)
            value = _NC.sub(b"nc=<count>", value)
            if b"cnonce=" in value:
                # Only when there is a client nonce. Without one the digest is
                # fully determined by the challenge and the credentials, and
                # that is the case worth comparing.
                value = _DIGEST_RESPONSE.sub(b'response="<digest>"', value)
        headers.append((name, value))

    body = request.body
    if boundary is not None:
        body = body.replace(boundary, b"b" * len(boundary))

    return Request(request.line, headers, body)


def compare(case, ours, theirs):
    """Every way the two requests disagree, one `Difference` at a time."""
    out = []
    ours = normalize(parse(ours))
    theirs = normalize(parse(theirs))

    if ours.line != theirs.line:
        out.append(Difference(case, "request-line", ours.line, theirs.line))

    ours_names = set(ours.names())
    theirs_names = set(theirs.names())
    for name in sorted(ours_names | theirs_names):
        mine = ours.header(name)
        yours = theirs.header(name)
        if mine == yours:
            continue
        # Joined rather than reported as a list, because a header sent twice is
        # two lines on the wire and reading them side by side is the point.
        out.append(
            Difference(
                case,
                "header:" + name,
                b"; ".join(mine) if mine else "not sent",
                b"; ".join(yours) if yours else "not sent",
            )
        )

    # Ordering is checked over the names both sides sent, so a header only one
    # of them sends cannot make the order look different on its own. That
    # difference is already reported above and reporting it twice would hide the
    # real ordering disagreements.
    shared = ours_names & theirs_names
    mine = [n for n in ours.names() if n in shared]
    yours = [n for n in theirs.names() if n in shared]
    if mine != yours:
        out.append(
            Difference(case, "header-order", ", ".join(mine), ", ".join(yours))
        )

    if ours.body != theirs.body:
        out.append(Difference(case, "body", ours.body, theirs.body))

    return out
