"""TLS configuration, and the parts of the handshake that need no server.

Everything here runs offline. What is missing is the interesting half, which is
a real handshake against a real certificate, and that lives in
`tools/interop/badssl.mojo` because it needs the network and because a test
that fails when the wifi drops is a test people learn to ignore.

The offline half is still worth having. It covers the ALPN encoding, which is a
wire format with an easy off by one in it, the trust store search order, which
decides what a client trusts and therefore has to be spelled out rather than
observed, and the failure messages, which are the whole reason this layer got
written the way it did.
"""

from std.testing import assert_equal, assert_false, assert_true

from httpx._ffi.openssl import (
    TLS1_2_VERSION,
    TLS1_3_VERSION,
    is_available,
    library_path,
    version_text,
)
from httpx._io.deadline import Deadline
from httpx._io.socket import TcpStream, open_stream
from httpx._stream.config import ClientCert, SSLVerify, TlsConfig, alpn_wire
from httpx._stream.stream import Stream
from httpx._stream.tls import TlsStream

from tests.support.loopback import Loopback


def test_openssl_is_available_and_recent() raises:
    # If this fails, nothing else in the file can run, and the reason is the
    # machine rather than the code, so it is the first test in the file.
    assert_true(is_available())
    assert_true(version_text().startswith("OpenSSL 3."))
    assert_true(library_path().byte_length() > 0)


def test_alpn_offers_only_http1_by_default() raises:
    var wire = alpn_wire(False)
    assert_equal(len(wire), 9)
    assert_equal(Int(wire[0]), 8)
    assert_equal(String(StringSpan(from_utf8=Span(wire)[1:])), "http/1.1")


def test_alpn_offers_h2_first_when_http2_is_allowed() raises:
    # Order is preference order, and a server that supports both should be told
    # which one we would rather have.
    var wire = alpn_wire(True)
    assert_equal(len(wire), 12)
    assert_equal(Int(wire[0]), 2)
    assert_equal(String(StringSpan(from_utf8=Span(wire)[1:3])), "h2")
    assert_equal(Int(wire[3]), 8)
    assert_equal(String(StringSpan(from_utf8=Span(wire)[4:])), "http/1.1")


def test_verify_is_on_by_default() raises:
    var verify = SSLVerify()
    assert_true(verify.enabled)
    assert_false(verify.is_custom())


def test_verify_off_is_a_deliberate_thing_to_ask_for() raises:
    var verify = SSLVerify.off()
    assert_false(verify.enabled)


def test_a_named_bundle_replaces_the_system_store() raises:
    var verify = SSLVerify.from_file(String("/tmp/ca.pem"))
    assert_true(verify.enabled)
    assert_true(verify.is_custom())
    assert_equal(verify.ca_file.value(), "/tmp/ca.pem")


def test_a_client_cert_defaults_its_key_to_the_same_file() raises:
    # A combined PEM holding both is what most tools produce, so passing one
    # path has to mean the key is in there too.
    var cert = ClientCert(String("/tmp/client.pem"))
    assert_equal(cert.certfile, "/tmp/client.pem")
    assert_equal(cert.keyfile, "/tmp/client.pem")
    assert_false(cert.password.__bool__())


def test_the_default_config_is_tls_1_2_up_to_1_3() raises:
    var config = TlsConfig()
    assert_equal(config.min_version, TLS1_2_VERSION)
    assert_equal(config.max_version, TLS1_3_VERSION)
    assert_true(config.trust_env)
    assert_false(config.http2)


def test_the_default_config_builds_a_context() raises:
    # Which means the trust store was found. On a machine where it is not, this
    # is the test that says so, rather than every https request failing later.
    var config = TlsConfig()
    _ = config.build()


def test_a_context_with_verification_off_still_builds() raises:
    var config = TlsConfig()
    config.verify = SSLVerify.off()
    _ = config.build()


def test_a_ca_bundle_that_is_not_there_names_the_file() raises:
    var config = TlsConfig()
    config.verify = SSLVerify.from_file(String("/tmp/no-such-bundle-here.pem"))
    var raised = False
    try:
        _ = config.build()
    except e:
        raised = True
        assert_true("no-such-bundle-here.pem" in String(e))
    assert_true(raised)


def test_a_client_certificate_that_is_not_there_names_the_file() raises:
    var config = TlsConfig()
    config.cert = Optional(ClientCert(String("/tmp/no-such-client-cert.pem")))
    var raised = False
    try:
        _ = config.build()
    except e:
        raised = True
        assert_true("no-such-client-cert.pem" in String(e))
    assert_true(raised)


def _handshake_against(mut listener: Loopback, reply: StringSpan) raises:
    """Offer `reply` to a client hello and let the handshake fail on it.

    The listener has to be borrowed for the whole call rather than made inside
    it, because Mojo drops a value after its last use and a listener dropped
    while the client is still connecting is a connection refused instead of the
    failure being tested.
    """
    var tcp = open_stream(listener.addr, "loopback", Deadline.after(5.0))
    var config = TlsConfig()
    var ctx = config.build()
    var peer = listener.accept_within()
    if reply.byte_length() > 0:
        peer.send_text(reply)
    else:
        peer.close()
    var stream = TlsStream(
        tcp^, ctx, String("loopback"), True, Deadline.after(5.0)
    )
    _ = stream^


