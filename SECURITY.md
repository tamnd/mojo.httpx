# Security Policy

## Supported versions

The project is pre-alpha and has not had a release yet. Once 1.0.0 ships, the latest minor release will receive security fixes. Until then, only the `main` branch is supported.

## Reporting a vulnerability

Do not open a public issue.

Use GitHub's private vulnerability reporting on this repository, under the Security tab, or report it through [github.com/tamnd/mojo.httpx/security/advisories/new](https://github.com/tamnd/mojo.httpx/security/advisories/new).

Please include a description of the issue, the steps to reproduce it, the Mojo version and platform, and what an attacker gets out of it. A proof of concept helps a lot, especially for a parser issue where the raw bytes are the whole story.

You should get an acknowledgement within three working days and an assessment within ten. If a fix is needed we will agree a disclosure date with you, and you will be credited in the advisory unless you prefer otherwise.

## What counts

This is an HTTP client, so it parses attacker controlled input on every request. The parsers are the part that matters most. In scope:

- Request smuggling through the HTTP/1.1 parser, including CL.TE, TE.CL, TE.TE, line folding and whitespace before the colon
- HTTP/2 resource exhaustion, including CONTINUATION floods, HPACK decompression bombs, rapid reset and zero window stalls
- Decompression bombs in gzip, deflate, brotli or zstd
- Credential leakage across a redirect, especially `Authorization` surviving a cross origin hop
- Cookie leakage across domains, or a cookie set on a public suffix
- Header injection through a user controlled header value
- TLS verification failures, including hostname mismatch, an accepted expired or self signed certificate, or a truncation attack without `close_notify`
- Any memory safety failure reachable from network input
- `HTTP_PROXY` picked up from a CGI environment, the httpoxy class of bug

Out of scope: anything that requires the user to pass `verify=False`, denial of service against a server rather than the client, and issues in Mojo itself or in OpenSSL rather than in how we call them.

## Hardening in the project

Every attack class listed above has an explicit test in `tests/security/`, cross referenced to the rule in the spec that defends against it. The HTTP/1.1 parser, the HPACK decoder, the URL parser and the JSON parser are fuzzed continuously and differentially against reference implementations, and a crash or a hang is a release blocker.
