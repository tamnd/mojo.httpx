"""Tests for the pool's resource bounds.

Small type, but the arithmetic in `keepalive_allowance` is the sort that reads
as obviously right and is off by one, so every combination of the two limits
being set, unset and in conflict has a case here.
"""

from std.testing import assert_equal, assert_true

from httpx._exceptions import is_invalid_argument
from httpx._pool.limits import (
    DEFAULT_KEEPALIVE_EXPIRY_SECONDS,
    DEFAULT_MAX_CONNECTIONS,
    DEFAULT_MAX_KEEPALIVE_CONNECTIONS,
    Limits,
)


def _rejected(
    max_connections: Optional[Int],
    max_keepalive: Optional[Int],
    expiry: Optional[Float64],
) raises:
    var raised = False
    try:
        _ = Limits(max_connections, max_keepalive, expiry)
    except e:
        raised = True
        assert_true(is_invalid_argument(e))
    assert_true(raised)


def test_the_defaults_are_the_httpx_defaults() raises:
    var limits = Limits()
    assert_equal(limits.max_connections.value(), DEFAULT_MAX_CONNECTIONS)
    assert_equal(
        limits.max_keepalive_connections.value(),
        DEFAULT_MAX_KEEPALIVE_CONNECTIONS,
    )
    assert_equal(
        limits.keepalive_expiry.value(), DEFAULT_KEEPALIVE_EXPIRY_SECONDS
    )


def test_the_default_keepalive_allowance_is_the_keepalive_limit() raises:
    assert_equal(
        Limits().keepalive_allowance(), DEFAULT_MAX_KEEPALIVE_CONNECTIONS
    )


def test_no_limits_at_all_gives_an_unbounded_allowance() raises:
    assert_equal(Limits.unlimited().keepalive_allowance(), -1)


def test_a_keepalive_limit_larger_than_the_total_is_capped() raises:
    # Two numbers that say different things, and only the smaller one can
    # actually be honoured. Without the cap the pool would try to retain more
    # connections than it is allowed to have.
    var limits = Limits(5, 50, 5.0)
    assert_equal(limits.keepalive_allowance(), 5)


def test_no_keepalive_limit_still_respects_the_total() raises:
    var limits = Limits(7, None, 5.0)
    assert_equal(limits.keepalive_allowance(), 7)


def test_a_keepalive_limit_with_no_total_stands_on_its_own() raises:
    var limits = Limits(None, 3, 5.0)
    assert_equal(limits.keepalive_allowance(), 3)


def test_zero_keepalive_connections_means_no_reuse() raises:
    # A real setting, not a mistake. It is how a caller asks for a fresh
    # connection every time, which some proxies and some load balancers need.
    var limits = Limits(10, 0, 5.0)
    assert_equal(limits.keepalive_allowance(), 0)


def test_a_pool_that_can_never_connect_is_rejected() raises:
    _rejected(0, 0, 5.0)


def test_a_negative_connection_limit_is_rejected() raises:
    _rejected(-1, 0, 5.0)


def test_a_negative_keepalive_limit_is_rejected() raises:
    _rejected(10, -1, 5.0)


def test_a_negative_expiry_is_rejected() raises:
    _rejected(10, 5, -1.0)


def test_a_zero_expiry_is_allowed() raises:
    # It means never reuse an idle connection, which is a different thing from
    # never keeping one, and both are worth being able to ask for.
    var limits = Limits(10, 5, 0.0)
    assert_equal(limits.keepalive_expiry.value(), 0.0)


def test_limits_print_with_every_field_named() raises:
    var limits = Limits(10, 5, 2.5)
    var text = String(limits)
    assert_true("max_connections=10" in text)
    assert_true("max_keepalive_connections=5" in text)
    assert_true("keepalive_expiry=2.5" in text)


def test_unlimited_prints_as_none_rather_than_as_a_number() raises:
    var text = String(Limits.unlimited())
    assert_true("max_connections=None" in text)
    assert_true("keepalive_expiry=None" in text)