def test_a_plain_http_server_on_a_tls_port_says_so() raises:
    # The single most common way to get this wrong is an https URL pointing at
    # a port that speaks plain HTTP, so the message for it says what happened
    # rather than quoting an OpenSSL error code.
    var listener = Loopback()
    var raised = False
    try:
        _handshake_against(listener, "HTTP/1.1 400 Bad Request\r\n\r\n")
    except e:
        raised = True
        assert_true("TLS" in String(e))
    assert_true(raised)


def test_a_server_that_hangs_up_during_the_handshake_says_so() raises:
    var listener = Loopback()
    var raised = False
    try:
        _handshake_against(listener, "")
    except e:
        raised = True
        assert_true("TLS handshake" in String(e))
    assert_true(raised)


def _plain_stream(mut listener: Loopback) raises -> Stream:
    var tcp = open_stream(listener.addr, "loopback", Deadline.after(5.0))
    return Stream(tcp^)


def test_a_plain_stream_reports_itself_as_not_secure() raises:
    # The pool asks this before handing a connection to an https request, so a
    # wrong answer here is an unencrypted request to a URL that promised
    # otherwise.
    var listener = Loopback()
    var stream = _plain_stream(listener)
    var peer = listener.accept_within()
    assert_false(stream.is_secure())
    assert_equal(stream.alpn_protocol(), "")
    assert_equal(stream.tls_version(), "")
    assert_equal(stream.tls_cipher(), "")
    _ = peer^
    _ = stream^


comptime FIXTURES = "tests/fixtures/tls/"
"""Throwaway keys and certificates. See the README in that directory.

Relative to the repository root, because the test runner builds and runs from
there and a path found relative to the source file would need a way to ask
where the source file was.
"""


def test_a_client_certificate_and_its_key_load() raises:
    var config = TlsConfig()
    config.cert = Optional(
        ClientCert(
            String(FIXTURES, "client.pem"), String(FIXTURES, "client.key")
        )
    )
    _ = config.build()


def test_a_certificate_with_no_key_beside_it_says_so() raises:
    # `client.pem` holds only the certificate, so naming one path is wrong
    # here, and the message has to be about the key rather than about the
    # certificate that loaded fine.
    var config = TlsConfig()
    config.cert = Optional(ClientCert(String(FIXTURES, "client.pem")))
    var raised = False
    try:
        _ = config.build()
    except e:
        raised = True
        assert_true("client key" in String(e))
    assert_true(raised)


def test_an_encrypted_key_loads_when_the_password_is_given() raises:
    # The password reaches OpenSSL through the default callback's user data
    # rather than through a callback of ours, so this is the test that the
    # trick actually works.
    var config = TlsConfig()
    config.cert = Optional(
        ClientCert(
            String(FIXTURES, "client.pem"),
            String(FIXTURES, "client-encrypted.key"),
            Optional(String("hunter2")),
        )
    )
    _ = config.build()


def test_an_encrypted_key_with_no_password_says_what_is_missing() raises:
    var config = TlsConfig()
    config.cert = Optional(
        ClientCert(
            String(FIXTURES, "client.pem"),
            String(FIXTURES, "client-encrypted.key"),
        )
    )
    var raised = False
    try:
        _ = config.build()
    except e:
        raised = True
        assert_true("password" in String(e))
    assert_true(raised)


def test_an_encrypted_key_with_the_wrong_password_is_refused() raises:
    var config = TlsConfig()
    config.cert = Optional(
        ClientCert(
            String(FIXTURES, "client.pem"),
            String(FIXTURES, "client-encrypted.key"),
            Optional(String("not it")),
        )
    )
    var raised = False
    try:
        _ = config.build()
    except e:
        raised = True
        assert_true("client key" in String(e))
    assert_true(raised)


def test_a_key_that_belongs_to_another_certificate_is_caught() raises:
    # Caught while the client is being built rather than during a handshake,
    # which matters because the handshake failure for this looks like the
    # server rejected us.
    var config = TlsConfig()
    config.cert = Optional(
        ClientCert(
            String(FIXTURES, "client.pem"), String(FIXTURES, "other.key")
        )
    )
    var raised = False
    try:
        _ = config.build()
    except e:
        raised = True
        assert_true("other.key" in String(e))
        assert_true("mismatch" in String(e))
        # No password was passed and none was needed, so the message must not
        # send the reader off looking for one.
        assert_true("password" not in String(e))
    assert_true(raised)


def test_a_named_ca_bundle_loads() raises:
    var config = TlsConfig()
    config.verify = SSLVerify.from_file(String(FIXTURES, "ca.pem"))
    _ = config.build()
