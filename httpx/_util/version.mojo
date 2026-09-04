"""The release version, in the one place that owns it.

It was in two: `__version__` in the package root and the `User-Agent` string in
the client. Nothing connected them, so the first release to bump one and forget
the other would have shipped a client announcing a version it was not. Both now
read from here, and a release is one edit plus the matching one in `pixi.toml`.

Down in `_util` because the client is at layer 10 and the package root at layer
12, so the only place both can import from is the bottom.
"""

comptime VERSION = "0.0.1"
"""The library version, as `major.minor.patch`."""

comptime USER_AGENT = "mojo-httpx/" + VERSION
"""What goes out as `User-Agent` when the caller set none.

Named after the package rather than after httpx, because a server operator
reading a log should be able to tell which client actually made the request.
"""
