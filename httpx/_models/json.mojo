"""JSON, as a value you can ask questions of.

```mojo
var body = response.json()
print(body["users"][0]["name"].as_string())
```

In Python `r.json()` hands back whatever the body happened to contain and every
access is a bet that it was the shape you expected. Mojo has no `Any`, so the
bet has to be made explicitly, and that turns out to be the better deal: a body
that is not the shape the calling code assumed raises here, saying which key
was wrong and what it actually held, instead of failing three functions later
as an attribute error on `None`.

## Why an arena and not a tree

The obvious shape for a JSON value is a struct that holds a list of itself.
Mojo 1.0 will not compile that, because a struct cannot be `Deinitable` while
one of its fields needs the struct to already be `Deinitable`, and there is no
way to break the cycle without a raw pointer.

That constraint pushed this towards a design that is better anyway. A document
is two flat lists: `_Node`, one per value, holding offsets and the indices of
its first child and next sibling, and `_text`, one byte buffer holding every
decoded string and every number as it was written. Parsing a response allocates
two buffers and grows them, rather than one allocation per value, and reading
`body["users"][0]["name"]` walks integers and copies nothing.

`Json` owns those two lists. `JsonValue` is a borrowed view of one node in
them: two spans and an index, which is why it carries two origin parameters.
Indexing gives back another `JsonValue` into the same document, so a chain of
lookups is a chain of integer walks.

## Why the parser has an explicit stack

A response body is attacker controlled. A recursive descent parser given
`[[[[[[...` recurses once per bracket, and a few hundred thousand of those
overflow the machine stack, which is not an exception you can catch. That is a
one line denial of service against anything that calls `r.json()` on a body it
did not write, so the parser here keeps its own stack on the heap and refuses
anything deeper than `MAX_DEPTH`.

## What is rejected

Strictly RFC 8259, which is what Python's `json` module does and therefore what
httpx2 users already expect.

No trailing commas, no comments, no single quotes, no unquoted keys, no `NaN`
or `Infinity`, no leading zeros or leading plus on a number, no control
character inside a string without an escape, and nothing after the top level
value but whitespace.

Two rejections are worth the extra sentence. Invalid UTF-8 in the body is an
error rather than something quietly replaced, because a body that is not the
encoding it claims is a body somebody else has already misread. And a lone
surrogate in a `\\u` escape is an error, because it has no UTF-8 encoding at all
and the alternatives are to invent a replacement character or to produce bytes
that `String` would refuse.

Duplicate keys are allowed, and a lookup finds the last one. That is what
Python, JavaScript and every other mainstream parser do. Rejecting them would
be defensible and is not what the ecosystem does, so a caller who cares has
`keys` to count with.
"""

from httpx._bytes import _quote, append_codepoint, is_digit, utf8_length
from httpx._exceptions import ErrorKind, new_error
from std.collections.string import StringSpan

comptime KIND_NULL = 0
comptime KIND_BOOL = 1
comptime KIND_NUMBER = 2
comptime KIND_STRING = 3
comptime KIND_ARRAY = 4
comptime KIND_OBJECT = 5

comptime MAX_DEPTH = 200
"""How deeply values may nest.

Enforced by the parser and by the builder, so every document in existence
respects it and the serializer can be written as a plain recursion without
having to worry about how it got that deep.

Two hundred is what Python's `json` module allows by default and it is far
beyond anything a real API returns. The number exists to bound an attack, not
to be a budget anybody spends.
"""

comptime _QUOTE = UInt8(ord('"'))
comptime _BACKSLASH = UInt8(ord("\\"))
comptime _SLASH = UInt8(ord("/"))
comptime _COLON = UInt8(ord(":"))
comptime _COMMA = UInt8(ord(","))
comptime _LBRACE = UInt8(ord("{"))
comptime _RBRACE = UInt8(ord("}"))
comptime _LBRACKET = UInt8(ord("["))
comptime _RBRACKET = UInt8(ord("]"))
comptime _MINUS = UInt8(ord("-"))
comptime _PLUS = UInt8(ord("+"))
comptime _DOT = UInt8(ord("."))
comptime _ZERO = UInt8(ord("0"))
comptime _NINE = UInt8(ord("9"))


@fieldwise_init
struct _Node(ImplicitlyCopyable, Movable):
    """One value in a document.

    Children are a singly linked list rather than a `List` per node, because a
    nested `List` would be an allocation per container and the whole point of
    the arena is that there are two allocations in total. `last` is carried so
    that appending to a container is O(1) instead of a walk to the end, which
    on a ten thousand element array is the difference between linear and
    quadratic parsing.
    """

    var kind: Int
    var truth: Bool
    var key_start: Int
    var key_length: Int
    """Where this member's name sits in `_text`. Length is -1 for a value that
    is not a member of an object, which is not the same as a member whose name
    is the empty string."""

    var text_start: Int
    var text_length: Int
    """The decoded string for `KIND_STRING`, or the number exactly as it was
    written for `KIND_NUMBER`. Numbers are kept as text so that a 64 bit
    integer survives a round trip, which it would not if it went through a
    `Float64` on the way in."""

    var first: Int
    var last: Int
    var next: Int
    var count: Int


def _blank(kind: Int) -> _Node:
    return _Node(kind, False, 0, -1, 0, 0, -1, -1, -1, 0)


