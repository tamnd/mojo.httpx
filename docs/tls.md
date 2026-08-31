# TLS

`https://` URLs work with no configuration. This page is for the cases where the defaults are not what you want, and for reading the errors when a handshake fails.

## The defaults

```mojo
import httpx

def main() raises:
    var r = httpx.get("https://example.com/")
    print(r.status_code)
```

That connection verifies the server's certificate chain, checks the hostname against the certificate, sends SNI, offers ALPN, and refuses anything below TLS 1.2. None of it is opt in. A client that only encrypts when asked is a client that eventually ships unencrypted, so verification is on and turning it off takes a deliberate line of code.

| Setting | Default | Why |
| --- | --- | --- |
| Verification | on | An unverified TLS connection is encrypted to whoever answered, which is not the same as being encrypted to the server you asked for |
| Hostname check | on, done by OpenSSL | Doing it ourselves means reimplementing RFC 6125 wildcard rules, and that is not a place to be original |
| Minimum version | TLS 1.2 | TLS 1.0 and 1.1 are deprecated by RFC 8996 |
| Maximum version | TLS 1.3 | |
| SNI | sent, except for IP literals | RFC 6066 section 3 forbids a literal address in the extension |
| ALPN | `http/1.1`, with `h2` first once HTTP/2 lands | |
| Compression | off | CRIME recovered session cookies from compressed record lengths |
| Renegotiation | off | A client has no reason to want one, and accepting them has been an attack surface twice |
| Revocation | not checked | See below |

## Where trust comes from

The search stops at the first source that produces anything, so naming a bundle gives you that bundle and not that bundle plus the system store.

1. A CA bundle or directory you named through `verify=`.
2. `SSL_CERT_FILE` and `SSL_CERT_DIR` from the environment, unless `trust_env=False`.
3. `$CONDA_PREFIX/ssl/cacert.pem`, the bundle that ships beside the Mojo toolchain. Mojo's distribution is a conda environment, so this is normally present and is the same set of anchors every other tool in that environment uses.
4. Whatever paths OpenSSL itself was compiled to look at.
5. The usual system locations, `/etc/ssl/cert.pem` on macOS and `/etc/ssl/certs/ca-certificates.crt` and friends on Linux.

Running out of sources is an error raised when the client is built. It is deliberately not a silent fallback to an empty store, because a verifying context with no anchors rejects every certificate on earth and reports each one as untrusted, which sends whoever reads that message off to look at a server that was fine.

## Using your own CA

```mojo
from httpx import Client, SSLVerify

def main() raises:
    with Client(verify=SSLVerify.from_file("/etc/corp/root.pem")) as client:
        var r = client.get("https://internal.corp/status")
        print(r.status_code)
```

`SSLVerify.from_directory` takes an OpenSSL hashed directory instead, the kind `c_rehash` produces. Both replace the system store rather than adding to it. If you need your own root and the public ones, concatenate them into one PEM file, which is what every other tool expects too.

A bundle that is not there fails when the client is built and the message names the path. That is on purpose. The alternative is a file typo showing up much later as a certificate error on an unrelated request.

## Client certificates

```mojo
from httpx import Client, ClientCert

def main() raises:
    var cert = ClientCert("/etc/corp/client.pem", "/etc/corp/client.key")
    with Client(cert=Optional(cert)) as client:
        var r = client.get("https://mtls.corp/")
        print(r.status_code)
```

Passing one path means the key is in the same file, which is what most tools produce. An encrypted key takes its password as a third argument.

```mojo
var cert = ClientCert(
    "/etc/corp/client.pem",
    "/etc/corp/client.key",
    Optional(String("hunter2")),
)
```

Everything that can go wrong with a key pair goes wrong when the client is built, not during a handshake. A missing file names the file, an encrypted key with no password says a password is missing, and a key belonging to a different certificate says so in those words. That last one matters more than it looks: the handshake failure for a mismatched pair reads as though the server rejected you, and people lose afternoons to it.

## Turning verification off

```mojo
from httpx import Client, SSLVerify

def main() raises:
    with Client(verify=SSLVerify.off()) as client:
        var r = client.get("https://192.168.1.10/")
        print(r.status_code)
```

This disables the chain check and the hostname check together. It is here because talking to your own box with a self signed certificate is a real thing people do, and a library without an escape hatch just gets patched out of the way. It is not a fix for a certificate error against a server you do not control. If the error was about an unknown issuer, the answer is to give the client that issuer with `verify=`, not to stop checking.

## Reading a failure

TLS is the failure a user is least equipped to diagnose from an error code, so these messages are longer than the rest of the library's. Each one says what was being checked, what the certificate actually said, and what would make it work.

| What you see | What it means |
| --- | --- |
| valid but not issued for `<host>` | The certificate is fine, the name is wrong. Check the address, or connect by the name on the certificate |
| expired on `<date>` | Usually the server. Occasionally a machine with the wrong clock, so check the date locally before mailing anyone |
| self-signed | Either a private CA you need to pass with `verify=`, or an interception proxy |
| unable to get local issuer | The server did not send its intermediate certificates. It is a server misconfiguration, and browsers hide it by caching intermediates from earlier sites, which is why it works in a browser and not here |
| the server closed the connection during the TLS handshake | Very often an `https://` URL pointing at a port that speaks plain HTTP |

## Revocation is not checked

A revoked certificate is accepted. That is the same answer Python's `ssl` module gives with a default context, and the same answer most non browser clients give.

Checking properly means OCSP or CRLs, which means a network request inside a network request, and a policy for what to do when that inner request fails or times out. Soft fail is what most implementations chose and it means an attacker who can block the OCSP responder can also suppress the revocation. Chrome sidesteps the whole thing with a list pushed out of band, which is not something a client library can copy. So the honest position is that this is not covered, stated here rather than implied by silence.

## Which OpenSSL

The library is loaded at runtime with `dlopen` rather than linked, so no build step and no headers are involved and the same source works against whatever the machine has. OpenSSL 3.0 or newer is required and the version is checked on load.

The search order is `$CONDA_PREFIX/lib` first, since that is where the Mojo toolchain's own copy lives, then the plain library name for the system loader to resolve, then the usual Homebrew and Linux directories. Setting `HTTPX_OPENSSL_PATH` to a full path overrides all of it.

If nothing loads, the error lists every path that was tried, because "OpenSSL not found" on a machine with four copies of OpenSSL installed is not a useful thing to be told.

## Testing

The offline half lives in `tests/unit/test_tls.mojo`: the ALPN wire encoding, the trust store search order, and every one of the key pair failure messages, using the throwaway certificates in `tests/fixtures/tls/`.

The real handshakes live in `tools/interop/badssl.mojo` and run with `pixi run badssl`. See [testing](testing.md).
