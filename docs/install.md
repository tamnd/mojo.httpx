# Installation

There is no package to install. mojo.httpx ships as source, you put that source somewhere Mojo can import it from, and that is the whole of it.

That is not laziness. `.mojopkg` is tied to the exact compiler that produced it, and the Mojo documentation says directly that it is not meant as a distributable format: a package built with 1.0.0 will not import under 1.0.1. So a release here is a source tarball, `.mojopkg` is used only as a local build cache, and the import path is how you depend on it. [Architecture](architecture.md) has the longer version of that argument.

## What you need

Mojo 1.0.0. The project pins the exact toolchain in `pixi.toml` and building against a different one is a real source of confusion, because the language still changes between releases in ways that move the ground under this project. `httpx.MOJO_MIN_VERSION` is the version the code was written against.

OpenSSL 3.0 or newer, but only for `https://`. It is opened at run time by name rather than linked, so there is no build step, no headers to install and nothing to configure, and the copy that ships inside the Mojo toolchain's own environment is found first. Plain `http://` needs nothing at all.

Nothing else is required. zlib, libbrotlidec and libzstd are each opened the same way, the first time a compressed response needs one, and a machine missing one of them simply does not advertise that coding in `Accept-Encoding`. You get larger responses rather than a failure. [Compatibility guide](deviations.md) says why that is decided at run time here and at import time in httpx2.

| Platform | Status |
| --- | --- |
| macOS arm64 | Supported, tested in CI on every pull request |
| Linux x86_64 | Supported, tested in CI and on real hardware |
| Linux arm64 | Supported, tested in CI on every pull request |
| Windows | Under WSL2 only, tested on real hardware rather than in CI |

Mojo has no native Windows build, so there is nothing to install on Windows directly. WSL2 works and is tested. That is a Modular limitation rather than one of ours.

## Getting the source

The easiest way is to clone it next to your own code.

```bash
git clone https://github.com/tamnd/mojo.httpx
```

A release tarball will be the other way, once there is a release to download. The release workflow publishes `mojo-httpx-VERSION.tar.gz` with a `SHA256SUMS` beside it and a build attestation, so what you downloaded can be checked against what CI built. Until the first tag, a clone is the only way and pinning means pinning a commit.

## Putting it on the import path

Mojo finds a package by looking in the directories `-I` names. The `httpx` package is the `httpx/` directory inside the checkout, so `-I` wants the directory that contains it.

```bash
mojo run -I /path/to/mojo.httpx myprogram.mojo
mojo build -I /path/to/mojo.httpx -o myprogram myprogram.mojo
```

If you cloned it inside your own project, that is `-I mojo.httpx`. If you are working in this repository, it is `-I .`, which is what every example in these docs and every task in `pixi.toml` uses.

Writing the flag out on every command gets old, so put it in your own `pixi.toml` instead.

```toml
[dependencies]
mojo = "==1.0.0"

[tasks]
run = "mojo run -I vendor/mojo.httpx main.mojo"
build = "mojo build -I vendor/mojo.httpx -o build/app main.mojo"
```

You need the Modular channel for the `mojo` dependency itself. If you are starting a project from nothing, this is the whole file.

```toml
[workspace]
name = "myproject"
channels = ["https://conda.modular.com/max", "conda-forge"]
platforms = ["osx-arm64", "linux-64", "linux-aarch64"]

[dependencies]
mojo = "==1.0.0"

[tasks]
run = "mojo run -I vendor/mojo.httpx main.mojo"
```

## Checking it works

```mojo
import httpx


def main() raises:
    print(httpx.__version__)
    var r = httpx.get("https://example.com/")
    print(r.status_code)
```

```bash
mojo run -I /path/to/mojo.httpx check.mojo
```

Two numbers and no traceback means the source is on the path, OpenSSL was found, and the certificate chain verified. If any of those went wrong, the message says which one, and [Troubleshooting](troubleshooting.md) is indexed by that message.

To check without touching the network, ask for a mock transport instead. This exercises everything above the socket and needs nothing outside the process.

```mojo
from httpx import Client, MockRouter, Route, erase_transport


def main() raises:
    var router = MockRouter()
    router.add(Route.any().respond_json(200, '{"ok": true}'))

    var client = Client(erase_transport(router^))
    var r = client.get("https://example.com/")
    print(r.status_code, r.json()["ok"].as_bool())
```

## Building the command line client

The same library is also an `httpx` command. Inside a checkout of this repository:

```bash
pixi run cli
./build/httpx https://example.com/
```

The binary lands in `build/` rather than beside the source, because the package is a directory called `httpx` and the linker will not write a file over it. Copy it onto your `PATH` from there. It is one binary with no runtime to install alongside it, and it starts in a couple of milliseconds rather than the couple of hundred a Python entry point costs, which is the difference between a tool you can use inside a shell loop and one you cannot. [Command line client](cli.md) has the flags.

## Working on the library itself

```bash
git clone https://github.com/tamnd/mojo.httpx
cd mojo.httpx
pixi install
pixi run check
```

`pixi install` reads the pinned toolchain out of `pixi.lock`, so you get the exact Mojo, the exact OpenSSL and the exact compression libraries CI uses. `pixi run check` is everything: formatting, the lints, the vendored data, the generated tables, the API reference, the platform baselines, the test suite and the command line golden tests. It takes a few minutes on a quiet machine. [Contributing](../CONTRIBUTING.md) is the rest of the setup.
