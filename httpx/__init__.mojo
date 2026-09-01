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
    basic_auth,
    digest_auth,
    erase_auth,
    netrc_auth,
)
from httpx._client import Client
from httpx._config import Timeout
from httpx._content.multipart import FileUpload, MultipartData
from httpx._exceptions import ErrorKind
from httpx._models.cookies import Cookie, CookieJar, Cookies, SameSite
from httpx._models.headers import Headers
from httpx._models.iterators import ByteChunks, LineChunks, TextChunks
from httpx._models.json import Json, JsonValue, parse_json
from httpx._models.request import Request
from httpx._models.response import Response
from httpx._models.stream import ByteSource, ByteStream, erase_source
from httpx._models.url import URL, QueryParams
from httpx._pool.limits import Limits
from httpx._stream.config import ClientCert, SSLVerify
from httpx._util.charset import DefaultEncoding

comptime __version__ = "0.0.1"

comptime MOJO_MIN_VERSION = "1.0.0"
"""The oldest Mojo toolchain this release is tested against."""
