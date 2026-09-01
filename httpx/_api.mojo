"""The one line helpers.

`httpx.get(url)` builds a client, sends one request, closes the client and
returns the response. That is the whole of it, and it is the slow path on
purpose: every call pays a connect, a DNS lookup and later a TLS handshake,
because the pool it would have reused died with the client.

They exist anyway because the first thing anybody writes is one request, and a
library that made that awkward would be a library people stopped reading. The
docstrings say what to use instead as soon as there is a second request, which
is the same thing httpx does.
"""

from httpx._client import Client
from httpx._config import Timeout
from httpx._models.headers import Headers
from httpx._models.response import Response
from httpx._models.url import QueryParams


def request(
    method: StringSpan,
    url: StringSpan,
    *,
    var headers: Headers = Headers(),
    var content: List[UInt8] = List[UInt8](),
    var params: QueryParams = QueryParams(),
    timeout: Optional[Timeout] = None,
) raises -> Response:
    """Send one request through a client that lives for one request.

    Use `Client` for anything that sends more than one. The connection reuse it
    gives you is the difference between one round trip and three or four.
    """
    var client = Client()
    var response: Response
    try:
        response = client.request(
            method,
            url,
            headers=headers^,
            content=content^,
            params=params^,
            timeout=timeout,
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
    var params: QueryParams = QueryParams(),
    timeout: Optional[Timeout] = None,
) raises -> Response:
    """Send one request and return before the body has arrived.

    The client is closed before this returns, but the connection carrying the
    body is not in the pool to be closed, so the response keeps working and
    releases the connection itself when it is done or dropped. What that costs
    is the connection: there is no pool left to put it back into, so it is
    closed rather than reused. `Client.stream` is the one to use for anything
    that streams more than once.
    """
    var client = Client()
    var response: Response
    try:
        response = client.stream(
            method,
            url,
            headers=headers^,
            content=content^,
            params=params^,
            timeout=timeout,
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
    timeout: Optional[Timeout] = None,
) raises -> Response:
    return request(
        "GET", url, headers=headers^, params=params^, timeout=timeout
    )


def head(
    url: StringSpan,
    *,
    var headers: Headers = Headers(),
    var params: QueryParams = QueryParams(),
    timeout: Optional[Timeout] = None,
) raises -> Response:
    return request(
        "HEAD", url, headers=headers^, params=params^, timeout=timeout
    )


def options(
    url: StringSpan,
    *,
    var headers: Headers = Headers(),
    var params: QueryParams = QueryParams(),
    timeout: Optional[Timeout] = None,
) raises -> Response:
    return request(
        "OPTIONS", url, headers=headers^, params=params^, timeout=timeout
    )


def delete(
    url: StringSpan,
    *,
    var headers: Headers = Headers(),
    var params: QueryParams = QueryParams(),
    timeout: Optional[Timeout] = None,
) raises -> Response:
    return request(
        "DELETE", url, headers=headers^, params=params^, timeout=timeout
    )


def post(
    url: StringSpan,
    *,
    var content: List[UInt8] = List[UInt8](),
    var headers: Headers = Headers(),
    var params: QueryParams = QueryParams(),
    timeout: Optional[Timeout] = None,
) raises -> Response:
    return request(
        "POST",
        url,
        headers=headers^,
        content=content^,
        params=params^,
        timeout=timeout,
    )


def put(
    url: StringSpan,
    *,
    var content: List[UInt8] = List[UInt8](),
    var headers: Headers = Headers(),
    var params: QueryParams = QueryParams(),
    timeout: Optional[Timeout] = None,
) raises -> Response:
    return request(
        "PUT",
        url,
        headers=headers^,
        content=content^,
        params=params^,
        timeout=timeout,
    )


def patch(
    url: StringSpan,
    *,
    var content: List[UInt8] = List[UInt8](),
    var headers: Headers = Headers(),
    var params: QueryParams = QueryParams(),
    timeout: Optional[Timeout] = None,
) raises -> Response:
    return request(
        "PATCH",
        url,
        headers=headers^,
        content=content^,
        params=params^,
        timeout=timeout,
    )
