# The command line client

`httpx` is a command line HTTP client built from the same library. It sends one request and prints what comes back.

```
pixi run cli
./build/httpx https://example.com/
```

The binary goes in `build/` rather than beside the source, because the package is a directory called `httpx` and the linker will not write a file over it.

## The flags

Every flag is httpx2's, spelled the same way, so a command line written for one works on the other.

| Flag | Takes | What it does |
| --- | --- | --- |
| `-m`, `--method` | a method | The method to send. Defaults to GET, or POST when a body flag was given |
| `-p`, `--params` | a name and a value | One query parameter. Repeatable |
| `-h`, `--headers` | a name and a value | One request header. Repeatable |
| `--cookies` | a name and a value | One cookie to send. Repeatable |
| `-c`, `--content` | text | A raw request body, sent exactly as written |
| `-d`, `--data` | a name and a value | One form field. Repeatable. Sends a urlencoded body |
| `-f`, `--files` | a field name and a path | One file to upload. Repeatable. Sends a multipart body |
| `-j`, `--json` | text | A JSON request body, parsed before it is sent |
| `--auth` | a username and a password | Basic authentication |
| `--proxy` | a URL | Send through this proxy |
| `--timeout` | seconds | Give up after this long. 0 means do not wait at all |
| `--http2` | nothing | Offer HTTP/2 in the handshake as well as HTTP/1.1 |
| `--verify`, `--no-verify` | nothing | Whether to check TLS certificates. On by default |
| `--follow-redirects`, `--no-follow-redirects` | nothing | Whether to follow a 3xx. On by default here |
| `-v`, `--verbose` | nothing | Exactly `--print Hhb` |
| `--print` | letters | Which parts to print. See below |
| `--download` | a path | Write the body to a file instead of printing it. `-` means stdout |
| `--fail` | nothing | Exit 6 on a 4xx or 5xx instead of printing it |
| `--help`, `--version` | nothing | Print and stop |

`-h` is `--headers` and not help. That catches people out, and it is that way because it is that way in httpx2, where matching flag for flag is worth more than matching the habit. Help is `--help` only.

An option that takes a name and a value wants them as two separate arguments. `-h Accept application/json` is right and `-h Accept:application/json` is an error, rather than being split on some character the parser invented. An option that takes one value accepts it joined or separate, so `-m POST`, `-mPOST` and `--method=POST` are all the same thing.

The value after an option is whatever comes next, even when it starts with a dash, because header values and passwords really do start with dashes. Everything after a bare `--` is the URL rather than a flag.

## What gets printed

By default the response body goes to stdout and nothing else does. Anything else would mean every user of the tool learning a flag to turn it off before a pipeline worked.

`--print` takes httpie's letters, so the notation is one people already know. `H` is the request headers, `B` the request body, `h` the response headers, and `b` the response body. The default is `b`, and `-v` is exactly `Hhb`, which is the two heads and the response body. The request body is not in `-v` because it is usually the thing you just typed and it can be large, so ask for it with `--print HBhb` when you want it.

The request that is printed is the one that was actually sent, taken back off the response, so it carries the headers the client added, the credentials an auth scheme worked out, the cookies from the jar, and the URL a redirect chain ended at. An HTTP/2 exchange is shown in HTTP/1.1 shape, which is what every other tool does and is the only form most people can read.

Progress notes, warnings and errors all go to stderr, and the notes only appear when stderr is a terminal. Redirect stdout and what you get is the body and nothing else.

## Terminals and pipes

Everything that makes the output nicer to read happens only when the output is a terminal. Down a pipe or into a file you get the bytes the server sent, in the order it sent them, with nothing added and nothing taken away. That is one rule with three consequences, and it is the rule the golden tests exist to defend.

A JSON body is laid out over several lines and coloured on a terminal. The values are the ones that arrived: numbers keep the spelling the server used, strings keep their own escapes, and an object keeps its order. Only the whitespace is this program's. A body that says it is JSON and is not is printed exactly as it arrived rather than replaced by a parse error, because that body is usually an error page from something in the middle and it is the most useful thing on the screen at that moment. A body over four megabytes is streamed rather than laid out, since indenting it would mean holding all of it in memory first.

