"""Working out the request that follows a redirect.

Following a redirect is not a matter of sending the same request to a new
address. The method can change, the body can be dropped, and some of the
headers must not travel, and every one of those rules exists because getting it
wrong has hurt somebody. `Authorization` carried across an origin hands the
caller's credentials to whatever host the first server names, and a `Cookie`
computed for one URL is not the cookie for another. So the rules are here, in
one place, written out rather than implied.

They are httpx's rules, which are in turn the rules browsers settled on rather
than the ones RFC 9110 describes. The RFC says a 301 or a 302 should preserve
the method and only 303 should rewrite it. Nobody does that, because two
decades of servers were written against clients that rewrite, and a client that
followed the specification here would fail against real sites. The 307 and 308
codes exist precisely because the older ones cannot be trusted to preserve a
method, and those two are preserved.

Nothing in this file sends anything or looks at a response object. It takes the
request that went out, the status code that came back and the `Location` that
came with it, and produces the next request. That makes every rule testable
without a server and keeps the decision separate from the loop that acts on it.
"""

from httpx._exceptions import ErrorKind, message_of, new_error
from httpx._models.headers import Headers
from httpx._models.request import Request
from httpx._models.url import URL
from httpx._pool.origin import origin_for

comptime _COLON = UInt8(ord(":"))
comptime _SLASH = UInt8(ord("/"))
comptime _QUESTION = UInt8(ord("?"))
comptime _HASH = UInt8(ord("#"))


def _is_alpha(byte: UInt8) -> Bool:
    return (byte >= UInt8(ord("a")) and byte <= UInt8(ord("z"))) or (
        byte >= UInt8(ord("A")) and byte <= UInt8(ord("Z"))
    )


def _is_scheme_byte(byte: UInt8) -> Bool:
    if _is_alpha(byte):
        return True
    if byte >= UInt8(ord("0")) and byte <= UInt8(ord("9")):
        return True
    return (
        byte == UInt8(ord("+"))
        or byte == UInt8(ord("-"))
        or byte == UInt8(ord("."))
    )


comptime DEFAULT_MAX_REDIRECTS = 20
"""How many hops before giving up, matching httpx.

A bound rather than a cycle detector. A server can redirect in a loop that never
repeats a URL, so counting is the only check that always terminates, and twenty
is far more than any working site needs.
"""


def redirect_method(method: StringSpan, status_code: Int) raises -> String:
    """The method the next request should use.

    303 means "go look over there instead", so anything but a HEAD becomes a
    GET. 302 and 301 are rewritten too, which the RFC does not ask for and every
    browser does. 307 and 308 are not in this list at all, which is the whole
    reason they were registered.
    """
    var out = String(method)
    if status_code == 303 and out != "HEAD":
        out = String("GET")
    # QUERY is spared because it is a read with a body, so rewriting it to GET
    # would throw away the request rather than repeat it.
    if status_code == 302 and out != "HEAD" and out != "QUERY":
        out = String("GET")
    if status_code == 301 and out == "POST":
        out = String("GET")
    return out^


def _empty_authority_at(location: StringSpan) -> Optional[Int]:
    """Where a host belongs, for a `Location` that names a scheme and stops.

    `https://` and `https:///a` are both malformed and both sent by real
    servers, and what they mean is the same host over the scheme they named.
    The answer is the offset the host goes at, or nothing at all when this is an
    ordinary URL that names a host of its own.
    """
    var bytes = location.as_bytes()
    var at = 0
    while at < len(bytes) and bytes[at] != _COLON:
        at += 1
    if at == 0 or at + 2 >= len(bytes):
        return None
    if bytes[at + 1] != _SLASH or bytes[at + 2] != _SLASH:
        return None

    # Everything before the colon has to be a scheme, or this is a path that
    # happens to contain `://` and there is no authority here to fill in.
    if not _is_alpha(bytes[0]):
        return None
    for i in range(1, at):
        if not _is_scheme_byte(bytes[i]):
            return None

    var host_at = at + 3
    if host_at == len(bytes):
        return host_at
    var first = bytes[host_at]
    if first == _SLASH or first == _QUESTION or first == _HASH:
        return host_at
    return None