struct JsonValue[no: ImmOrigin, to: ImmOrigin](
    ImplicitlyCopyable, Movable, Sized, Writable
):
    """One value inside a document, borrowed rather than owned.

    Two origins because it holds two spans into two different fields of the
    `Json` it came from, and Mojo tracks each field's origin separately. They
    are always the same document. Nothing here allocates and nothing here can
    outlive the document, which the compiler enforces.

    ```mojo
    from httpx import Json


    def main() raises:
        var doc = Json.loads('{"users": [{"name": "alice"}]}')
        var root = doc.value()
        var first = root["users"][0]
        print(first["name"].as_string(), first.is_object())
    ```
    """

    var _nodes: Span[_Node, Self.no]
    var _text: Span[UInt8, Self.to]
    var _index: Int

    def __init__(
        out self,
        nodes: Span[_Node, Self.no],
        text: Span[UInt8, Self.to],
        index: Int,
    ):
        self._nodes = nodes
        self._text = text
        self._index = index

    def kind(self) -> Int:
        return self._nodes[self._index].kind

    def is_null(self) -> Bool:
        return self.kind() == KIND_NULL

    def is_bool(self) -> Bool:
        return self.kind() == KIND_BOOL

    def is_number(self) -> Bool:
        return self.kind() == KIND_NUMBER

    def is_string(self) -> Bool:
        return self.kind() == KIND_STRING

    def is_array(self) -> Bool:
        return self.kind() == KIND_ARRAY

    def is_object(self) -> Bool:
        return self.kind() == KIND_OBJECT

    def __len__(self) -> Int:
        """How many members or elements. Zero for anything that is not a
        container, rather than an error, because `len` cannot raise and an
        answer of zero for a scalar is at least not misleading."""
        return self._nodes[self._index].count

    def key(self) -> Optional[String]:
        """The name this value was stored under, if it is a member of an object.

        Useful when walking an object with `members`, and empty for an array
        element or for the root, which is why it is an `Optional` and not an
        empty string.
        """
        ref node = self._nodes[self._index]
        if node.key_length < 0:
            return None
        return Optional(self._slice(node.key_start, node.key_length))

    def as_string(self) raises -> String:
        ref node = self._nodes[self._index]
        if node.kind != KIND_STRING:
            raise self._wrong("a string")
        return self._slice(node.text_start, node.text_length)

    def as_bool(self) raises -> Bool:
        ref node = self._nodes[self._index]
        if node.kind != KIND_BOOL:
            raise self._wrong("true or false")
        return node.truth

    def as_int(self) raises -> Int:
        """The value as an integer, exactly.

        Reads the digits rather than rounding a `Float64`, so a number that
        does not fit an `Int` is an error and never a silently different
        number. A number with a fraction or an exponent is refused too: an API
        that sent `1.0` where the caller wanted an id is worth a complaint,
        because the next value it sends may be `1.5`.
        """
        ref node = self._nodes[self._index]
        if node.kind != KIND_NUMBER:
            raise self._wrong("a number")
        var text = self._text[
            node.text_start : node.text_start + node.text_length
        ]
        return _parse_int(text)

    def as_float(self) raises -> Float64:
        ref node = self._nodes[self._index]
        if node.kind != KIND_NUMBER:
            raise self._wrong("a number")
        var text = self._slice(node.text_start, node.text_length)
        return Float64(text)

    def get(self, key: StringSpan) -> Optional[Self]:
        """The member named `key`, or nothing.

        The last one, when a badly behaved server sent the name twice. That
        matches Python and JavaScript, so code ported from either behaves the
        same way here.
        """
        ref node = self._nodes[self._index]
        if node.kind != KIND_OBJECT:
            return None
        var wanted = key.as_bytes()
        var found = -1
        var at = node.first
        while at >= 0:
            ref child = self._nodes[at]
            if child.key_length == wanted.__len__():
                var name = self._text[
                    child.key_start : child.key_start + child.key_length
                ]
                if name == wanted:
                    found = at
            at = child.next
        if found < 0:
            return None
        return Optional(Self(self._nodes, self._text, found))

    def __contains__(self, key: StringSpan) -> Bool:
        return self.get(key).__bool__()

    def __getitem__(self, key: StringSpan) raises -> Self:
        var found = self.get(key)
        if found:
            return found.value()
        if not self.is_object():
            raise self._wrong("an object")
        raise new_error(
            ErrorKind.INVALID_ARGUMENT,
            String(
                "no key '",
                key,
                "' in this object. It has: ",
                _name_list(self.keys()),
            ),
        )

    def __getitem__(self, index: Int) raises -> Self:
        ref node = self._nodes[self._index]
        if node.kind != KIND_ARRAY:
            raise self._wrong("an array")
        # Negative indices count from the end, as they do everywhere else in
        # Mojo and Python. A JSON array is the one place a caller reaches for
        # `[-1]` without thinking about it.
        var wanted = index + node.count if index < 0 else index
        if wanted < 0 or wanted >= node.count:
            raise new_error(
                ErrorKind.INVALID_ARGUMENT,
                String(
                    "index ",
                    index,
                    " is outside this array, which has ",
                    node.count,
                    " element(s)",
                ),
            )
        var at = node.first
        for _ in range(wanted):
            at = self._nodes[at].next
        return Self(self._nodes, self._text, at)

    def keys(self) -> List[String]:
        """Every member name, in the order the document had them.

        Duplicates are listed as many times as they appeared, because hiding
        them here would make `len(keys())` disagree with what a second parser
        of the same bytes would report.
        """
        var out = List[String]()
        ref node = self._nodes[self._index]
        if node.kind != KIND_OBJECT:
            return out^
        var at = node.first
        while at >= 0:
            ref child = self._nodes[at]
            out.append(self._slice(child.key_start, child.key_length))
            at = child.next
        return out^

    def members(self) -> List[Self]:
        """Every element of an array, or every value of an object, in order.

        A list rather than an iterator struct because a view is a handful of
        words and building the list costs one allocation, which is cheaper than
        the iterator machinery would be to read.
        """
        var out = List[Self]()
        var at = self._nodes[self._index].first
        while at >= 0:
            out.append(Self(self._nodes, self._text, at))
            at = self._nodes[at].next
        return out^

    def write_to[W: Writer](self, mut writer: W):
        """This value as JSON text, compactly.

        No spaces after the separators, matching `json.dumps(separators=...)`
        rather than its default, because this is what goes on a wire far more
        often than it goes on a screen.
        """
        _write_node(writer, self._nodes, self._text, self._index)

    def _slice(self, start: Int, length: Int) -> String:
        # Sound without a UTF-8 check because everything in `_text` was put
        # there by the parser, which validated it, or by the builder, which
        # took it from a `String`.
        return String(
            StringSpan(unsafe_from_utf8=self._text[start : start + length])
        )

    def _wrong(self, wanted: StringSpan) -> Error:
        var under = String()
        var name = self.key()
        if name:
            under = String(" under '", name.value(), "'")
        return new_error(
            ErrorKind.INVALID_ARGUMENT,
            String(
                "expected ",
                wanted,
                under,
                ", found ",
                kind_name(self.kind()),
            ),
        )


