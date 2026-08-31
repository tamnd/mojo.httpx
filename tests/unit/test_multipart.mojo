"""Tests for the `multipart/form-data` writer.

Most of these compare the whole body byte for byte against a literal rather than
asserting on a substring. That is on purpose. Multipart is a format where a
missing blank line or a stray `\\r\\n` produces something that one server parses
and the next one does not, and a test that only checks the filename made it in
would pass through every one of those. Comparing the whole thing means the shape
cannot drift without somebody deciding it should.

The boundary is pinned everywhere it is compared, because a random boundary and
an exact expectation cannot both exist. `render_multipart` takes the boundary
for that reason, and the tests that care about the randomness test
`generate_boundary` and `choose_boundary` directly.
"""

from std.testing import (
    assert_equal,
    assert_false,
    assert_not_equal,
    assert_true,
)

from httpx._bytes import Bytes
from httpx._content.multipart import (
    DEFAULT_FILE_TYPE,
    FileUpload,
    MultipartData,
    choose_boundary,
    escape_form_param,
    generate_boundary,
    guess_type,
    render_multipart,
)


def rendered(data: MultipartData, boundary: StringSpan) raises -> String:
    return render_multipart(data, boundary).to_string()


def escaped(name: StringSpan) raises -> String:
    return escape_form_param(name).to_string()


def bytes_of(*values: Int) -> Bytes:
    var out = Bytes()
    for value in values:
        out.append(UInt8(value))
    return out^


def test_a_body_with_nothing_in_it_is_just_the_closing_boundary() raises:
    # Legal and not useless: a POST with an empty form is a real request, and a
    # writer that produced zero bytes here would send a body a server reads as
    # truncated rather than as empty.
    var data = MultipartData()
    assert_false(data)
    assert_equal(rendered(data, "X"), "--X--\r\n")


def test_one_text_field() raises:
    var data = MultipartData()
    data.add("title", "holiday")
    assert_equal(
        rendered(data, "X"),
        (
            "--X\r\n"
            'Content-Disposition: form-data; name="title"\r\n'
            "\r\n"
            "holiday\r\n"
            "--X--\r\n"
        ),
    )


def test_a_text_field_gets_no_content_type() raises:
    # A browser does not write one for a text input, and a server that sees one
    # is entitled to treat the part as a file. Asserting the absence rather than
    # trusting the previous test to have noticed.
    var data = MultipartData()
    data.add("title", "holiday")
    assert_true("Content-Type" not in rendered(data, "X"))


def test_an_empty_field_value_is_still_a_part() raises:
    var data = MultipartData()
    data.add("note", "")
    assert_equal(
        rendered(data, "X"),
        (
            "--X\r\n"
            'Content-Disposition: form-data; name="note"\r\n'
            "\r\n"
            "\r\n"
            "--X--\r\n"
        ),
    )


def test_a_repeated_field_name_sends_both_values_in_order() raises:
    # Dropping one or reordering them changes what the application receives,
    # because a repeated name is how every checkbox group is submitted.
    var data = MultipartData()
    data.add("tag", "one")
    data.add("tag", "two")
    assert_equal(
        rendered(data, "X"),
        (
            "--X\r\n"
            'Content-Disposition: form-data; name="tag"\r\n'
            "\r\n"
            "one\r\n"
            "--X\r\n"
            'Content-Disposition: form-data; name="tag"\r\n'
            "\r\n"
            "two\r\n"
            "--X--\r\n"
        ),
    )


def test_a_file_with_a_filename_and_a_guessed_type() raises:
    var data = MultipartData()
    data.add_file(FileUpload("photo", "beach.jpg", "JPEGBYTES"))
    assert_equal(
        rendered(data, "X"),
        (
            "--X\r\n"
            'Content-Disposition: form-data; name="photo";'
            ' filename="beach.jpg"\r\n'
            "Content-Type: image/jpeg\r\n"
            "\r\n"
            "JPEGBYTES\r\n"
            "--X--\r\n"
        ),
    )


def test_an_explicit_content_type_beats_the_guess() raises:
    # The caller knows more than the extension does. A `.txt` holding CSV is a
    # real thing and the guess must not override the caller saying so.
    var data = MultipartData()
    data.add_file(FileUpload("f", "data.txt", "a,b", "text/csv"))
    assert_true("Content-Type: text/csv\r\n" in rendered(data, "X"))


