"""The one line helpers.

`httpx.get(url)` builds a client, sends one request, closes the client and
returns the response. That is the whole of it, and it is the slow path on
purpose: every call pays a connect, a DNS lookup and later a TLS handshake,
because the pool it would have reused died with the client.

They exist anyway because the first thing anybody writes is one request, and a
library that made that awkward would be a library people stopped reading. The
docstrings say what to use instead as soon as there is a second request, which
is the same thing httpx does.

Each of them takes the arguments that describe one request and the three that
describe the connection it goes out on, `verify`, `cert` and `trust_env`. The
connection ones are here because the client these build is not reachable from
outside, so without them a caller talking to a private CA would have to abandon
the one line form on their very first request. Everything else that lives on a
`Client`, the pool limits, the event hooks, the redirect ceiling, describes
behaviour across requests and there is only ever one request here.
"""

from httpx._auth import AnyAuth
from httpx._client import Client
from httpx._config import Timeout
from httpx._content.multipart import MultipartData
from httpx._models.cookies import Cookies
from httpx._models.headers import Headers
from httpx._models.json import Json
from httpx._models.response import Response
from httpx._models.stream import ByteStream
from httpx._models.url import QueryParams
from httpx._stream.config import ClientCert, SSLVerify


def request(
    method: StringSpan,
    url: StringSpan,
    *,
    var headers: Headers = Headers(),
    var content: List[UInt8] = List[UInt8](),
    text: StringSpan = "",
    var data: QueryParams = QueryParams(),
    var files: MultipartData = MultipartData(),
    var json: Optional[Json] = None,
    var content_stream: Optional[ByteStream] = None,
    var params: QueryParams = QueryParams(),
    var cookies: Cookies = Cookies(),
    timeout: Optional[Timeout] = None,
    follow_redirects: Bool = False,
    var auth: Optional[AnyAuth] = None,
    verify: SSLVerify = SSLVerify(),
    cert: Optional[ClientCert] = None,
    trust_env: Bool = True,
) raises -> Response:
    """Send one request through a client that lives for one request.

    Use `Client` for anything that sends more than one. The connection reuse it
    gives you is the difference between one round trip and three or four.
    """
    var client = Client(verify=verify, cert=cert, trust_env=trust_env)
    var response: Response
    try:
        response = client.request(
            method,
            url,
            headers=headers^,
            content=content^,
            text=text,
            data=data^,
            files=files^,
            json=json^,
            content_stream=content_stream^,
            params=params^,
            cookies=cookies^,
            timeout=timeout,
            follow_redirects=follow_redirects,
            auth=auth^,
        )
    except e:
        # The pool has to be closed on the way out as well, or a failed one shot
        # call leaks a socket for as long as the process runs.
        client.close()
        raise e
    client.close()
    return response^


def stream(
    method: StringSpan,
    url: StringSpan,
    *,
    var headers: Headers = Headers(),
    var content: List[UInt8] = List[UInt8](),
    text: StringSpan = "",
    var data: QueryParams = QueryParams(),
    var files: MultipartData = MultipartData(),
    var json: Optional[Json] = None,
    var content_stream: Optional[ByteStream] = None,
    var params: QueryParams = QueryParams(),
    var cookies: Cookies = Cookies(),
    timeout: Optional[Timeout] = None,
    follow_redirects: Bool = False,
    var auth: Optional[AnyAuth] = None,
    verify: SSLVerify = SSLVerify(),
    cert: Optional[ClientCert] = None,
    trust_env: Bool = True,
) raises -> Response:
    """Send one request and return before the body has arrived.

    The client is closed before this returns, but the connection carrying the
    body is not in the pool to be closed, so the response keeps working and
    releases the connection itself when it is done or dropped. What that costs
    is the connection: there is no pool left to put it back into, so it is
    closed rather than reused. `Client.stream` is the one to use for anything
    that streams more than once.
    """
    var client = Client(verify=verify, cert=cert, trust_env=trust_env)
    var response: Response
    try:
        response = client.stream(
            method,
            url,
            headers=headers^,
            content=content^,
            text=text,
            data=data^,
            files=files^,
            json=json^,
            content_stream=content_stream^,
            params=params^,
            cookies=cookies^,
            timeout=timeout,
            follow_redirects=follow_redirects,
            auth=auth^,
        )
    except e:
        client.close()
        raise e
    client.close()
    return response^