struct Json(Movable, Sized, Writable):
    """A whole JSON document, owning its nodes and its text.

    Built by parsing, or assembled a field at a time for a request body:

    ```mojo
    from httpx import Client, Json


    def main() raises:
        var body = Json.object()
        body.set("name", "alice")
        body.set("admin", True)
        with Client() as client:
            var r = client.post("https://example.com/users", json=body^)
            print(r.json().value()["id"].as_int())
    ```

    The root value is always node zero, so an empty `Json` does not exist. A
    default constructed one is `null`, which is a real JSON document and a
    sensible thing to send.
    """

    var _nodes: List[_Node]
    var _text: List[UInt8]
    var _depth: Int
    """The deepest nesting anywhere in this document, counting the root as one.

    Tracked as the document is built so that `set` and `append` can refuse to
    make one deeper than `MAX_DEPTH` without walking it first. That keeps the
    limit a property of every document rather than only of parsed ones, which
    is what lets the serializer recurse.
    """

    def __init__(out self):
        """A `null` document."""
        self._nodes = List[_Node]()
        self._nodes.append(_blank(KIND_NULL))
        self._text = List[UInt8]()
        self._depth = 1

    def __init__(out self, value: StringSpan):
        self._nodes = List[_Node]()
        var node = _blank(KIND_STRING)
        node.text_start = 0
        node.text_length = value.byte_length()
        self._nodes.append(node)
        self._text = List[UInt8]()
        self._text.extend(value.as_bytes())
        self._depth = 1

    def __init__(out self, value: Int):
        self = Self._number(String(value))

    def __init__(out self, value: Float64):
        self = Self._number(String(value))

    def __init__(out self, value: Bool):
        self._nodes = List[_Node]()
        var node = _blank(KIND_BOOL)
        node.truth = value
        self._nodes.append(node)
        self._text = List[UInt8]()
        self._depth = 1

    @staticmethod
    def object() -> Self:
        return Self._container(KIND_OBJECT)

    @staticmethod
    def array() -> Self:
        return Self._container(KIND_ARRAY)

    @staticmethod
    def null() -> Self:
        return Self()

    @staticmethod
    def _container(kind: Int) -> Self:
        var out = Self()
        out._nodes[0] = _blank(kind)
        return out^

    @staticmethod
    def _number(text: String) -> Self:
        var out = Self()
        var node = _blank(KIND_NUMBER)
        node.text_start = 0
        node.text_length = text.byte_length()
        out._nodes[0] = node
        out._text.extend(text.as_bytes())
        return out^

    @staticmethod
    def parse[o: ImmOrigin](source: Span[UInt8, o]) raises -> Self:
        return parse_json(source)

    @staticmethod
    def loads(source: StringSpan) raises -> Self:
        return parse_json(source.as_bytes())

    def copy(self) -> Self:
        var out = Self()
        out._nodes = self._nodes.copy()
        out._text = self._text.copy()
        out._depth = self._depth
        return out^

    def kind(self) -> Int:
        return self._nodes[0].kind

    def __len__(self) -> Int:
        return self._nodes[0].count

    def set(mut self, key: StringSpan, var value: Self) raises:
        """Add or replace a member of the root object.

        Replaces rather than appending when the key is already there, because
        a builder that let a caller produce a duplicate would be a builder that
        produced a document two parsers might read differently.
        """
        if self._nodes[0].kind != KIND_OBJECT:
            raise new_error(
                ErrorKind.INVALID_ARGUMENT,
                String(
                    "cannot set '",
                    key,
                    "' on ",
                    kind_name(self._nodes[0].kind),
                    ". Start from Json.object().",
                ),
            )
        self._check_depth(value._depth)
        self._remove(key)
        var key_start = len(self._text)
        self._text.extend(key.as_bytes())
        var index = self._absorb(value^)
        self._nodes[index].key_start = key_start
        self._nodes[index].key_length = key.byte_length()
        self._link(index)

    def set(mut self, key: StringSpan, value: StringSpan) raises:
        self.set(key, Self(value))

    def set(mut self, key: StringSpan, value: Int) raises:
        self.set(key, Self(value))

    def set(mut self, key: StringSpan, value: Float64) raises:
        self.set(key, Self(value))

    def set(mut self, key: StringSpan, value: Bool) raises:
        self.set(key, Self(value))

    def append(mut self, var value: Self) raises:
        """Add an element to the root array."""
        if self._nodes[0].kind != KIND_ARRAY:
            raise new_error(
                ErrorKind.INVALID_ARGUMENT,
                String(
                    "cannot append to ",
                    kind_name(self._nodes[0].kind),
                    ". Start from Json.array().",
                ),
            )
        self._check_depth(value._depth)
        var index = self._absorb(value^)
        self._link(index)

    def append(mut self, value: StringSpan) raises:
        self.append(Self(value))

    def append(mut self, value: Int) raises:
        self.append(Self(value))

    def append(mut self, value: Float64) raises:
        self.append(Self(value))

    def append(mut self, value: Bool) raises:
        self.append(Self(value))

    def value(self) -> JsonValue[origin_of(self._nodes), origin_of(self._text)]:
        """The root, as something that can be indexed and read."""
        return JsonValue(Span(self._nodes), Span(self._text), 0)

    def get(
        self, key: StringSpan
    ) -> Optional[JsonValue[origin_of(self._nodes), origin_of(self._text)]]:
        return self.value().get(key)

    def __contains__(self, key: StringSpan) -> Bool:
        return self.value().__contains__(key)

    def __getitem__(
        self, key: StringSpan
    ) raises -> JsonValue[origin_of(self._nodes), origin_of(self._text)]:
        return self.value()[key]

    def __getitem__(
        self, index: Int
    ) raises -> JsonValue[origin_of(self._nodes), origin_of(self._text)]:
        return self.value()[index]

    def keys(self) -> List[String]:
        return self.value().keys()

    def members(
        self,
    ) -> List[JsonValue[origin_of(self._nodes), origin_of(self._text)]]:
        return self.value().members()

    def as_string(self) raises -> String:
        return self.value().as_string()

    def as_int(self) raises -> Int:
        return self.value().as_int()

    def as_float(self) raises -> Float64:
        return self.value().as_float()

    def as_bool(self) raises -> Bool:
        return self.value().as_bool()

    def to_bytes(self) -> List[UInt8]:
        """The document as the bytes to put in a request body."""
        var out = String()
        _write_node(out, Span(self._nodes), Span(self._text), 0)
        var bytes = List[UInt8]()
        bytes.extend(out.as_bytes())
        return bytes^

    def write_to[W: Writer](self, mut writer: W):
        _write_node(writer, Span(self._nodes), Span(self._text), 0)

    def _check_depth(mut self, added: Int) raises:
        var wanted = 1 + added
        if wanted > MAX_DEPTH:
            raise new_error(
                ErrorKind.INVALID_ARGUMENT,
                String(
                    "this would nest ",
                    wanted,
                    " deep and the limit is ",
                    MAX_DEPTH,
                ),
            )
        if wanted > self._depth:
            self._depth = wanted

    def _absorb(mut self, var value: Self) -> Int:
        """Copy another document's nodes and text in, and return its new root.

        The two arenas are concatenated and the moved nodes have every index
        they hold shifted by how far they moved, which is what makes building
        bottom up work: an inner object is a complete document until the moment
        it becomes part of an outer one.
        """
        var node_shift = len(self._nodes)
        var text_shift = len(self._text)
        for i in range(len(value._nodes)):
            var node = value._nodes[i]
            if node.key_length >= 0:
                node.key_start += text_shift
            if node.kind == KIND_STRING or node.kind == KIND_NUMBER:
                node.text_start += text_shift
            if node.first >= 0:
                node.first += node_shift
            if node.last >= 0:
                node.last += node_shift
            if node.next >= 0:
                node.next += node_shift
            self._nodes.append(node)
        self._text.extend(Span(value._text))
        return node_shift

    def _link(mut self, index: Int):
        """Hang a node off the root as its newest child."""
        var last = self._nodes[0].last
        if last < 0:
            self._nodes[0].first = index
        else:
            self._nodes[last].next = index
        self._nodes[0].last = index
        self._nodes[0].count += 1

    def _remove(mut self, key: StringSpan):
        """Unhook a member by name, leaving its nodes in the arena.

        The nodes are left behind rather than compacted out, because compacting
        means renumbering every index in the document and the only thing it
        buys is memory that a builder holds for a few microseconds. Nothing can
        reach an unhooked node, so nothing can see it.
        """
        var wanted = key.as_bytes()
        var previous = -1
        var at = self._nodes[0].first
        while at >= 0:
            var next = self._nodes[at].next
            var matches = False
            if self._nodes[at].key_length == wanted.__len__():
                var start = self._nodes[at].key_start
                var name = Span(self._text)[
                    start : start + self._nodes[at].key_length
                ]
                matches = name == wanted
            if matches:
                if previous < 0:
                    self._nodes[0].first = next
                else:
                    self._nodes[previous].next = next
                if self._nodes[0].last == at:
                    self._nodes[0].last = previous
                self._nodes[0].count -= 1
                self._nodes[at].next = -1
            else:
                previous = at
            at = next


