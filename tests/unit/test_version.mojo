from std.testing import assert_true, assert_equal

from httpx import __version__, MOJO_MIN_VERSION


def test_version_is_set() raises:
    assert_true(__version__.byte_length() > 0)
    assert_equal(MOJO_MIN_VERSION, "1.0.0")
