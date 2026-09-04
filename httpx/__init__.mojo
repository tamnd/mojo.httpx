"""A full featured HTTP client for Mojo, with the same API as httpx2.

```mojo
import httpx

var r = httpx.get("http://example.com")
print(r.status_code, r.text())
```

Everything a user needs is re-exported here, so `import httpx` is the only
import in ordinary code and the underscore modules underneath are free to move.
A name that is not in this file is not public, whatever it is spelled like.

The library is pre-alpha. Nothing here is stable and most of it does not exist
yet. See docs/roadmap.md for what lands when.
"""

from httpx._aio_client import AsyncClient, gather
from httpx._api import (
    delete,
    get,
    head,
    options,
    patch,
    post,
    put,
    request,
    stream,
)
from httpx._auth import (
    AnyAuth,
    Auth,
    BasicAuth,
    DigestAuth,
    NetRCAuth,
    NoAuth,
    basic_auth,
    digest_auth,
    erase_auth,
    netrc_auth,
    no_auth,
)
from httpx._client import Client
from httpx._config import Timeout
from httpx._content.multipart import FileUpload, MultipartData
from httpx._exceptions import ErrorKind
from httpx._hooks import (
    AnyRequestHook,
    AnyResponseHook,
    EventHooks,
    RequestHook,
    ResponseHook,
    erase_request_hook,
    erase_response_hook,
)
from httpx._models.cookies import Cookie, CookieJar, Cookies, SameSite
from httpx._models.headers import Headers
from httpx._models.iterators import ByteChunks, LineChunks, TextChunks
from httpx._models.json import Json, JsonValue, parse_json
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._models.stream import ByteSource, ByteStream, erase_source
from httpx._models.url import URL, QueryParams
from httpx._pool.limits import Limits
from httpx._pool.proxy import Proxy, proxy_basic_auth
from httpx._stream.config import ClientCert, SSLVerify
from httpx._transport.aio_base import (
    AnyAsyncTransport,
    AsyncTransport,
    erase_async_transport,
)
from httpx._transport.aio_http import AsyncHTTPTransport
from httpx._transport.base import AnyTransport, Transport, erase_transport
from httpx._transport.http import HTTPTransport
from httpx._transport.blocked import (
    BlockedTransport,
    async_blocked,
    blocked,
)
from httpx._transport.mock import MockRouter, MockTransport, Route
from httpx._transport.mounts import Mounts as MountTable
from httpx._transport.mounts import URLPattern
from httpx._util.charset import DefaultEncoding
from httpx._util.duration import Duration
from httpx._util.links import Link, parse_links

comptime Mounts = MountTable[AnyTransport]
"""The routing table a `Client` takes, built up a mount at a time.

```mojo
var routes = Mounts()
routes.mount("all://internal.example.com", erase_transport(HTTPTransport()))
routes.mount("http://", blocked())
```

A named type rather than a dictionary literal because Mojo has no literal that
holds a transport, and because the entries have to be parsed and ordered, which
is work that has to happen somewhere and is better done as each one is added
than at the first request.
"""

comptime AsyncMounts = MountTable[AnyAsyncTransport]
"""The same for an `AsyncClient`, holding async transports."""

comptime __version__ = "0.0.1"

comptime MOJO_MIN_VERSION = "1.0.0"
"""The oldest Mojo toolchain this release is tested against."""
