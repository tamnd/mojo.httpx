"""Public Suffix List lookups.

The list says which domain suffixes anyone may register a name under. That
matters here for one reason: a `Set-Cookie` carrying `Domain=co.uk` would
otherwise apply to every site registered under it, so a page on one site could
set or overwrite a cookie belonging to another. Rejecting those is a security
control, and it is the piece httpx2 gets from the standard library and we do not
have.

The rules live in `_psl_data.mojo` as one sorted, newline separated blob, and a
lookup binary searches it and walks back to the nearest newline. No offset table,
so there is nothing beside the data that can disagree with it, and no allocation
anywhere on the path: the two derived forms a lookup needs, the exception rule
`!name` and the wildcard rule `*.name`, are searched for by comparing a prefix
and a body separately rather than by building the joined string.

Everything here takes a host in the form it is compared in: lower case, A-label,
no trailing dot. `httpx/_util/idna.mojo` produces exactly that.
"""

from httpx._bytes import to_lower
from httpx._util._psl_data import PSL_RULE_COUNT, PSL_RULES, PSL_SOURCE_SHA256

comptime _NEWLINE = UInt8(0x0A)
comptime _DOT = UInt8(ord("."))


def _compare_line[
    l: ImmOrigin, b: ImmOrigin
](line: Span[UInt8, l], prefix: StaticString, body: Span[UInt8, b]) -> Int:
    """Order one rule against `prefix + body`, without joining the two.

    Negative when the rule sorts first, positive when it sorts last, zero when
    they are the same. The body is lowercased as it is read, because the table is
    lower case and a host that arrives otherwise should still find its rule
    rather than silently miss and be treated as registrable.
    """
    var head = prefix.as_bytes()
    var total = head.__len__() + body.__len__()
    var shared = min(line.__len__(), total)
    for i in range(shared):
        var want: UInt8
        if i < head.__len__():
            want = head[i]
        else:
            want = to_lower(body[i - head.__len__()])
        if line[i] != want:
            if line[i] < want:
                return -1
            return 1
    if line.__len__() == total:
        return 0
    if line.__len__() < total:
        return -1
    return 1


def _present[b: ImmOrigin](prefix: StaticString, body: Span[UInt8, b]) -> Bool:
    """True when `prefix + body` is one of the rules.

    The search space is byte offsets rather than rule numbers, so each step lands
    somewhere inside a rule and walks back to the newline before it. Both bounds
    move strictly on every iteration, which is what makes it terminate: a step
    that goes right moves the low bound past the end of the line it just read,
    and a step that goes left moves the high bound back to that line's start.
    """
    if body.__len__() == 0:
        return False
    var data = PSL_RULES.as_bytes()
    var low = 0
    var high = data.__len__()
    while low < high:
        var middle = (low + high) // 2
        var start = middle
        while start > 0 and data[start - 1] != _NEWLINE:
            start -= 1
        var end = start
        while end < data.__len__() and data[end] != _NEWLINE:
            end += 1
        var order = _compare_line(data[start:end], prefix, body)
        if order == 0:
            return True
        if order < 0:
            low = end + 1
        else:
            high = start
    return False


def _label_starts[o: ImmOrigin](host: Span[UInt8, o]) -> List[Int]:
    """Where each label of `host` begins, leftmost first."""
    var starts = List[Int]()
    starts.append(0)
    for i in range(host.__len__()):
        if host[i] == _DOT:
            starts.append(i + 1)
    return starts^


def _has_empty_label[o: ImmOrigin](host: Span[UInt8, o]) -> Bool:
    if host.__len__() == 0:
        return True
    if host[0] == _DOT or host[host.__len__() - 1] == _DOT:
        return True
    for i in range(1, host.__len__()):
        if host[i] == _DOT and host[i - 1] == _DOT:
            return True
    return False


def public_suffix_start[o: ImmOrigin](host: Span[UInt8, o]) -> Int:
    """The byte offset where the public suffix of `host` begins.

    This is the algorithm from the list's own definition, which is worth
    following literally because the two rule kinds that make it non obvious are
    both live in the real list. A wildcard rule `*.ck` makes every name directly
    under `ck` a suffix of its own. An exception rule `!www.ck` pulls one name
    back out of that. And a host that matches nothing falls to the implicit rule
    `*`, meaning its last label is the suffix, which is what keeps an unknown or
    made up top level domain from looking registrable.

    Returns 0 when the whole host is a public suffix, and `host.__len__()` for an
    empty host so that callers get an offset they can slice with either way.
    """
    if host.__len__() == 0:
        return 0
    var starts = _label_starts(host)
    var count = len(starts)
    for i in range(count):
        var body = host[starts[i] : host.__len__()]
        if _present("!", body):
            # The exception cancels the rule that would have matched, and the
            # prevailing rule becomes that one without its leftmost label.
            if i + 1 < count:
                return starts[i + 1]
            return starts[i]
        if _present("", body):
            return starts[i]
        if i + 1 < count:
            var rest = host[starts[i + 1] : host.__len__()]
            if _present("*.", rest):
                return starts[i]
    return starts[count - 1]


def is_public_suffix[o: ImmOrigin](host: Span[UInt8, o]) -> Bool:
    """True when nobody owns `host` itself, only names under it.

    A `Set-Cookie` whose `Domain` is one of these is dropped, unless it is
    exactly the host that sent it. That exception matters: a site that really is
    at a public suffix, which happens, can still set a cookie for itself.
    """
    if host.__len__() == 0:
        return False
    return public_suffix_start(host) == 0


def registrable_domain[o: ImmOrigin](host: Span[UInt8, o]) -> Span[UInt8, o]:
    """The public suffix plus the one label to its left, or empty.

    Empty when `host` is itself a public suffix, because then there is no
    registrable name to speak of. This is the boundary two hosts have to share to
    count as the same site.

    Also empty when any label of `host` is empty, which covers a leading dot, a
    trailing dot and a doubled dot. None of those is a hostname, and answering
    for them would mean deciding that `.com` is registrable, which is exactly the
    answer the public suffix check exists to prevent. A caller holding a fully
    qualified name with its root dot strips that dot first.
    """
    if _has_empty_label(host):
        return host[0:0]
    var start = public_suffix_start(host)
    if start == 0:
        return host[0:0]
    var previous = 0
    for i in range(start - 1):
        if host[i] == _DOT:
            previous = i + 1
    return host[previous : host.__len__()]


def rule_count() -> Int:
    """How many rules the embedded table holds.

    Exposed so a test can assert the table was generated at all. A lookup against
    an empty table answers no to everything, which reads as a working cookie jar
    with the public suffix check quietly switched off.
    """
    return PSL_RULE_COUNT


def source_digest() -> StaticString:
    """The SHA-256 of the list the table was generated from."""
    return PSL_SOURCE_SHA256