def redirect_url(request_url: URL, location: StringSpan) raises -> URL:
    """The URL to go to, resolved against the one we asked for.

    A `Location` is allowed to be relative and very often is, so the resolution
    is RFC 3986's and not string concatenation. The two odd cases either side of
    it are both things real servers send: a `Location` with a scheme and no host
    at all, and one that drops a fragment the original URL had.
    """
    var text = String(location)

    # The host goes in before the parse rather than being patched in after,
    # because a URL with no host is not one this library will build, so there is
    # no parsed form of `https://` to patch.
    var host_at = _empty_authority_at(location)
    if host_at:
        var at = host_at.value()
        var spliced = String(
            text[byte=0:at],
            StringSpan(from_utf8=request_url.raw_host()),
            text[byte=at:],
        )
        text = spliced^

    var url: URL
    try:
        url = URL(text)
    except e:
        raise new_error(
            ErrorKind.REMOTE_PROTOCOL_ERROR,
            String("Invalid URL in location header: ", message_of(e), "."),
        )

    if url.is_relative_url():
        url = request_url.join(location)

    # A fragment is never sent to a server, so a redirect cannot know about the
    # one the caller asked for. Carrying it forward is what keeps a link to
    # `#section` still pointing at that section after a hop.
    if request_url.fragment() != "" and url.fragment() == "":
        url = url.copy_with(fragment=request_url.fragment())
    return url^


def is_https_redirect(url: URL, location: URL) raises -> Bool:
    """Whether this hop is the same site upgrading itself to TLS.

    The one cross origin hop that may keep the `Authorization` header. Sending
    credentials from `http://example.com` to `https://example.com` gives them to
    the host that already had them, over a better connection than the one they
    arrived on, so stripping them there would break the redirect every site with
    an HTTPS upgrade relies on and protect nobody.
    """
    if url.host() != location.host():
        return False
    var from_port = url.effective_port()
    var to_port = location.effective_port()
    if not from_port or not to_port:
        return False
    if url.scheme() != "http" or from_port.value() != 80:
        return False
    return location.scheme() == "https" and to_port.value() == 443


def redirect_headers(
    request: Request, url: URL, method: StringSpan
) raises -> Headers:
    """The headers to send on the next hop, with what must not travel removed.

    Three separate rules, and the first is the one that matters. Credentials are
    scoped to the origin they were meant for, and a server that redirects
    elsewhere must not be able to make a client hand them over. The other two
    are housekeeping: framing that describes a body that is no longer being
    sent, and a `Cookie` that was computed for a URL we are no longer asking
    for.
    """
    var out = request.headers.copy()

    if origin_for(url) != origin_for(request.url):
        if not is_https_redirect(request.url, url):
            _ = out.discard("Authorization")
        # httpx rewrites `Host` here. This drops it instead, which comes out the
        # same on the wire: the head is serialized with a `Host` taken from the
        # URL whenever the request does not carry one of its own, so removing
        # the stale one is enough and leaves one rule about where `Host` comes
        # from rather than two.
        _ = out.discard("Host")

    if method != request.method:
        # Only ever a rewrite to GET, and a GET does not carry the body these
        # describe. Leaving them would tell the server to wait for a body that
        # is never coming.
        _ = out.discard("Content-Length")
        _ = out.discard("Transfer-Encoding")

    # Always, even on a same origin hop. The cookie jar sets this from the URL
    # being requested, so a header computed for the old URL is stale whether or
    # not the origin changed.
    _ = out.discard("Cookie")
    return out^


def build_redirect_request(
    mut request: Request, status_code: Int, location: StringSpan
) raises -> Request:
    """The request that follows `request`, given what came back.

    `request` is borrowed mutably because a body that is being streamed can only
    be handed on, not copied, and handing it on is a move. A body that has
    already gone out that way cannot be sent again at all, and `take_stream`
    says so with the error that explains what to do instead.
    """
    var method = redirect_method(request.method, status_code)
    var url = redirect_url(request.url, location)
    var headers = redirect_headers(request, url, method)

    if method != request.method:
        # Rewritten to GET, so the body is dropped along with the framing that
        # described it. A body resent as a GET would be a body the server has no
        # way to read.
        return Request(method, url^, headers^)

    if request.has_stream() or request.body_was_taken():
        return Request.streaming(method, url^, request.take_stream(), headers^)

    return Request(method, url^, headers^, request.content.copy())
