# JSON

`response.json()` parses the body and hands back a `Json`, which you index into and then ask for a concrete type.

```mojo
var r = httpx.get("https://api.example.com/users")

print(r.json()["users"][0]["name"].as_string())
```

That is one line longer than Python, and the extra call is where the type checking happens. In Python `r.json()["users"][0]["name"]` is an `Any` and stays an `Any` until something downstream trips over it. Here `as_string()` is the point at which the code says what it expected, so a server that started sending a number instead raises at the access with a message naming the key, rather than three functions later.

## Reading a body

Hold the document in a variable when you are going to read more than one thing out of it. The values you index out of it borrow from it, so it has to outlive them, and the compiler will tell you if it does not.

```mojo
var body = r.json()

var total = body["total"].as_int()
for user in body["users"].members():
    print(user["id"].as_int(), user["name"].as_string())
```

`members()` walks an array's elements or an object's values in document order. On an object, each value's `key()` gives the name it was stored under.

The accessors are `as_string`, `as_int`, `as_float` and `as_bool`. Each one raises if the value is a different kind, and the message says which kind was actually there and, when the value came from an object, which key it was under.

When you do not know the shape yet, ask before you read. `is_null`, `is_bool`, `is_number`, `is_string`, `is_array` and `is_object` never raise, and neither does `len`, which is zero for anything that is not a container.

```mojo
var body = r.json()
if "error" in body:
    print("failed:", body["error"].as_string())
```

`body.get("error")` is the form that returns nothing instead of raising, including when the document is not an object at all.

## Numbers

A number is kept as the text the server sent, and `as_int` reads the digits rather than rounding a `Float64`. That matters more than it sounds like it does. Every integer above 2^53 comes back off a double as a different number, and an id is exactly the kind of field that gets that large. `9007199254740993` reads back as `9007199254740993` here.

The other side of that: `as_int` on `1.0` raises rather than returning `1`. A service that sends `1.0` where the caller wants an id may send `1.5` next, and the complaint is worth making. Use `as_float` when a fraction is expected.

`as_int` on a number too large for an `Int` raises rather than wrapping or saturating.

## Building a body

```mojo
var payload = Json.object()
payload.set("name", String("widget"))
payload.set("count", 3)
payload.set("active", True)

var tags = Json.array()
tags.append(String("blue"))
tags.append(String("small"))
payload.set("tags", tags^)
```

`set` and `append` take a `String`, an `Int`, a `Float64`, a `Bool` or another `Json`. Nesting is bottom up: build the inner document, then move it into the outer one with `^`. A parsed document can be nested into a built one the same way, which is how you forward a body you received.

Setting a key that is already there replaces it. A builder that let you write the same key twice would be a builder that produced a document two parsers might read differently.

`to_bytes()` gives the bytes to put on the wire, and `String(payload)` gives the same thing as text. The output is compact, with no space after the separators, and non-ASCII goes out as UTF-8 rather than as `\u` escapes. That is `json.dumps(..., separators=(",", ":"), ensure_ascii=False)` in Python's terms.

## What is rejected

Strictly RFC 8259, which is what Python's `json` module accepts and therefore what anything ported from httpx2 already expects.

| Not accepted | Example |
| --- | --- |
| Trailing commas | `{"a": 1,}` |
| Comments | `// x` and `/* x */` |
| Single quoted strings | `{'a': 1}` |
| Unquoted keys | `{a: 1}` |
| `NaN` and `Infinity` | what `json.dumps` writes for those floats |
| Leading zeros and a leading plus | `01`, `+1` |
| Incomplete numbers | `1.`, `.5`, `1e` |
| Bare control characters in a string | a literal newline between the quotes |
| Anything after the top level value | `{} {}` |

Two more are worth spelling out because parsers differ on them.

Invalid UTF-8 in the body is an error rather than something quietly replaced. A body that is not the encoding it claims has already been misread by whatever produced it, and turning the evidence into replacement characters hides that.

A lone surrogate in a `\u` escape is an error. `"\uD800"` on its own has no UTF-8 encoding, and the alternatives are to invent a replacement character or to produce bytes that a `String` would refuse to hold.

Duplicate keys are allowed and the last one wins, which is what Python and JavaScript do. `keys()` lists every one that appeared, so code that cares can count.

## Depth

Nesting is capped at two hundred, the same as Python's default, and a document deeper than that is refused with an error rather than accepted.

This is a limit rather than a budget. A response body is attacker controlled, and a recursive descent parser handed a few hundred thousand open brackets exhausts the machine stack, which is not something the caller can catch. The parser here keeps its own stack on the heap and stops counting at the cap, so the worst a body of nothing but brackets can do is produce an error.

The same limit applies to documents you build, which is what lets the serializer be a plain recursion.

## Errors

A parse failure says the line, the column, what was expected, and shows the bytes around the problem.

```
the response body is not valid JSON at line 3 column 8: expected a value Near: '"b": nope\n}'
```

The excerpt goes through the same escaping every other error in this library uses, so a body containing a terminal escape sequence or a newline cannot reshape the log line it ends up in.

Parse failures carry `ErrorKind.DECODING_ERROR`. Asking a value for the wrong type carries `ErrorKind.INVALID_ARGUMENT`.

## The content type is not consulted

`response.json()` parses whatever the body is, regardless of what the `Content-Type` header says. Real services send JSON labelled `text/plain`, labelled `application/octet-stream`, and labelled nothing at all, and refusing to parse an obviously fine body because of a header the caller cannot change would only mean the caller reaches past this to `parse_json` and gets the same result with more typing. A body that is not JSON raises either way.

## Design

A JSON value is not a tree of structs here, because Mojo 1.0 cannot compile a struct that holds a list of itself. A document is two flat lists: one node per value, holding offsets and the indices of its first child and next sibling, and one byte buffer holding every decoded string and every number as it was written.

That turned out to be the better design regardless. Parsing allocates two buffers and grows them, rather than one allocation per value, and `body["users"][0]["name"]` walks integers and copies nothing. `Json` owns the two lists and `JsonValue` is a borrowed view of one node in them, which is why a value cannot outlive the document it came from.

See [architecture](architecture.md) for how this fits the rest of the library.