def test_a_file_with_no_filename_gets_no_filename_parameter() raises:
    # Not `filename=""`. That is what a browser sends for a file input nobody
    # chose a file for, and several frameworks read it as exactly that, so
    # writing it for a caller who deliberately sent unnamed bytes loses the part.
    var data = MultipartData()
    data.add_file(FileUpload("blob", "", "raw"))
    assert_equal(
        rendered(data, "X"),
        (
            "--X\r\n"
            'Content-Disposition: form-data; name="blob"\r\n'
            "Content-Type: application/octet-stream\r\n"
            "\r\n"
            "raw\r\n"
            "--X--\r\n"
        ),
    )


def test_fields_are_written_before_files() raises:
    # The order httpx2 writes them, and the order that matters for parity. A
    # server reading a repeated name across the two groups sees a different last
    # value if these swap.
    var data = MultipartData()
    data.add_file(FileUpload("f", "a.txt", "FILE"))
    data.add("t", "TEXT")
    var body = rendered(data, "X")
    assert_true(body.find("TEXT") < body.find("FILE"))


def test_files_keep_the_order_they_were_added_in() raises:
    var data = MultipartData()
    data.add_file(FileUpload("a", "1.txt", "FIRST"))
    data.add_file(FileUpload("b", "2.txt", "SECOND"))
    var body = rendered(data, "X")
    assert_true(body.find("FIRST") < body.find("SECOND"))


def test_binary_content_survives_byte_for_byte() raises:
    # Nothing is escaped inside a part, which is the whole reason the boundary
    # has to be unguessable. A writer that mangled a nul or a lone carriage
    # return would corrupt every upload that was not text.
    var data = MultipartData()
    data.add_file(FileUpload("f", "x.bin", bytes_of(0, 13, 10, 255, 0x80)))
    var body = render_multipart(data, "X")

    var expected = Bytes(
        "--X\r\n"
        'Content-Disposition: form-data; name="f"; filename="x.bin"\r\n'
        "Content-Type: application/octet-stream\r\n"
        "\r\n"
    )
    expected.extend(bytes_of(0, 13, 10, 255, 0x80).as_span())
    expected.extend("\r\n--X--\r\n".as_bytes())

    assert_equal(len(body), len(expected))
    for i in range(len(expected)):
        assert_equal(body[i], expected[i])


def test_a_quote_in_a_filename_is_escaped() raises:
    var data = MultipartData()
    data.add_file(FileUpload("f", 'ho"me.txt', "x"))
    assert_true('filename="ho%22me.txt"' in rendered(data, "X"))


def test_a_line_ending_in_a_filename_cannot_inject_a_header() raises:
    # The attack this escaping exists for. Unescaped, the filename below closes
    # the quoted string, ends the header block and starts a body the application
    # believes it wrote.
    var data = MultipartData()
    data.add_file(
        FileUpload("f", 'x"\r\nContent-Type: text/html\r\n\r\n<script>', "safe")
    )
    var body = rendered(data, "X")
    # The terminator is what the assertion is about. The words `Content-Type:
    # text/html` are still in there, inside the quoted filename where they are
    # data. What must not exist is a line ending that turns them into a header,
    # and the escaping is what takes it away.
    assert_true("Content-Type: text/html\r\n" not in body)
    assert_true(
        'filename="x%22%0D%0AContent-Type: text/html%0D%0A%0D%0A<script>"'
        in body
    )


def test_a_line_ending_in_a_field_name_cannot_inject_a_header() raises:
    # Same attack through the other door. Field names come from application code
    # more often than filenames do, which makes them easier to forget.
    var data = MultipartData()
    data.add('a"\r\nX-Evil: yes', "v")
    var body = rendered(data, "X")
    assert_true("X-Evil: yes\r\n" not in body)
    assert_true('name="a%22%0D%0AX-Evil: yes"' in body)


def test_only_three_characters_are_escaped() raises:
    # Matching browsers exactly is the point. Escaping more would produce
    # filenames that arrive percent encoded and are stored that way, which is
    # the failure people actually hit with the stricter implementations.
    assert_equal(escaped("a b&c=d;e%f"), "a b&c=d;e%f")
    assert_equal(escaped('"'), "%22")
    assert_equal(escaped("\r"), "%0D")
    assert_equal(escaped("\n"), "%0A")
    assert_equal(escaped(""), "")


