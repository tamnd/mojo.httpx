# TLS test fixtures

Throwaway keys and certificates for the tests in `tests/unit/test_tls.mojo` and `tests/unit/test_proxy.mojo`, and for the https mode of `tests/server/server.py`. None of them protects anything and none of them is used outside the test suite. They are checked in rather than generated because a test that shells out to `openssl` before it can run is a test that fails differently on every machine.

If a secret scanner flags `client.key` or `other.key`, this is why. They are 2048 bit RSA keys generated for this directory and thrown away, and rotating them is a matter of running the commands below again.

| File | What it is |
| --- | --- |
| `ca.pem` | A self signed certificate, used only as a CA bundle that loads without error |
| `client.pem` | A client certificate |
| `client.key` | The matching key, unencrypted |
| `client-encrypted.key` | The same key, AES-256 under the password `hunter2` |
| `other.key` | A different key, so that the mismatch check has something to catch |
| `server.pem` | A self signed certificate for `localhost`, which the test server presents and a test client trusts |
| `server.key` | The matching key, unencrypted |

The client fixtures expire in 2046 and `server.pem` in 2126. How they were made:

```bash
openssl req -x509 -newkey rsa:2048 -keyout ca.key -out ca.pem -days 7300 -nodes -subj "/CN=mojo.httpx test CA"
openssl req -x509 -newkey rsa:2048 -keyout client.key -out client.pem -days 7300 -nodes -subj "/CN=mojo.httpx test client"
openssl rsa -in client.key -aes256 -passout pass:hunter2 -out client-encrypted.key
openssl genrsa -out other.key 2048
rm ca.key

openssl req -x509 -newkey rsa:2048 -nodes -keyout server.key -out server.pem \
  -days 36500 -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign" \
  -addext "extendedKeyUsage=serverAuth"
```

`server.pem` is the one with real work to do, and its two unusual settings are why it works. The subject alternative names are what a hostname check reads, and a certificate with only a common name on it is one that modern OpenSSL will not match against anything. `CA:TRUE` is what lets the same file be both the leaf and the trust anchor, which is what makes `TestServer.tls_verify()` a one liner: without it OpenSSL loads the certificate into the trust store and then refuses to use it as an issuer, and every handshake fails complaining about a self signed certificate in the chain.

The alternative to checking it in was generating it when the test server starts, which needs either the `openssl` binary or a library outside the standard library on every machine the suite runs on, Windows included. A suite that fails because a tool is missing is a suite people stop trusting.

The CA key is deleted on purpose. Nothing signs anything with it, so keeping it around would only be somewhere for a future test to take a shortcut.
