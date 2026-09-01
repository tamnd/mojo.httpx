# Request bodies

There are six ways to put a body on a request and they are six arguments. httpx2 has four, and tells bytes from strings from iterables at runtime, which is a thing Python can do and Mojo cannot. Naming them apart is better than one argument and a wrapper whose only job is to hide which one the caller meant.

| Argument | Type | Content type it implies |
| --- | --- | --- |
| `content=` | `List[UInt8]` | none |
| `text=` | `StringSpan` | none |
| `data=` | `QueryParams` | `application/x-www-form-urlencoded` |
| `files=` | `MultipartData` | `multipart/form-data; boundary=...` |
| `json=` | `Json` | `application/json` |
| `content_stream=` | `ByteStream` | none |

All six are on `request`, `stream`, `post`, `put` and `patch`, on `Client` and on the top level helpers, and on `build_request` for a caller who wants to see the request without sending it. `get`, `head`, `options` and `delete` do not take a body, because RFC 9110 gives one no defined semantics on those and httpx2 leaves it out of the signature for the same reason.

## One body per request

Passing two of these raises, and the message names both.

```mojo
var r = client.post("/items", data=form^, json=payload^)
# InvalidArgument: more than one request body was given: data=, json=
```

httpx2 lets `data=` and `json=` fight and silently drops the loser, so the caller finds out from the server, several layers away from the line that caused it. There is no reading of that call where the caller knew what they wanted, so refusing is more useful than picking.

The exception is `data=` with `files=`, which is not two bodies but one. The fields and the files go into the same multipart body, written fields first, which is what a browser sends for a form with a file input on it.

An argument left empty is not a body. An empty `QueryParams` next to a real `json=` is one body, not a conflict, because every one of these types has an empty value that cannot be told apart from not passing it at all.

## The content type is a default, not an override

Each encoder says what type describes its bytes, and the client writes that type only if nothing else already did. A `Content-Type` the caller put in `headers=`, on the call or on the client, wins.

```mojo
var headers = Headers()
headers["Content-Type"] = "application/vnd.api+json"
var r = client.post("/items", json=payload^, headers=headers^)
# Content-Type: application/vnd.api+json
```

That is what makes `json=` usable against an API with its own media type, which is most of the ones that are strict about media types.

## `content=` and `text=` name no type

This is the one answer that surprises people, and it is deliberate. Bytes with no further description are `application/octet-stream` as far as HTTP is concerned, but guessing that on the caller's behalf means silently labelling every hand built body, including the ones that are already JSON or already form encoded. httpx2 sets nothing here and neither does this. A caller who wants a type writes one.

`text=` is UTF-8 and that is not configurable. A body in any other encoding needs a `Content-Type` saying so, which means the caller is passing a charset anyway, which means they can encode the bytes themselves and pass those.

## Forms

`data=` takes a `QueryParams`, the same multi valued type the query string uses, and encodes with the same encoder.

```mojo
var form = QueryParams().add("name", "a b").add("tag", "x&y")
var r = client.post("/search", data=form^)
# name=a+b&tag=x%26y
```

Delegating to the query encoder rather than writing pairs out by hand is the entire security content of this. A value containing `&` or `=` comes out escaped and cannot introduce a field that was not there.

## Files

`files=` takes a `MultipartData`, which holds text fields and file uploads in one value.

```mojo
var files = MultipartData()
files.add("caption", "on holiday")
files.add_file(FileUpload("photo", "beach.jpg", bytes^))
var r = client.post("/upload", files=files^)
```

A `FileUpload` with no content type gets one guessed from the filename, and `application/octet-stream` when the extension says nothing. A wrong content type is worse than an unspecific one, because the receiving side may act on it.

The boundary is drawn fresh for every body, from the operating system rather than from a seeded generator, and every part is scanned for it before the body is built. Two requests sharing a boundary means anybody who saw the first knows the boundary of the second, and knowing the boundary is the whole of what forging a part needs. [Architecture](architecture.md) has the rest of the multipart reasoning, including why filenames are escaped the way browsers escape them rather than the way RFC 2231 says to.

## JSON

`json=` takes a `Json` document, serialized compactly with no spaces, as `application/json` with no charset parameter. RFC 8259 defines the media type as UTF-8 and says the parameter is neither required nor defined, so adding it is noise a strict server is entitled to reject.

```mojo
var payload = Json.object()
payload.set("name", Json("widget"))
payload.set("count", Json(3))
var r = client.post("/items", json=payload^)
# {"name":"widget","count":3}
```

The argument is an `Optional` rather than a plain `Json` so that `json=Json.null()` sends `null`, which is a valid document and a sensible thing to send, instead of being read as nothing passed. [JSON](json.md) covers building and reading documents.

## Streaming

`content_stream=` is a body pulled as it is written rather than held in memory, for an upload too large to buffer or one whose length is not known in advance. It cannot be combined with any of the others.

```mojo
var r = client.post("/upload", content_stream=Optional[ByteStream](source^))
```

With no length known when the head is written, the body goes out chunked. A caller who does know the length can set `Content-Length` themselves and get a length framed body instead, which is worth having because some servers and more proxies still handle chunked request bodies badly. A one shot stream cannot be sent twice, so a redirect that would have to resend it fails with an error saying so rather than sending an empty body.
