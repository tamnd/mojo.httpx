# QuickStart

This is the twenty minute tour. It follows httpx2's quickstart page, so if you have read that one you are re-reading it in Mojo, and the differences are the interesting part.

Every example here is a whole program. Save it and run it with `mojo run -I /path/to/mojo.httpx example.mojo`. [Installation](install.md) covers the path, and [Mojo notes](mojo.md) covers the four or five language facts behind why the code reads the way it does.

## Sending a request

```mojo
import httpx


def main() raises:
    var r = httpx.get("https://example.com/")
    print(r.status_code)
```

There is one helper per method: `get`, `head`, `options`, `delete`, `post`, `put` and `patch`, plus `request` for a method you name yourself and `stream` for a body you read as it arrives.

```mojo
import httpx


def main() raises:
    var deleted = httpx.delete("https://httpbin.org/delete")
    var checked = httpx.head("https://httpbin.org/get")
    var asked = httpx.options("https://httpbin.org/get")
    var named = httpx.request("REPORT", "https://example.com/")
    print(deleted.status_code, checked.status_code)
    print(asked.status_code, named.status_code)
```

Each of these builds a client, sends one request and closes the client again. That is fine for one request and wasteful for two, because the connection goes away with the client. As soon as there is a second request, [use a `Client`](#clients).

## Reading the response

```mojo
import httpx


def main() raises:
    var r = httpx.get("https://example.com/")

    print(r.status_code)
    print(r.reason_phrase)
    print(r.text())
    print(r.encoding())
    print(len(r.content()))
```

`r.text()` decodes the body using the charset the response named. When it named none, or named one nothing here can decode, `default_encoding` decides, and that is UTF-8 unless you changed it. `r.content()` is the raw bytes, as a `List[UInt8]`.

`r.text()` never raises on the bytes themselves. An undecodable sequence becomes U+FFFD, one per maximal subpart, which is what Python's `errors="replace"` produces and therefore what httpx2 hands back for the same body.

## JSON

```mojo
import httpx


def main() raises:
    var r = httpx.get("https://api.github.com/repos/modular/modular")
    var body = r.json()

    print(body["full_name"].as_string())
    print(body["stargazers_count"].as_int())
    print(body["owner"]["login"].as_string())
```

This is the first real difference from httpx2. There, `r.json()` gives back whatever Python object the document happened to be and you find out what it is by using it. Mojo has no dynamic `Any`, so `r.json()` gives back a typed `Json` value, and the type check happens where you read a leaf: `as_string`, `as_int`, `as_float`, `as_bool`. Asking for the wrong one raises rather than handing you a plausible wrong answer.

Indexing works for objects and arrays, and missing keys raise rather than returning null.

```mojo
import httpx


def main() raises:
    var r = httpx.get("https://api.github.com/users/modular/repos")
    var repos = r.json()

    print(len(repos))
    for i in range(len(repos)):
        print(repos[i]["name"].as_string())
```

Ask before you assume, when the shape is not guaranteed.

```mojo
import httpx


def main() raises:
    var r = httpx.get("https://httpbin.org/get")
    var body = r.json()

    if "headers" in body:
        print(body["headers"]["Host"].as_string())

    if body["url"].is_string():
        print(body["url"].as_string())
```

[JSON](json.md) covers building a document, the parser's limits, and why the tree is an arena of nodes rather than a struct that holds itself.

## Query parameters

```mojo
import httpx
from httpx import QueryParams


def main() raises:
    var params = QueryParams().add("q", "mojo").add("page", "2")
    var r = httpx.get("https://httpbin.org/get", params=params^)
    print(r.url())
```

`QueryParams` keeps order and allows a name more than once, because both of those matter to real APIs. `add` appends, `set` replaces every entry with that name, and each returns a new value so they chain. Parameters written into the URL string and parameters passed with `params=` are merged, with the passed ones added rather than replacing.

## Headers

```mojo
import httpx
from httpx import Headers


def main() raises:
    var headers = Headers()
    headers["Accept"] = "application/json"
    headers["User-Agent"] = "my-app/1.0"

    var r = httpx.get("https://httpbin.org/get", headers=headers^)
    print(r.headers["content-type"])
    print(r.headers.get("x-missing", "not there"))
```

Header names are case insensitive on the way in and on the way out. `headers["set-cookie"]` gives the first value, and `headers.get_list("set-cookie")` gives all of them, which matters for exactly the headers that are allowed to repeat.

Printing a `Headers`, a `Request` or a `Response` redacts `Authorization`, `Proxy-Authorization`, `Cookie` and `Set-Cookie`, showing `[secret, 28 bytes]` in place of the value, so a debug print cannot leak a password into a log. Asking for the value by name still gives you the value.

## Sending a body

There are six ways to put a body on a request, and each one carries the content type that describes it.

```mojo
import httpx
from httpx import URL, FileUpload, Json, MultipartData, QueryParams


def main() raises:
    with httpx.Client(base_url=URL("https://httpbin.org")) as client:
        # Raw text, sent exactly as written.
        var raw = client.post("/post", text="hello")

        # A urlencoded form.
        var form = QueryParams().add("name", "mojo").add("kind", "language")
        var posted = client.post("/post", data=form^)

        # A JSON document.
        var doc = Json.object()
        doc.set("name", Json("widget"))
        doc.set("count", Json(3))
        var sent = client.post("/post", json=doc^)

        # A multipart upload, with fields alongside the files.
        var files = MultipartData()
        files.add("caption", "on holiday")
        files.add_file(FileUpload("photo", "beach.jpg", "the jpeg bytes"))
        var uploaded = client.post("/post", files=files^)

        print(raw.status_code, posted.status_code)
        print(sent.status_code, uploaded.status_code)
```

The two remaining ones are `content=` for bytes you already have and `content_stream=` for a body pulled as it is written. httpx2 folds those two into a single `content=` and tells them apart at runtime, which Mojo cannot do, so they are separate arguments.

Passing two bodies raises and names both, rather than silently dropping one. The one combination that is allowed is `data=` with `files=`, which is not two bodies but one multipart body carrying the fields and the files, exactly as a browser sends it. [Request bodies](content.md) covers all six and the content type rules.

## Status codes and errors

```mojo
import httpx


def main() raises:
    var r = httpx.get("https://httpbin.org/status/404")
    print(r.status_code)
    print(r.is_success(), r.is_client_error(), r.is_server_error())
```

A 4xx or a 5xx is not an error by itself. Ask for one with `raise_for_status`.

```mojo
import httpx


def main() raises:
    var r = httpx.get("https://httpbin.org/status/500")
    try:
        r.raise_for_status()
    except e:
        print(String(e))
```

`raise_for_status` returns nothing here, so it goes on its own line rather than being chained as `r.raise_for_status().json()`. A `Response` is not copyable, so a method that gave one back would have to consume the receiver and `r` would be gone afterwards.

Everything the library raises for a request is one `Error`, because Mojo has one error type and no exception subclassing. httpx2's class hierarchy is reproduced as a set of predicates you ask instead of types you catch.

```mojo
import httpx


def main() raises:
    var budget = httpx.Timeout.uniform(2.0)
    try:
        var r = httpx.get("https://example.com/", timeout=budget)
        print(r.status_code)
    except e:
        if httpx.is_timeout(e):
            print("too slow")
        elif httpx.is_connect_error(e):
            print("could not get there")
        elif httpx.is_status_error(e):
            print("the server said no:", httpx.kind_of(e).name())
        else:
            raise e
```

The predicates nest the way the classes do. `is_timeout` is true for all four timeouts, `is_transport_error` is true for every network layer failure, and `is_http_error` is true for anything raised for a request. `kind_of(e).name()` gives back the httpx2 class name, so a log line reads the same in both libraries.

## Redirects

A redirect is not followed unless you ask, which is httpx2's default and the right one. A client that follows silently is a client that can be sent somewhere else without the caller ever knowing.

```mojo
import httpx


def main() raises:
    var r = httpx.get("https://httpbin.org/redirect/2", follow_redirects=True)
    print(r.status_code, r.url())

    var history = r.history()
    for i in range(len(history)):
        print(history[i].status_code, history[i].url())
```

Left off, a 3xx comes back as it is and `r.next_request()` holds the request that would have been sent, which is how you inspect or rewrite a hop before taking it. `Authorization` is dropped when a hop crosses an origin, so no server can talk this client into handing your credentials to an address you never named.

## Timeouts

Every request has a timeout, and the default is five seconds on each phase. There is no way to switch it off by accident.

```mojo
import httpx
from httpx import Timeout


def main() raises:
    # One number for every phase.
    var quick = httpx.get("https://example.com/", timeout=Timeout.uniform(2.0))

    # Or a different number per phase, because they fail for different reasons.
    var careful = Timeout(
        connect_seconds=3.0,
        read_seconds=30.0,
        write_seconds=10.0,
        pool_seconds=5.0,
    )
    var slow = httpx.get("https://example.com/big", timeout=careful)
    print(quick.status_code, slow.status_code)
```

The four are separate because they mean different things. A connect timeout is the server being unreachable, a read timeout is the server going quiet mid answer, a write timeout is a body that cannot be pushed, and a pool timeout is your own program asking for more connections than it allowed itself. Every one of them is a deadline that is checked all the way down to the socket call rather than a wrapper around the whole request.

## Streaming

A body too large to want in memory, or one that does not end, is read with `stream`.

```mojo
import httpx


def main() raises:
    with httpx.Client() as client:
        with client.stream("GET", "https://example.com/big.log") as r:
            print(r.status_code)
            var lines = r.iter_lines()
            while lines.has_next():
                print(lines.next())
```

`stream` returns as soon as the head has arrived, and the body comes off the wire a chunk at a time. The four iterators are `iter_bytes`, `iter_text`, `iter_lines` and `iter_raw`, the last of which hands over the bytes exactly as they arrived, still compressed if they were compressed.

Two things about that code are not decoration. The `with` around the response is what gives the connection back: it goes into the pool when the body ends and is closed if the block is left early, and both happen because the response was destroyed at the end of the block. And the loop is `has_next` and `next` rather than `for`, because Mojo 1.0 drops an error raised out of `__next__`, which would turn a connection dying halfway through a download into a body that looks complete and is not. [Compatibility guide](deviations.md) has that argument in full.

## Clients

Everything above works on `Client` too, and on a client the connection stays open between requests.

```mojo
import httpx
from httpx import URL, Headers, Timeout


def main() raises:
    var headers = Headers()
    headers["Authorization"] = "Bearer hunter2"

    with httpx.Client(
        base_url=URL("https://api.example.com"),
        headers=headers^,
        timeout=Timeout.uniform(30.0),
        follow_redirects=True,
    ) as client:
        var listing = client.get("/items")
        var one = client.get("/items/1")
        print(listing.status_code, one.status_code)
```

Both of those requests go over one connection. A `Client` also carries a cookie jar, so a login and the request after it are a session rather than two unrelated calls, and it carries the defaults every request inherits: the base URL, the headers, the timeout, the auth, the redirect policy and the encoding.

The `with` matters here for the same reason it does on a streamed response. Leaving the block closes the pool. If you cannot use a `with`, call `client.close()` yourself.

`AsyncClient` is the same client over a pool that does not hold a runtime worker while a request waits on a socket, and it is spelled the same way because it is the same code with a different transport in it. [Async support](async.md) covers it.

## Where to go next

[Advanced usage](advanced.md) is the next page: authentication, event hooks, custom transports, mocking, proxies and connection limits. [Compatibility guide](deviations.md) is the page to read if something behaves differently from what httpx2 taught you to expect, because it is probably in there with the reason next to it.
