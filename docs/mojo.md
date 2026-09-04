# Mojo notes

This page is for somebody who knows Python and httpx and is now reading Mojo. It is not a language tutorial. It is the handful of facts that explain why the API here looks the way it does, because almost every difference from httpx2 traces back to one of them.

If something in the library surprised you, it is probably on this page or in the [Compatibility guide](deviations.md).

## Values are owned, and `^` gives ownership away

Mojo has no garbage collector. Every value has one owner, and passing it somewhere either lends it or gives it away. `^` is how you give it away.

```mojo
from httpx import Client, Headers


def main() raises:
    var headers = Headers()
    headers["Accept"] = "application/json"

    # The client takes the headers. `headers` is gone after this line.
    with Client(headers=headers^) as client:
        print(client.get("https://example.com/").status_code)
```

Anywhere the docs write `something^`, the argument is being handed over rather than copied. Leave the `^` off and the compiler tells you which of the two it wanted. It is not a performance hint, it is the difference between two things that do not mean the same.

This is why `Response.raise_for_status()` returns nothing. A `Response` is not copyable, so a method that gave one back would have to consume the receiver, and `r` would be gone afterwards. Two lines is cheaper than losing the response you were about to read.

## A value dies at its last use, not at the end of the block

Mojo destroys a value immediately after the last line that reads it. This is the rule most likely to surprise you, because Python keeps a name alive until the scope ends.

```mojo
from httpx import Client


def main() raises:
    var client = Client()
    var r = client.get("https://example.com/")
    # `client` is destroyed here, on its last use above, and its pool with it.
    print(r.status_code)
```

That is usually what you want and occasionally not. Use a `with` block when the lifetime matters, which is what every example in these docs does, because it says exactly where the pool closes.

The same rule is why a streamed response wants a `with` around it. The connection goes back to the pool when the body ends and is closed if you leave early, and both happen because the response was destroyed.

## `def` does not raise unless it says so

In Mojo 1.0 a `def` is not implicitly raising. If a function can fail, `raises` is written out.

```mojo
import httpx


def fetch(url: String) raises -> Int:
    return httpx.get(url).status_code


def main() raises:
    print(fetch("https://example.com/"))
```

Almost everything in an HTTP client can fail, which is why nearly every example says `def main() raises:`. If you forget it, the error is `cannot call function that may raise in a context that cannot raise`, and it names the line.

## There is one error type, so you ask rather than catch

`raise` takes an `Error`, `except e` binds it, and there are no subclasses and no `except SomeType` filtering. httpx2's class hierarchy is reproduced as a set of questions.

```mojo
import httpx


def main() raises:
    try:
        print(httpx.get("https://example.com/").status_code)
    except e:
        if httpx.is_timeout(e):
            print("too slow")
        elif httpx.is_transport_error(e):
            print("the network")
        else:
            raise e
```

The predicates nest the way the classes do, so `is_timeout` is true for all four timeouts and `is_http_error` is true for anything raised for a request. `kind_of(e).name()` gives back httpx2's class name for a log line, and `message_of(e)` gives the message without the kind on the front. The kind travels as the leading token of the message text, which is not a trick: httpx2 messages already read `ConnectError: ...`, so the human readable form and the machine readable form are the same string.

## `len()` does not work on a `String`

`len()` on a `String` is a compile error in Mojo 1.0, because the byte answer and the grapheme answer are different numbers and neither is the obvious one. Use `s.byte_length()`, and slice with `s[byte=start:end]`.

You mostly do not run into this, because the library hands you `String` at the boundary and does its own parsing over bytes. It comes up when you write your own parsing over something the library gave you.

`len()` on a `List`, a `Headers`, a `QueryParams` or a `Json` array works normally.

## There are no generators, so an iterator is a `while` loop

```mojo
from httpx import Client


def main() raises:
    with Client() as client:
        with client.stream("GET", "https://example.com/big.log") as r:
            var lines = r.iter_lines()
            while lines.has_next():
                print(lines.next())
```

This is the ugliest thing in the library and it is not a style choice. Mojo 1.0 drops an error raised out of `__next__`: a `for` loop over an iterator whose `__next__` raises stops as if the iterator had run out, and the error never reaches the caller. The compiler goes further and warns that a `try` around the loop is unreachable, so wrapping it does not help.

For an HTTP client that is the worst possible failure mode. A connection dying halfway through a response body would end the loop quietly, and the truncated body would be indistinguishable from a complete one. So `ByteChunks`, `TextChunks` and `LineChunks` have `has_next` and `next`, and `next` raises the way any other read does. `tests/unit/test_language.mojo` pins the compiler behaviour that forced this, so a later Mojo that fixes it shows up as a failing test.