def kind_name(kind: Int) -> StaticString:
    """What to call a kind in an error message, in the words a user would use.
    """
    if kind == KIND_NULL:
        return "null"
    if kind == KIND_BOOL:
        return "a boolean"
    if kind == KIND_NUMBER:
        return "a number"
    if kind == KIND_STRING:
        return "a string"
    if kind == KIND_ARRAY:
        return "an array"
    if kind == KIND_OBJECT:
        return "an object"
    return "something unknown"


def _name_list(names: List[String]) -> String:
    """The keys an object does have, for the error when it lacks the one asked
    for. Truncated, because an object with four hundred keys would otherwise
    produce an error message nobody reads."""
    comptime LIMIT = 12
    if len(names) == 0:
        return String("nothing, it is empty")
    var out = String()
    var shown = min(len(names), LIMIT)
    for i in range(shown):
        if i > 0:
            out += ", "
        out += String("'", names[i], "'")
    if len(names) > shown:
        out += String(" and ", len(names) - shown, " more")
    return out^


def parse_json[o: ImmOrigin](source: Span[UInt8, o]) raises -> Json:
    """Parse one JSON document out of `source`.

    Everything after the value has to be whitespace. A parser that stopped at
    the end of the first value and ignored the rest would accept two documents
    concatenated, and then this client and whatever produced the body would
    disagree about what was sent.
    """
    var doc = Json()
    doc._nodes.clear()
    var n = source.__len__()
    var at = _skip_space(source, 0)
    if at >= n:
        raise _bad(source, at, String("the body is empty"))

    var stack = List[Int]()
    while True:
        # Inside an object a name and a colon come before every value.
        var key_start = 0
        var key_length = -1
        if (
            len(stack) > 0
            and doc._nodes[stack[len(stack) - 1]].kind == KIND_OBJECT
        ):
            at = _skip_space(source, at)
            if at >= n or source[at] != _QUOTE:
                raise _bad(source, at, String("expected a quoted member name"))
            var read = _read_string(doc, source, at)
            key_start = read[0]
            key_length = read[1]
            at = read[2]
            at = _skip_space(source, at)
            if at >= n or source[at] != _COLON:
                raise _bad(
                    source, at, String("expected ':' after the member name")
                )
            at += 1

        at = _skip_space(source, at)
        if at >= n:
            raise _bad(source, at, String("expected a value"))

        var parent = stack[len(stack) - 1] if len(stack) > 0 else -1
        var byte = source[at]

        if byte == _LBRACE or byte == _LBRACKET:
            var kind = KIND_OBJECT if byte == _LBRACE else KIND_ARRAY
            var index = _add(doc, parent, kind, key_start, key_length)
            at = _skip_space(source, at + 1)
            var closer = _RBRACE if kind == KIND_OBJECT else _RBRACKET
            if at < n and source[at] == closer:
                at += 1
            else:
                stack.append(index)
                if len(stack) > MAX_DEPTH:
                    raise _bad(
                        source,
                        at,
                        String(
                            "nested more than ",
                            MAX_DEPTH,
                            (
                                " deep. This is a limit rather than a budget: a"
                                " parser without one can be made to exhaust the"
                                " machine stack by a body that is nothing but"
                                " brackets."
                            ),
                        ),
                    )
                continue
        else:
            at = _read_scalar(doc, source, at, parent, key_start, key_length)

        # A value finished. Close every container it was the last member of.
        while True:
            if len(stack) == 0:
                at = _skip_space(source, at)
                if at != n:
                    raise _bad(
                        source,
                        at,
                        String(
                            "there is more here than one JSON value. Everything"
                            " after the first one has to be whitespace."
                        ),
                    )
                doc._depth = _depth_of(doc)
                return doc^
            var top = stack[len(stack) - 1]
            at = _skip_space(source, at)
            if at >= n:
                raise _bad(
                    source,
                    at,
                    String(
                        "the body ends before ",
                        kind_name(doc._nodes[top].kind),
                        " is closed",
                    ),
                )
            var here = source[at]
            if here == _COMMA:
                at += 1
                break
            var closer = (
                _RBRACE if doc._nodes[top].kind == KIND_OBJECT else _RBRACKET
            )
            if here == closer:
                at += 1
                _ = stack.pop()
                continue
            raise _bad(
                source,
                at,
                String("expected ',' or '", chr(Int(closer)), "'"),
            )