def test_a_non_ascii_filename_is_sent_as_raw_utf8() raises:
    # What browsers do. RFC 2231 would say `filename*=UTF-8''...` and is the
    # better design and is not what enough server side parsers implement.
    var data = MultipartData()
    data.add_file(FileUpload("f", "café.txt", "x"))
    assert_true('filename="café.txt"' in rendered(data, "X"))


def test_the_type_is_guessed_from_the_last_dot() raises:
    # `archive.tar.gz` is a gzip, not a tar. The first dot would say otherwise.
    assert_equal(guess_type("archive.tar.gz"), "application/gzip")
    assert_equal(guess_type("archive.tar"), "application/x-tar")


def test_guessing_ignores_the_case_of_the_extension() raises:
    assert_equal(guess_type("PHOTO.JPG"), "image/jpeg")
    assert_equal(guess_type("Notes.Md"), "text/markdown")


def test_a_few_types_that_people_actually_upload() raises:
    assert_equal(guess_type("a.txt"), "text/plain")
    assert_equal(guess_type("a.json"), "application/json")
    assert_equal(guess_type("a.pdf"), "application/pdf")
    assert_equal(guess_type("a.png"), "image/png")
    assert_equal(guess_type("a.svg"), "image/svg+xml")
    assert_equal(guess_type("a.mp4"), "video/mp4")


def test_an_unknown_or_missing_extension_falls_back() raises:
    # Unspecific rather than wrong. The receiving side may act on the type, so
    # guessing `text/plain` for an unknown extension would be worse than saying
    # nothing useful.
    assert_equal(guess_type("a.wat"), DEFAULT_FILE_TYPE)
    assert_equal(guess_type("README"), DEFAULT_FILE_TYPE)
    assert_equal(guess_type("trailing."), DEFAULT_FILE_TYPE)
    assert_equal(guess_type(".hidden"), DEFAULT_FILE_TYPE)
    assert_equal(guess_type(""), DEFAULT_FILE_TYPE)


def test_a_boundary_is_thirty_two_hexadecimal_characters() raises:
    # The shape matters as much as the entropy. Every character has to be one
    # RFC 2046 allows in a boundary, and the length has to stay under seventy.
    var boundary = generate_boundary()
    assert_equal(boundary.byte_length(), 32)
    for byte in boundary.as_bytes():
        var digit = byte >= UInt8(ord("0")) and byte <= UInt8(ord("9"))
        var letter = byte >= UInt8(ord("a")) and byte <= UInt8(ord("f"))
        assert_true(digit or letter)


def test_two_boundaries_are_not_the_same() raises:
    # A boundary that repeats is a boundary somebody who saw the first request
    # already knows, and knowing it is all it takes to forge a part. This
    # catches the whole class of mistake where the source turns out to be a
    # constant, a counter, or a clock read twice in the same instant.
    var seen = List[String]()
    for _ in range(32):
        var boundary = generate_boundary()
        for i in range(len(seen)):
            assert_not_equal(seen[i], boundary)
        seen.append(boundary^)


def test_a_chosen_boundary_does_not_appear_in_the_data() raises:
    var data = MultipartData()
    data.add("a", "some value")
    data.add_file(FileUpload("f", "a.txt", "some content"))
    var boundary = choose_boundary(data)
    assert_true(boundary not in "some value")
    assert_true(boundary not in "some content")
    assert_true(boundary not in rendered(data, "OTHER"))


def test_the_boundary_never_appears_inside_a_part() raises:
    # The property that makes the format safe, checked end to end rather than by
    # trusting the collision check on its own. The rendered body must contain the
    # boundary only where the writer put it.
    var data = MultipartData()
    data.add("a", "1")
    data.add_file(FileUpload("f", "a.txt", "content"))
    var boundary = choose_boundary(data)
    var body = rendered(data, boundary)
    var expected = 3  # two opening boundaries and the closing one
    var count = 0
    var at = body.find(boundary)
    while at >= 0:
        count += 1
        at = body.find(boundary, at + boundary.byte_length())
    assert_equal(count, expected)
