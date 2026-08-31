"""Reading the vendored test corpora.

The files under tests/data are checked in and their digests are pinned, so a test
that reads one is reading known bytes rather than whatever a server felt like
serving. `pixi run vendor-check` is what enforces that; this only opens the file.

Paths are relative to the repository root because that is where the runner
starts the compiled suite, and a corpus that cannot be opened raises rather than
being treated as an empty file. A silently empty corpus is a suite that passes
without checking anything, which is worse than a suite that fails.
"""


def read_corpus(name: StringSpan) raises -> String:
    var handle = open(String("tests/data/", name), "r")
    var text = handle.read()
    handle.close()
    if text.byte_length() == 0:
        raise Error(
            String(
                "tests/data/",
                name,
                " is empty. Run `python tools/vendor/fetch.py --update`.",
            )
        )
    return text^


def quoted_fields(line: StringSpan) raises -> List[String]:
    """Every single quoted run in `line`, in order.

    The corpora that are JavaScript call sites rather than data files are read
    this way. It is deliberately not a parser: the files use one quoting style
    with no escapes, and pulling the arguments out by hand keeps the harness
    small enough to be obviously right.
    """
    var out = List[String]()
    var bytes = line.as_bytes()
    var quote = UInt8(ord("'"))
    var i = 0
    while i < bytes.__len__():
        if bytes[i] != quote:
            i += 1
            continue
        var start = i + 1
        var end = start
        while end < bytes.__len__() and bytes[end] != quote:
            end += 1
        if end >= bytes.__len__():
            break
        out.append(String(StringSpan(from_utf8=bytes[start:end])))
        i = end + 1
    return out^