def _add(
    mut doc: Json, parent: Int, kind: Int, key_start: Int, key_length: Int
) -> Int:
    """Append a node and hang it off `parent`, which is -1 for the root."""
    var node = _blank(kind)
    node.key_start = key_start
    node.key_length = key_length
    var index = len(doc._nodes)
    doc._nodes.append(node)
    if parent >= 0:
        var last = doc._nodes[parent].last
        if last < 0:
            doc._nodes[parent].first = index
        else:
            doc._nodes[last].next = index
        doc._nodes[parent].last = index
        doc._nodes[parent].count += 1
    return index


def _read_scalar[
    o: ImmOrigin
](
    mut doc: Json,
    source: Span[UInt8, o],
    at: Int,
    parent: Int,
    key_start: Int,
    key_length: Int,
) raises -> Int:
    """One string, number, `true`, `false` or `null`.

    Returns the position just past it. The node it added is the last one in the
    arena, which is the only thing the caller needs to know about it.
    """
    var n = source.__len__()
    var byte = source[at]

    if byte == _QUOTE:
        var read = _read_string(doc, source, at)
        var index = _add(doc, parent, KIND_STRING, key_start, key_length)
        doc._nodes[index].text_start = read[0]
        doc._nodes[index].text_length = read[1]
        return read[2]

    if byte == _MINUS or (byte >= _ZERO and byte <= _NINE):
        var end = _scan_number(source, at)
        var index = _add(doc, parent, KIND_NUMBER, key_start, key_length)
        doc._nodes[index].text_start = len(doc._text)
        doc._nodes[index].text_length = end - at
        doc._text.extend(source[at:end])
        return end

    if _matches(source, at, "true") or _matches(source, at, "false"):
        var truth = byte == UInt8(ord("t"))
        var index = _add(doc, parent, KIND_BOOL, key_start, key_length)
        doc._nodes[index].truth = truth
        return at + (4 if truth else 5)

    if _matches(source, at, "null"):
        _ = _add(doc, parent, KIND_NULL, key_start, key_length)
        return at + 4

    # The three things people most often try that are not JSON, each named so
    # the reader is not left comparing their body against a grammar.
    if byte == UInt8(ord("'")):
        raise _bad(
            source,
            at,
            String("strings have to be double quoted in JSON"),
        )
    if _matches(source, at, "NaN") or _matches(source, at, "Infinity"):
        raise _bad(
            source,
            at,
            String(
                "NaN and Infinity are not JSON. Python writes them by default"
                " and most other parsers refuse them."
            ),
        )
    if byte == UInt8(ord("/")) and at + 1 < n:
        raise _bad(source, at, String("JSON has no comments"))
    raise _bad(source, at, String("expected a value"))


