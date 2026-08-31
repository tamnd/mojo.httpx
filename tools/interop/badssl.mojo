"""The badssl.com suite, one host per way of getting TLS wrong.

    pixi run badssl

Every case says whether the handshake has to succeed or fail, and the failing
ones say what the message has to mention. Asserting on the message and not only
on the refusal is deliberate: a client that rejects everything for the same
vague reason is not much better than one that accepts everything, because the
person reading the error still has no idea which of the twelve possible
problems they have.

This needs the network and depends on certificates somebody else renews, so it
is not part of `pixi run check` and is not in CI either. It runs on the fleet.
See docs/testing.md.

Two things to know before believing a failure here.

badssl.com's own certificates expire. Several of its hosts are broken in ways
its operators did not intend, and a case that starts failing is at least as
likely to be their certificate as our code, so check the host in a browser
before changing anything.

Revocation is not checked, by us or by anything else that does not go out of
its way. `revoked.badssl.com` is expected to be accepted, which is the same
answer Python's `ssl` module gives with its default context. Checking it
properly means OCSP or CRLs, which means a network request inside a network
request and a policy for what to do when that one fails. Chrome does it with a
pushed list rather than by asking, which is not something a client library can
copy.
"""

from httpx._io.connect import connect_to_host
from httpx._io.deadline import Deadline
from httpx._io.dns import Resolver
from httpx._stream.config import SSLVerify, TlsConfig
from httpx._stream.tls import TlsStream


struct Case(ImplicitlyCopyable, Movable):
    var host: String
    var port: UInt16
    var accept: Bool
    var expect: String
    """A substring the failure has to contain, or empty when any refusal will
    do. Only set where the wording is the point of the case."""

    var why: String
    """What this host is testing, printed beside the result so that a failure
    reads as a sentence rather than as a host name."""

    def __init__(
        out self,
        host: String,
        accept: Bool,
        why: String,
        expect: String = String(),
        port: UInt16 = 443,
    ):
        self.host = host.copy()
        self.port = port
        self.accept = accept
        self.expect = expect.copy()
        self.why = why.copy()


def cases() -> List[Case]:
    var out = List[Case]()

    # The ones that have to work. Without these the suite would pass on a
    # client that refused every certificate on earth.
    out.append(Case(String("badssl.com"), True, String("an ordinary server")))
    out.append(
        Case(String("sha256.badssl.com"), True, String("a SHA-256 signature"))
    )
    out.append(
        Case(String("ecc256.badssl.com"), True, String("an elliptic curve key"))
    )
    out.append(
        Case(
            String("tls-v1-2.badssl.com"),
            True,
            String("TLS 1.2, the oldest version still allowed"),
            port=1012,
        )
    )
    out.append(
        Case(
            String("revoked.badssl.com"),
            True,
            String("a revoked certificate, which nothing here checks for"),
        )
    )

    # Certificate problems. Each one has to name what is wrong with it.
    out.append(
        Case(
            String("expired.badssl.com"),
            False,
            String("an expired certificate"),
            expect=String("expired"),
        )
    )
    out.append(
        Case(
            String("wrong.host.badssl.com"),
            False,
            String("a certificate for somebody else"),
            expect=String("hostname mismatch"),
        )
    )
    out.append(
        Case(
            String("self-signed.badssl.com"),
            False,
            String("a certificate that signs itself"),
            expect=String("self-signed"),
        )
    )
    out.append(
        Case(
            String("untrusted-root.badssl.com"),
            False,
            String("a root nothing on this machine trusts"),
            expect=String("self-signed"),
        )
    )
    out.append(
        Case(
            String("incomplete-chain.badssl.com"),
            False,
            String("a server that did not send its intermediates"),
            expect=String("issuer"),
        )
    )

    # Protocol and cipher floors. These fail during the handshake rather than
    # during verification, so the message comes from OpenSSL.
    out.append(
        Case(
            String("tls-v1-0.badssl.com"),
            False,
            String("TLS 1.0, below the floor"),
            expect=String("protocol"),
            port=1010,
        )
    )
    out.append(
        Case(
            String("tls-v1-1.badssl.com"),
            False,
            String("TLS 1.1, below the floor"),
            expect=String("protocol"),
            port=1011,
        )
    )
    out.append(
        Case(String("rc4.badssl.com"), False, String("RC4, a broken cipher"))
    )
    out.append(
        Case(
            String("3des.badssl.com"),
            False,
            String("3DES, weak enough to be worth a fetch"),
        )
    )
    out.append(
        Case(
            String("null.badssl.com"),
            False,
            String("a cipher that does not encrypt"),
        )
    )
    out.append(
        Case(
            String("dh480.badssl.com"),
            False,
            String("a 480 bit Diffie-Hellman modulus"),
        )
    )
    return out^


def handshake(host_case: Case, verify: SSLVerify) raises -> String:
    """Connect and handshake, and hand back the negotiated version."""
    var config = TlsConfig()
    config.verify = verify
    var ctx = config.build()
    var resolver = Resolver()
    var tcp = connect_to_host(
        resolver, host_case.host, host_case.port, Deadline.after(20.0)
    )
    var stream = TlsStream(
        tcp^, ctx, host_case.host, verify.enabled, Deadline.after(20.0)
    )
    return stream.protocol_version()


def run(host_case: Case) -> Bool:
    """One case. True when the result was the one written down for it."""
    var label = String(host_case.host, ": ", host_case.why)
    try:
        var version = handshake(host_case, SSLVerify())
        if host_case.accept:
            print("  ok      ", label, "(", version, ")")
            return True
        print("  ACCEPTED", label, "and should not have been")
        return False
    except e:
        var message = String(e)
        if host_case.accept:
            print("  REFUSED ", label, "|", message)
            return False
        if host_case.expect != "" and host_case.expect not in message:
            print("  wrong reason for", label)
            print("    wanted to see:", host_case.expect)
            print("    got:          ", message)
            return False
        print("  ok      ", label)
        return True


def check_verification_can_be_turned_off() -> Bool:
    """The escape hatch has to work, or nobody can talk to their own test box.

    Run against an expired certificate rather than a good one, because a client
    that quietly kept verifying would still pass against a good one.
    """
    var host_case = Case(
        String("expired.badssl.com"), True, String("with verify turned off")
    )
    try:
        var version = handshake(host_case, SSLVerify.off())
        print("  ok       verify off accepts an expired certificate (", version, ")")
        return True
    except e:
        print("  FAILED   verify off still refused:", String(e))
        return False


def main() raises:
    print("badssl.com, through httpx._stream.tls")
    var failures = 0
    var all = cases()
    for i in range(len(all)):
        if not run(all[i]):
            failures += 1
    if not check_verification_can_be_turned_off():
        failures += 1

    print()
    if failures == 0:
        print(len(all) + 1, "cases, all as expected")
        return
    raise Error(
        String(
            failures,
            " of ",
            len(all) + 1,
            (
                " cases gave the wrong answer. Check the host in a browser"
                " first, because badssl.com's certificates expire."
            ),
        )
    )