## There is no `Any`, so JSON is typed at the leaf

`r.json()` cannot hand back "whatever the document happened to be", because Mojo has no dynamic `Any`. It hands back a `Json`, indexing works, and the type check happens where you read a value.

```mojo
import httpx


def main() raises:
    var body = httpx.get("https://httpbin.org/get").json()

    print(body["url"].as_string())
    print(body["headers"]["Host"].as_string())

    if "args" in body:
        print(len(body["args"]))
```

`as_string`, `as_int`, `as_float` and `as_bool` each raise if the value is not that. `is_string`, `is_null` and the rest ask without raising. Membership is `in`.

The tree underneath is an arena of nodes indexed by integer rather than a struct that holds itself, because Mojo 1.0 has no recursive structs. That is invisible from outside except that a `Json` is cheap to pass around.

## There are no trait objects, so a transport is erased explicitly

Mojo has no trait objects, so a field cannot hold "some `Transport`". What it holds is `AnyTransport`, a reference counted box with a vtable, and `erase_transport` is how a concrete one becomes that.

```mojo
from httpx import Client, MockRouter, Route, erase_transport


def main() raises:
    var router = MockRouter()
    router.add(Route.any().respond(204))

    var transport = erase_transport(router^)
    var handle = transport.copy()

    with Client(transport^) as client:
        print(client.get("https://example.com/").status_code)

    print(len(handle.state[MockRouter]().calls))
```

`state[T]()` gets the concrete value back out. Taking a `copy()` before handing the transport to the client is how you keep a way to read it afterwards, and a copy is the same transport rather than a second one.

The same shape appears as `erase_auth`, `erase_source`, `erase_request_hook` and `erase_response_hook`. When you see `erase_` in this library, that is what it is doing.

## There is no `**kwargs`, so configuration is typed

httpx2 passes configuration around as keyword arguments and sorts out at runtime what it got. Mojo has no keyword argument packing and no runtime type dispatch, so each of those becomes a named type with a constructor that can report a mistake where the mistake was written.

`proxy="http://localhost:3128"` is `proxy=Proxy("http://localhost:3128")`. `auth=("user", "pass")` is `auth=basic_auth("user", "pass")`. `mounts={...}` is a `Mounts` table built a mount at a time. In each case the alternative was another overload of a constructor that already has seventeen keyword arguments.

## Optional is explicit

There is no `None` that fits anywhere. An argument that may be absent is `Optional[T]`, and you get at the value with `.value()` after checking it.

```mojo
import httpx


def main() raises:
    var r = httpx.get("https://api.example.com/items")
    var next = r.link_url("next")
    if next:
        print(String(next.value()))
```

A bare `Optional[T]` is truthy when it holds something, so `if next:` reads the way it does in Python.

Where the library takes a number that may be absent, such as a timeout phase, a plain number converts into the `Optional` for you: `Timeout.uniform(2.0)` works and so does `Timeout.uniform(None)`, which means no limit on any phase.

## Async is not asyncio

There is no `async with`, no `await` on a client method, and no `asyncio.gather`. `AsyncClient` is used exactly like `Client`, with an ordinary `with` block and ordinary calls, and concurrency is `httpx.gather(client, requests)`.

```mojo
import httpx
from httpx import URL


def main() raises:
    with httpx.AsyncClient(base_url=URL("http://api.example.com")) as client:
        var pending = List[httpx.Request]()
        pending.append(client.build_request("GET", "/users/1"))
        pending.append(client.build_request("GET", "/users/2"))

        var answers = httpx.gather(client, pending^)
        for i in range(len(answers)):
            print(answers[i].status_code)
```

The reason `gather` takes a list rather than letting you assemble the coroutines yourself is that a `Coroutine` in Mojo 1.0 is a linear type: it cannot be stored in a variable, put in a list or returned, so there is no way to hand you a request in progress. [Async support](async.md) has that argument and everything that follows from it.

## What to read when the compiler says something odd

`cannot call function that may raise in a context that cannot raise` means a missing `raises` on the enclosing `def`.

`value of type 'X' cannot be copied into its destination` usually means a missing `^` on an argument that takes ownership.

`use of uninitialized value` after a `^` means you used something you already gave away.

`no matching function in initialization` with a list of candidates is Mojo showing every overload it considered. The useful line is the one saying `unexpected keyword argument` or `cannot be converted from`, which names the actual mistake.

[Troubleshooting](troubleshooting.md) covers the errors the library raises rather than the ones the compiler does.
