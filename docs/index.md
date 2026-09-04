# Documentation

mojo.httpx is a full featured HTTP client for Mojo, with the same API and the same developer experience as [httpx2](https://github.com/pydantic/httpx2). If you already know `requests` or `httpx`, you already know most of this.

The library is pre-alpha. HTTP/1.1 and HTTP/2 both work, over plain TCP and over TLS, with connection pooling, streaming in both directions, proxies, cookies, redirects, authentication and content decoding. The async client works over `http://` and `https://`, speaking HTTP/1.1 only. [Limitations](limitations.md) is the honest list of everything that is missing or does less than it should.

## Where to start

If you want a request in the next minute, read [QuickStart](quickstart.md). If you are setting up a project, read [Installation](install.md) first. If you are porting code from Python, read [Mojo notes](mojo.md) before anything else, because four or five language facts explain almost every difference you are about to hit.

## The pages

The structure follows httpx2's, so somebody moving between the two libraries is never lost.

| Page | What it covers |
| --- | --- |
| [Installation](install.md) | Requirements, getting it onto the import path, and how to check it works |
| [QuickStart](quickstart.md) | Sending a request, reading a response, and the twenty minute tour |
| [Advanced usage](advanced.md) | Clients, configuration, authentication, hooks, transports and testing |
| [Async support](async.md) | `AsyncClient`, `gather`, what stops a request, and what Mojo's scheduler allows |
| [Compatibility guide](deviations.md) | Every place this behaves differently from httpx2, and why |
| [Mojo notes](mojo.md) | The language facts that explain the API, for a Python developer |
| [Troubleshooting](troubleshooting.md) | Indexed by the error message you just pasted into a search engine |
| [API reference](api.md) | Every name `import httpx` gives you, generated from the source |
| [Contributing](../CONTRIBUTING.md) | Getting set up, the rules that are easy to break, and how to send a change |
| [Changelog](../CHANGELOG.md) | What changed in each release |

## The subject pages

These go deeper than the tour does, one subject each. Advanced usage links into them at the right moment, so you do not have to read them in order.

| Page | What it covers |
| --- | --- |
| [Request bodies](content.md) | The six body arguments, the content type each implies, and why passing two raises |
| [JSON](json.md) | Reading a body, building one, and what the parser refuses |
| [TLS](tls.md) | The defaults, private CAs, client certificates, and reading a handshake failure |
| [Proxies](proxies.md) | Forward proxying, CONNECT tunnels, SOCKS5, credentials, and per pattern mounts |
| [Command line client](cli.md) | The flags, what gets printed, and the exit code table |
| [Architecture](architecture.md) | The layer model and the design decisions behind it |
| [Testing](testing.md) | The test layers, the CI matrix, and the local hardware fleet |
| [Benchmarks](benchmarks.md) | The ten headline numbers, how each one is taken, and the five percent gate |
| [Limitations](limitations.md) | Everything missing or worse than httpx2, in one list |
| [Roadmap](roadmap.md) | Milestones M0 through M9 |

## How to read the examples

Every example is a whole program rather than a fragment. Save one to a file and run it with `pixi run mojo run -I . example.mojo` and it works. That is deliberate, and it is what lets `pixi run docex` hand every one of them to the compiler on every pull request, so an example that stops matching the code fails the build rather than sitting there.

`raises` is written out on every `def` that can fail, because Mojo 1.0 does not infer it. Almost everything in an HTTP client can fail, so almost every example says `def main() raises:`.