Colour is off when the output is not a terminal, when `NO_COLOR` is set to something, and when `TERM` is `dumb`. There is no flag for it. Header names are cyan, the request and status lines are bold, and in a JSON body the keys are cyan, the strings green, the numbers yellow and `true`, `false` and `null` magenta.

A body that is not text is not written to a terminal. Through a pipe it is written untouched, byte for byte, because the program on the other end asked for it. Whether a body counts as text is decided from `Content-Type` rather than by sniffing the bytes, because sniffing would mean holding the first chunk back to look at it.

```
./build/httpx https://example.com/logo.png
httpx: the body is image/png and is not being written to a terminal. Redirect it, or use --download to save it.
```

`--download -` says you want the bytes on stdout whatever they are, and skips that check.

A reader that goes away is not an error. `httpx URL | head -1` closes the pipe as soon as it has its line, and this stops writing and exits 0, the same as every other command line tool.

## Downloads

`--download PATH` writes the body to a file as it arrives, with a progress bar on stderr.

```
./build/httpx --download linux.tar.xz https://example.com/linux.tar.xz
linux.tar.xz  84.2 MiB / 132.0 MiB  [###################-----------] 63%
```

The bar is drawn only when stderr is a terminal, so `httpx --download f URL 2>log` leaves an empty log rather than a file full of carriage returns. It redraws at most ten times a second, because a download that spends its time drawing a bar is a slower download. A response with a `Content-Encoding` gets a running count and no bar: `Content-Length` counts the bytes on the wire, the file gets the decoded ones, and a bar that ran past its own end would be worse than no bar.

The file is opened before the request goes out. That means a path that cannot be written is reported before anything is sent, and it also means the file is truncated before the first byte arrives. curl's `-o` behaves the same way and for the same reason: there is no way to find out whether a path can be written except by writing to it.

## Exit codes

| Code | Means |
| --- | --- |
| 0 | The request was made and the response arrived |
| 1 | The command line was wrong, or something named on it could not be used |
| 2 | The network refused, dropped or garbled the exchange |
| 3 | A phase of the request ran out of time |
| 4 | TLS could not be established, or the certificate was rejected |
| 5 | The redirect chain went on too long |
| 6 | The status was 4xx or 5xx and `--fail` was given |

They follow curl closely enough to script against, which is the point. Nobody wants to learn a second table.

Code 1 covers more than a typo in a flag. A URL that will not parse, a scheme this client does not speak, a `--json` body that is not JSON, a file to upload that is not there and a download path that cannot be written are all the command line being wrong about something, even when the failure surfaces late.

Code 4 is worked out from the error message rather than from an exception class, because TLS failures are `ConnectError` here to match httpx2's hierarchy and there is no separate class to ask. The messages come from one file in this repository and a test pins the behaviour against a handshake that really failed.

## Two places it differs from httpx2

Redirects are followed by default. The library leaves them off, because a program that follows a redirect it did not ask for can leak a request to somewhere the caller never named, and the caller of a library is code that can check. At a prompt the caller is a person who typed a URL and wants the page. httpx2 draws the line in the same place, and so do curl -L and every browser.

A 4xx or 5xx without `--fail` exits 0. httpx2's CLI exits 1 on any status that is not a success. The reading here is curl's: the request worked, the server answered, and what it answered is on stdout to be read. A shell script that treats a 404 page as a failed command is usually right, and a shell script that cannot tell a 404 from a DNS failure never is.

## How the output is kept honest

`pixi run golden` runs the built binary against a server that answers with fixed bytes, once through pipes and once through a pty, and compares stdout, stderr and the exit code to files under `tests/golden/`. It also checks the two rules this page claims rather than only recording them: that nothing but the body reaches stdout unless it was asked for, and that a terminal differs from a pipe in decoration and never in content. It is part of `pixi run check` and runs in CI on all three platforms. [Testing](testing.md) has the details.
