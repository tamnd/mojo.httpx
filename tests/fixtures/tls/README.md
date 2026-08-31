# TLS test fixtures

Throwaway keys and certificates for the tests in `tests/unit/test_tls.mojo`. None of them protects anything and none of them is used outside the test suite. They are checked in rather than generated because a test that shells out to `openssl` before it can run is a test that fails differently on every machine.

If a secret scanner flags `client.key` or `other.key`, this is why. They are 2048 bit RSA keys generated for this directory and thrown away, and rotating them is a matter of running the commands below again.

| File | What it is |
| --- | --- |
| `ca.pem` | A self signed certificate, used only as a CA bundle that loads without error |
| `client.pem` | A client certificate |
| `client.key` | The matching key, unencrypted |
| `client-encrypted.key` | The same key, AES-256 under the password `hunter2` |
| `other.key` | A different key, so that the mismatch check has something to catch |

They expire in 2046. How they were made:

```bash
openssl req -x509 -newkey rsa:2048 -keyout ca.key -out ca.pem -days 7300 -nodes -subj "/CN=mojo.httpx test CA"
openssl req -x509 -newkey rsa:2048 -keyout client.key -out client.pem -days 7300 -nodes -subj "/CN=mojo.httpx test client"
openssl rsa -in client.key -aes256 -passout pass:hunter2 -out client-encrypted.key
openssl genrsa -out other.key 2048
rm ca.key
```

The CA key is deleted on purpose. Nothing signs anything with it, so keeping it around would only be somewhere for a future test to take a shortcut.