def _read_string[
    o: ImmOrigin
](mut doc: Json, source: Span[UInt8, o], at: Int) raises -> Tuple[
    Int, Int, Int
]:
    """Decode one quoted string into the text arena.

    Returns where it landed, how long it is, and the position just past the
    closing quote. `at` is the opening quote.
    """
    var n = source.__len__()
    var start = len(doc._text)
    var pos = at + 1
    while True:
        if pos >= n:
            raise _bad(source, pos, String("the body ends inside a string"))
        var byte = source[pos]
        if byte == _QUOTE:
            return (start, len(doc._text) - start, pos + 1)
        if byte < 0x20:
            raise _bad(
                source,
                pos,
                String(
                    (
                        "a control byte inside a string has to be escaped. This"
                        " one is \\u"
                    ),
                    _hex4(UInt32(byte)),
                    ".",
                ),
            )
        if byte == _BACKSLASH:
            pos = _read_escape(doc, source, pos)
            continue
        var width = utf8_length(source, pos)
        if width == 0:
            raise _bad(
                source,
                pos,
                String(
                    "the body is not valid UTF-8 here. A body that is not the"
                    " encoding it claims has already been misread by whatever"
                    " produced it."
                ),
            )
        doc._text.extend(source[pos : pos + width])
        pos += width


def _read_escape[
    o: ImmOrigin
](mut doc: Json, source: Span[UInt8, o], at: Int) raises -> Int:
    """One backslash escape. `at` is the backslash. Returns the position after.
    """
    var n = source.__len__()
    if at + 1 >= n:
        raise _bad(source, at, String("the body ends after a backslash"))
    var what = source[at + 1]
    if what == _QUOTE or what == _BACKSLASH or what == _SLASH:
        doc._text.append(what)
        return at + 2
    if what == UInt8(ord("b")):
        doc._text.append(0x08)
        return at + 2
    if what == UInt8(ord("f")):
        doc._text.append(0x0C)
        return at + 2
    if what == UInt8(ord("n")):
        doc._text.append(0x0A)
        return at + 2
    if what == UInt8(ord("r")):
        doc._text.append(0x0D)
        return at + 2
    if what == UInt8(ord("t")):
        doc._text.append(0x09)
        return at + 2
    if what != UInt8(ord("u")):
        raise _bad(
            source,
            at,
            String(
                "'\\",
                chr(Int(what)),
                (
                    "' is not an escape JSON has. The whole set is \\\" \\\\"
                    " \\/ \\b \\f \\n \\r \\t and \\u."
                ),
            ),
        )

    var first = _read_hex4(source, at + 2)
    if first < 0xD800 or first > 0xDFFF:
        append_codepoint(doc._text, first)
        return at + 6

    # A surrogate. Only a high one followed by a low one means anything, and
    # neither half has a UTF-8 encoding on its own, so a lone one is an error
    # rather than a replacement character. Inventing a character here would
    # hand the caller text that is not what the server sent.
    if first >= 0xDC00:
        raise _bad(
            source,
            at,
            String(
                "\\u",
                _hex4(first),
                (
                    " is the second half of a surrogate pair with no first"
                    " half. It has no UTF-8 encoding on its own."
                ),
            ),
        )
    if (
        at + 11 >= n
        or source[at + 6] != _BACKSLASH
        or source[at + 7] != UInt8(ord("u"))
    ):
        raise _bad(
            source,
            at,
            String(
                "\\u",
                _hex4(first),
                (
                    " is the first half of a surrogate pair and has to be"
                    " followed by the second half. It has no UTF-8 encoding on"
                    " its own."
                ),
            ),
        )
    var second = _read_hex4(source, at + 8)
    if second < 0xDC00 or second > 0xDFFF:
        raise _bad(
            source,
            at + 6,
            String(
                "\\u",
                _hex4(first),
                (
                    " has to be followed by a second half in the range \\uDC00"
                    " to \\uDFFF, not \\u"
                ),
                _hex4(second),
                ".",
            ),
        )
    var point = UInt32(0x10000) + ((first - 0xD800) << 10) + (second - 0xDC00)
    append_codepoint(doc._text, point)
    return at + 12