def get(
    url: StringSpan,
    *,
    var headers: Headers = Headers(),
    var params: QueryParams = QueryParams(),
    var cookies: Cookies = Cookies(),
    timeout: Optional[Timeout] = None,
    follow_redirects: Bool = False,
    var auth: Optional[AnyAuth] = None,
    verify: SSLVerify = SSLVerify(),
    cert: Optional[ClientCert] = None,
    trust_env: Bool = True,
) raises -> Response:
    """One `GET`, through a client that is built and closed around it.

    No body argument, because RFC 9110 gives a body on `GET` no defined
    semantics and httpx2 leaves it out of the signature for the same reason. A
    caller who genuinely needs one can reach for `request`.
    """
    return request(
        "GET",
        url,
        headers=headers^,
        params=params^,
        cookies=cookies^,
        timeout=timeout,
        follow_redirects=follow_redirects,
        auth=auth^,
        verify=verify,
        cert=cert,
        trust_env=trust_env,
    )


def head(
    url: StringSpan,
    *,
    var headers: Headers = Headers(),
    var params: QueryParams = QueryParams(),
    var cookies: Cookies = Cookies(),
    timeout: Optional[Timeout] = None,
    follow_redirects: Bool = False,
    var auth: Optional[AnyAuth] = None,
    verify: SSLVerify = SSLVerify(),
    cert: Optional[ClientCert] = None,
    trust_env: Bool = True,
) raises -> Response:
    """One `HEAD`. The same as `get` with the body left off by the server.

    Worth reaching for when all you want is the status, the length or the
    caching headers, since the server sends none of the body and the response
    still carries everything else.
    """
    return request(
        "HEAD",
        url,
        headers=headers^,
        params=params^,
        cookies=cookies^,
        timeout=timeout,
        follow_redirects=follow_redirects,
        auth=auth^,
        verify=verify,
        cert=cert,
        trust_env=trust_env,
    )


def options(
    url: StringSpan,
    *,
    var headers: Headers = Headers(),
    var params: QueryParams = QueryParams(),
    var cookies: Cookies = Cookies(),
    timeout: Optional[Timeout] = None,
    follow_redirects: Bool = False,
    var auth: Optional[AnyAuth] = None,
    verify: SSLVerify = SSLVerify(),
    cert: Optional[ClientCert] = None,
    trust_env: Bool = True,
) raises -> Response:
    """One `OPTIONS`, for asking a server what it will accept.

    No body argument, for the same reason `get` has none.
    """
    return request(
        "OPTIONS",
        url,
        headers=headers^,
        params=params^,
        cookies=cookies^,
        timeout=timeout,
        follow_redirects=follow_redirects,
        auth=auth^,
        verify=verify,
        cert=cert,
        trust_env=trust_env,
    )


def delete(
    url: StringSpan,
    *,
    var headers: Headers = Headers(),
    var params: QueryParams = QueryParams(),
    var cookies: Cookies = Cookies(),
    timeout: Optional[Timeout] = None,
    follow_redirects: Bool = False,
    var auth: Optional[AnyAuth] = None,
    verify: SSLVerify = SSLVerify(),
    cert: Optional[ClientCert] = None,
    trust_env: Bool = True,
) raises -> Response:
    """One `DELETE`.

    No body argument, because a body on a `DELETE` has no defined meaning and
    httpx2 leaves it out of the signature too. `request("DELETE", ...)` is there
    for a server that wants one anyway.
    """
    return request(
        "DELETE",
        url,
        headers=headers^,
        params=params^,
        cookies=cookies^,
        timeout=timeout,
        follow_redirects=follow_redirects,
        auth=auth^,
        verify=verify,
        cert=cert,
        trust_env=trust_env,
    )