def _read_hex4[o: ImmOrigin](source: Span[UInt8, o], at: Int) raises -> UInt32:
    if at + 4 > source.__len__():
        raise _bad(
            source, at, String("a \\u escape needs four hexadecimal digits")
        )
    var out = UInt32(0)
    for i in range(at, at + 4):
        var digit = _hex_value(source[i])
        if digit < 0:
            raise _bad(
                source,
                i,
                String(
                    "a \\u escape needs four hexadecimal digits, and '",
                    chr(Int(source[i])),
                    "' is not one",
                ),
            )
        out = (out << 4) | UInt32(digit)
    return out


def _hex_value(byte: UInt8) -> Int:
    if byte >= _ZERO and byte <= _NINE:
        return Int(byte - _ZERO)
    if byte >= UInt8(ord("a")) and byte <= UInt8(ord("f")):
        return Int(byte - UInt8(ord("a"))) + 10
    if byte >= UInt8(ord("A")) and byte <= UInt8(ord("F")):
        return Int(byte - UInt8(ord("A"))) + 10
    return -1


def _hex4(value: UInt32) -> String:
    """Four hexadecimal digits, upper case and always four wide.

    Written by hand rather than through `hex`, which drops leading zeros and
    would turn a tab into `\\u9`, which is not an escape any parser reads.
    """
    comptime DIGITS = StaticString("0123456789ABCDEF")
    var out = String()
    for shift in range(12, -1, -4):
        var nibble = Int((value >> UInt32(shift)) & 0xF)
        # Sound because the index is a nibble masked to 0 through 15 and the
        # table is sixteen ASCII bytes, so the slice is in bounds and is
        # always one character of valid UTF-8.
        out += StringSpan(
            unsafe_from_utf8=DIGITS.as_bytes()[nibble : nibble + 1]
        )
    return out^


def _scan_number[o: ImmOrigin](source: Span[UInt8, o], at: Int) raises -> Int:
    """Check the number grammar and return the position after it.

    Strict on purpose. `01` and `+1` and `1.` and `.5` are all things some
    parser somewhere accepts, and each one is a place where this client and the
    service it is talking to would read the same bytes as different numbers.
    """
    var n = source.__len__()
    var pos = at
    if pos < n and source[pos] == _MINUS:
        pos += 1
    if pos >= n or not is_digit(source[pos]):
        raise _bad(source, at, String("a number needs a digit after the minus"))
    if source[pos] == _ZERO:
        pos += 1
        if pos < n and is_digit(source[pos]):
            raise _bad(
                source,
                at,
                String(
                    "a number cannot have a leading zero. Some parsers read '0",
                    chr(Int(source[pos])),
                    "' as octal and JSON has no octal.",
                ),
            )
    else:
        while pos < n and is_digit(source[pos]):
            pos += 1

    if pos < n and source[pos] == _DOT:
        pos += 1
        if pos >= n or not is_digit(source[pos]):
            raise _bad(
                source, at, String("a number needs a digit after the point")
            )
        while pos < n and is_digit(source[pos]):
            pos += 1

    if pos < n and (source[pos] | 0x20) == UInt8(ord("e")):
        pos += 1
        if pos < n and (source[pos] == _PLUS or source[pos] == _MINUS):
            pos += 1
        if pos >= n or not is_digit(source[pos]):
            raise _bad(
                source, at, String("a number needs a digit in its exponent")
            )
        while pos < n and is_digit(source[pos]):
            pos += 1
    return pos


def _parse_int[o: ImmOrigin](text: Span[UInt8, o]) raises -> Int:
    """A JSON number as an `Int`, or an error saying why it is not one.

    The digits are read directly rather than going through a `Float64`, because
    every integer above 2^53 comes back off a double as a different number and
    an id is exactly the kind of value that gets that large.
    """
    var negative = text.__len__() > 0 and text[0] == _MINUS
    var start = 1 if negative else 0
    var total = 0
    for i in range(start, text.__len__()):
        var byte = text[i]
        if not is_digit(byte):
            raise new_error(
                ErrorKind.INVALID_ARGUMENT,
                String(
                    "the number ",
                    _quote(text),
                    " is not a whole number",
                ),
            )
        var digit = Int(byte - _ZERO)
        if total > (Int.MAX - digit) // 10:
            raise new_error(
                ErrorKind.INVALID_ARGUMENT,
                String(
                    "the number ",
                    _quote(text),
                    (
                        " does not fit in an Int. Read it with as_float if"
                        " losing precision is acceptable."
                    ),
                ),
            )
        total = total * 10 + digit
    return -total if negative else total


def _matches[
    o: ImmOrigin
](source: Span[UInt8, o], at: Int, word: StaticString) -> Bool:
    var bytes = word.as_bytes()
    if at + bytes.__len__() > source.__len__():
        return False
    for i in range(bytes.__len__()):
        if source[at + i] != bytes[i]:
            return False
    return True


def _skip_space[o: ImmOrigin](source: Span[UInt8, o], at: Int) -> Int:
    """Past space, tab, carriage return and line feed, which is the whole of
    the whitespace JSON allows. A vertical tab or a form feed is not
    whitespace here, and neither is anything Unicode calls a space."""
    var pos = at
    var n = source.__len__()
    while pos < n:
        var byte = source[pos]
        if byte == 0x20 or byte == 0x09 or byte == 0x0A or byte == 0x0D:
            pos += 1
        else:
            return pos
    return pos


def _depth_of(doc: Json) -> Int:
    """How deep the finished document nests.

    Computed once at the end rather than tracked during parsing, because the
    parser already refuses anything past `MAX_DEPTH` and this only has to be
    right enough for the builder to keep refusing afterwards.
    """
    var deepest = 1
    var depth = List[Int](length=len(doc._nodes), fill=1)
    for i in range(len(doc._nodes)):
        var at = doc._nodes[i].first
        while at >= 0:
            depth[at] = depth[i] + 1
            if depth[at] > deepest:
                deepest = depth[at]
            at = doc._nodes[at].next
    return deepest


def _bad[o: ImmOrigin](source: Span[UInt8, o], at: Int, why: String) -> Error:
    """A parse failure that says where it happened and shows the bytes.

    The excerpt is escaped and length limited by `_quote`, because a body is
    attacker controlled and pasting it raw into an error message is its own
    small vulnerability.

    It does not say where the bytes came from, because it does not know. The
    same parser reads a response and reads a `--json` body typed at a command
    line, and a message that named the response was telling somebody who had
    just made a typo about a response they never received.
    """
    var line = 1
    var column = 1
    var stop = min(at, source.__len__())
    for i in range(stop):
        if source[i] == 0x0A:
            line += 1
            column = 1
        else:
            column += 1
    var start = max(0, at - 16)
    var stop_at = min(source.__len__(), at + 16)
    return new_error(
        ErrorKind.DECODING_ERROR,
        String(
            "invalid JSON at line ",
            line,
            " column ",
            column,
            ": ",
            why,
            " Near: ",
            _quote(source[start:stop_at]),
        ),
    )


def _write_node[
    W: Writer, no: ImmOrigin, to: ImmOrigin
](mut writer: W, nodes: Span[_Node, no], text: Span[UInt8, to], index: Int,):
    """Serialize one value and everything under it.

    A plain recursion, which is safe here in a way it would not be in the
    parser: every document has been through `MAX_DEPTH`, whether it was parsed
    or built, so this cannot recurse two hundred deep no matter what it is
    handed.
    """
    ref node = nodes[index]
    if node.kind == KIND_NULL:
        writer.write("null")
        return
    if node.kind == KIND_BOOL:
        writer.write("true" if node.truth else "false")
        return
    if node.kind == KIND_NUMBER:
        writer.write(
            StringSpan(
                unsafe_from_utf8=text[
                    node.text_start : node.text_start + node.text_length
                ]
            )
        )
        return
    if node.kind == KIND_STRING:
        _write_string(
            writer,
            text[node.text_start : node.text_start + node.text_length],
        )
        return

    var object = node.kind == KIND_OBJECT
    writer.write("{" if object else "[")
    var at = node.first
    var first = True
    while at >= 0:
        if not first:
            writer.write(",")
        first = False
        if object:
            ref child = nodes[at]
            _write_string(
                writer,
                text[child.key_start : child.key_start + child.key_length],
            )
            writer.write(":")
        _write_node(writer, nodes, text, at)
        at = nodes[at].next
    writer.write("}" if object else "]")


def _write_string[
    W: Writer, o: ImmOrigin
](mut writer: W, bytes: Span[UInt8, o]):
    """One string, quoted and escaped.

    Only what has to be escaped is escaped. Non-ASCII goes out as the UTF-8 it
    already is rather than as `\\u` escapes, which is `ensure_ascii=False` in
    Python's terms and is what every modern service expects. A solidus is not
    escaped either: JSON allows `\\/` and nothing requires it, and escaping it
    only ever made HTML embedding slightly safer in a way that is not this
    library's problem.
    """
    writer.write('"')
    for i in range(bytes.__len__()):
        var byte = bytes[i]
        if byte == _QUOTE:
            writer.write('\\"')
        elif byte == _BACKSLASH:
            writer.write("\\\\")
        elif byte == 0x08:
            writer.write("\\b")
        elif byte == 0x0C:
            writer.write("\\f")
        elif byte == 0x0A:
            writer.write("\\n")
        elif byte == 0x0D:
            writer.write("\\r")
        elif byte == 0x09:
            writer.write("\\t")
        elif byte < 0x20:
            writer.write("\\u", _hex4(UInt32(byte)))
        else:
            # One byte at a time, including the middle of a multi-byte
            # character. The bytes are already valid UTF-8 and go out in order,
            # so splitting a character across two writes changes nothing about
            # what arrives.
            writer.write(StringSpan(unsafe_from_utf8=bytes[i : i + 1]))
    writer.write('"')