def post(
    url: StringSpan,
    *,
    var content: List[UInt8] = List[UInt8](),
    text: StringSpan = "",
    var data: QueryParams = QueryParams(),
    var files: MultipartData = MultipartData(),
    var json: Optional[Json] = None,
    var content_stream: Optional[ByteStream] = None,
    var headers: Headers = Headers(),
    var params: QueryParams = QueryParams(),
    var cookies: Cookies = Cookies(),
    timeout: Optional[Timeout] = None,
    follow_redirects: Bool = False,
    var auth: Optional[AnyAuth] = None,
    verify: SSLVerify = SSLVerify(),
    cert: Optional[ClientCert] = None,
    trust_env: Bool = True,
) raises -> Response:
    """One `POST`. The six body arguments are the ones `Client.post` takes."""
    return request(
        "POST",
        url,
        headers=headers^,
        content=content^,
        text=text,
        data=data^,
        files=files^,
        json=json^,
        content_stream=content_stream^,
        params=params^,
        cookies=cookies^,
        timeout=timeout,
        follow_redirects=follow_redirects,
        auth=auth^,
        verify=verify,
        cert=cert,
        trust_env=trust_env,
    )


def put(
    url: StringSpan,
    *,
    var content: List[UInt8] = List[UInt8](),
    text: StringSpan = "",
    var data: QueryParams = QueryParams(),
    var files: MultipartData = MultipartData(),
    var json: Optional[Json] = None,
    var content_stream: Optional[ByteStream] = None,
    var headers: Headers = Headers(),
    var params: QueryParams = QueryParams(),
    var cookies: Cookies = Cookies(),
    timeout: Optional[Timeout] = None,
    follow_redirects: Bool = False,
    var auth: Optional[AnyAuth] = None,
    verify: SSLVerify = SSLVerify(),
    cert: Optional[ClientCert] = None,
    trust_env: Bool = True,
) raises -> Response:
    """One `PUT`. The six body arguments are the ones `Client.put` takes."""
    return request(
        "PUT",
        url,
        headers=headers^,
        content=content^,
        text=text,
        data=data^,
        files=files^,
        json=json^,
        content_stream=content_stream^,
        params=params^,
        cookies=cookies^,
        timeout=timeout,
        follow_redirects=follow_redirects,
        auth=auth^,
        verify=verify,
        cert=cert,
        trust_env=trust_env,
    )


def patch(
    url: StringSpan,
    *,
    var content: List[UInt8] = List[UInt8](),
    text: StringSpan = "",
    var data: QueryParams = QueryParams(),
    var files: MultipartData = MultipartData(),
    var json: Optional[Json] = None,
    var content_stream: Optional[ByteStream] = None,
    var headers: Headers = Headers(),
    var params: QueryParams = QueryParams(),
    var cookies: Cookies = Cookies(),
    timeout: Optional[Timeout] = None,
    follow_redirects: Bool = False,
    var auth: Optional[AnyAuth] = None,
    verify: SSLVerify = SSLVerify(),
    cert: Optional[ClientCert] = None,
    trust_env: Bool = True,
) raises -> Response:
    """One `PATCH`. The six body arguments are the ones `Client.patch` takes."""
    return request(
        "PATCH",
        url,
        headers=headers^,
        content=content^,
        text=text,
        data=data^,
        files=files^,
        json=json^,
        content_stream=content_stream^,
        params=params^,
        cookies=cookies^,
        timeout=timeout,
        follow_redirects=follow_redirects,
        auth=auth^,
        verify=verify,
        cert=cert,
        trust_env=trust_env,
    )
