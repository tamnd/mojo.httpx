"""Golden tests for the command line client: every byte it writes, pinned.

The unit tests drive the CLI through `run(argv)`, which is quick and covers the
exit codes, but it cannot see the two things this suite exists for. What
actually lands on stdout and stderr, byte for byte, and whether that changes
when the descriptor is a terminal. Both of those are properties of a process,
so this runs the built binary against a server that answers with fixed bytes,
once through pipes and once through a pty, and compares everything to a file
checked in beside it.

Two rules are checked rather than only recorded.

Nothing but the body reaches stdout unless it was asked for. That is what makes
`httpx URL | jq` and `httpx URL > file` work, and it is the rule that CLI HTTP
clients most often break, usually by writing a progress line or a status to the
stream the next program is reading.

A terminal and a pipe differ in decoration and never in content. The suite
strips the escape sequences from the terminal run and requires what is left to
be what went down the pipe. A JSON body is the one place the bytes themselves
differ, because a terminal gets it indented, so there the two are compared as
parsed values instead, which is a stronger check than comparing whitespace.

Run it with `pixi run golden`, which builds the binary first. `--update`
rewrites the files from what the binary does now; read the diff before
committing it, because that is the whole value of having them.
"""

import argparse
import json
import os
import pty
import re
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import termios
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / "build" / "httpx"
GOLDEN = ROOT / "tests" / "golden"

# A fixed date, so a golden file is not a file that starts failing tomorrow.
DATE = "Thu, 01 Jan 2026 00:00:00 GMT"

# Deliberately written on one line, the way a server actually sends it, so that
# the layout in the golden file is the client's work and not the server's.
JSON_BODY = (
    b'{"name":"mojo","tags":["fast","typed"],"n":42,"ok":true,'
    b'"nothing":null,"empty":{},"list":[],"escaped":"a \\"quoted\\" word"}'
)
TEXT_BODY = b"hello from the test server\n"
BINARY_BODY = bytes(range(16))
BROKEN_JSON_BODY = b"{this is not json"
NOT_FOUND_BODY = b"no such thing\n"


def response(status, reason, content_type, body):
    head = (
        f"HTTP/1.1 {status} {reason}\r\n"
        f"Date: {DATE}\r\n"
        f"Server: golden/1\r\n"
        f"Content-Type: {content_type}\r\n"
        f"Content-Length: {len(body)}\r\n"
        f"Connection: close\r\n"
        f"\r\n"
    )
    return head.encode() + body


ROUTES = {
    "/text": response(200, "OK", "text/plain; charset=utf-8", TEXT_BODY),
    "/json": response(200, "OK", "application/json", JSON_BODY),
    "/broken-json": response(200, "OK", "application/json", BROKEN_JSON_BODY),
    "/binary": response(200, "OK", "application/octet-stream", BINARY_BODY),
    "/missing": response(
        404, "Not Found", "text/plain; charset=utf-8", NOT_FOUND_BODY
    ),
}


class Server(threading.Thread):
    """A socket server that answers with canned bytes and nothing else.

    Not `http.server`, because that one writes its own `Date` and `Server`
    headers and picks its own reason phrases, and every one of those would end
    up inside a golden file as something this project does not control.
    """

    def __init__(self):
        super().__init__(daemon=True)
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(16)
        self.port = self.sock.getsockname()[1]
        self.running = True

    def run(self):
        while self.running:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self.serve, args=(conn,), daemon=True).start()

    def serve(self, conn):
        with conn:
            head = b""
            while b"\r\n\r\n" not in head:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                head += chunk
            target = head.split(b" ")[1].decode("latin-1")
            path = target.split("?")[0]
            body = ROUTES.get(
                path,
                response(
                    404, "Not Found", "text/plain; charset=utf-8", NOT_FOUND_BODY
                ),
            )
            conn.sendall(body)

    def stop(self):
        self.running = False
        self.sock.close()


def read_until_eof(masters, proc):
    """Drain the pty masters until the child has gone and both are empty.

    A pty master reports EIO rather than end of file once the last process
    holding the slave has exited, which on Linux arrives as an OSError and on
    macOS as an empty read. Both mean the same thing here.
    """
    out = {fd: b"" for fd in masters}
    open_fds = list(masters)
    while open_fds:
        ready, _, _ = select.select(open_fds, [], [], 5.0)
        if not ready:
            if proc.poll() is not None:
                break
            continue
        for fd in ready:
            try:
                data = os.read(fd, 65536)
            except OSError:
                data = b""
            if not data:
                open_fds.remove(fd)
                continue
            out[fd] += data
    return out


def run_pipe(args, env, cwd):
    done = subprocess.run(
        [str(BINARY)] + args,
        env=env,
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        capture_output=True,
    )
    return done.returncode, done.stdout, done.stderr


def run_tty(args, env, cwd):
    """The same command with a terminal on both output descriptors.

    The pty's own newline translation is turned off first. Without that every
    line feed the client writes arrives as a carriage return and a line feed,
    and the golden file would be pinning what the kernel did rather than what
    the program did.
    """
    out_master, out_slave = pty.openpty()
    err_master, err_slave = pty.openpty()
    for slave in (out_slave, err_slave):
        attrs = termios.tcgetattr(slave)
        attrs[1] &= ~termios.ONLCR
        termios.tcsetattr(slave, termios.TCSANOW, attrs)

    proc = subprocess.Popen(
        [str(BINARY)] + args,
        env=env,
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        stdout=out_slave,
        stderr=err_slave,
    )
    os.close(out_slave)
    os.close(err_slave)
    streams = read_until_eof([out_master, err_master], proc)
    code = proc.wait()
    stdout = streams[out_master]
    stderr = streams[err_master]
    os.close(out_master)
    os.close(err_master)
    return code, stdout, stderr


ESCAPES = {0x0D: "\\r", 0x1B: "\\e", 0x5C: "\\\\"}


def encode(data):
    """Bytes as text that survives a diff and a code review.

    Line feeds stay line feeds, so a golden file reads like the output it is.
    Everything else that would be invisible or would not survive a text file is
    spelled out, which is what makes a stray carriage return or a colour
    sequence something a reviewer can see rather than something they have to
    take on trust.
    """
    out = []
    for byte in data:
        if byte == 0x0A:
            out.append("\n")
        elif byte in ESCAPES:
            out.append(ESCAPES[byte])
        elif 0x20 <= byte < 0x7F:
            out.append(chr(byte))
        else:
            out.append(f"\\x{byte:02x}")
    return "".join(out)


def envelope(code, stdout, stderr):
    return (
        f"exit {code}\n"
        f"[stdout]\n{encode(stdout)}\n"
        f"[stderr]\n{encode(stderr)}\n"
    )


ANSI = re.compile(rb"\x1b\[[0-9;]*m")


def undecorate(data):
    """What is left of a terminal's output once the decoration is taken off."""
    return ANSI.sub(b"", data)


def json_equal(left, right):
    try:
        return json.loads(left) == json.loads(right)
    except ValueError:
        return False


class Case:
    def __init__(
        self,
        name,
        args,
        path,
        env=None,
        json_body=False,
        download=None,
        withheld=False,
    ):
        self.name = name
        self.args = args
        self.path = path
        self.env = env or {}
        # True when a terminal is expected to lay the body out again, so the
        # two runs are compared as values rather than as bytes.
        self.json_body = json_body
        self.download = download
        # True when a terminal is expected to be told what the body is instead
        # of being given it, which is the one case where the two runs really do
        # differ in content and are meant to.
        self.withheld = withheld


CASES = [
    Case("text-body", [], "/text"),
    Case("text-verbose", ["-v"], "/text"),
    Case("json-body", [], "/json", json_body=True),
    Case("json-verbose", ["-v"], "/json", json_body=True),
    Case("json-broken", [], "/broken-json"),
    Case("headers-only", ["--print", "h"], "/json"),
    Case("binary-body", [], "/binary", withheld=True),
    Case("binary-forced", ["--download", "-"], "/binary"),
    Case("fail-status", ["--fail"], "/missing"),
    Case("no-color", ["-v"], "/json", env={"NO_COLOR": "1"}, json_body=True),
    Case("term-dumb", ["-v"], "/json", env={"TERM": "dumb"}, json_body=True),
    Case("download-file", ["--download", "out.bin"], "/text", download="out.bin"),
    Case("usage-error", ["--nope"], "/text"),
]


def base_env():
    """A fixed environment, so that whatever the developer's shell exports
    cannot get into a golden file. `TERM` is set to something ordinary because
    the client treats `dumb` as a request for no colour and an unset `TERM` is
    a third case that no user is in."""
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": os.environ.get("HOME", "/tmp"),
        "TERM": "xterm-256color",
    }
    # The library finds its own OpenSSL through this on a pixi machine, and a
    # run without it fails before it reaches anything this suite is about.
    for name in ("CONDA_PREFIX", "SSL_CERT_FILE", "SSL_CERT_DIR"):
        if name in os.environ:
            env[name] = os.environ[name]
    return env


def normalize(data, port):
    """Take the one thing out of the output that changes every run."""
    return data.replace(f"127.0.0.1:{port}".encode(), b"127.0.0.1:PORT")


def check_case(case, port, mode, update, failures):
    env = base_env()
    env.update(case.env)
    url = f"http://127.0.0.1:{port}{case.path}"
    workdir = tempfile.mkdtemp(prefix="httpx-golden-")
    try:
        runner = run_pipe if mode == "pipe" else run_tty
        code, stdout, stderr = runner(case.args + [url], env, workdir)
        if case.download:
            written = (Path(workdir) / case.download).read_bytes()
            if written != TEXT_BODY:
                failures.append(
                    f"{case.name} [{mode}]: the downloaded file is not the body"
                )
        got = envelope(
            code, normalize(stdout, port), normalize(stderr, port)
        )
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    path = GOLDEN / f"{case.name}.{mode}.txt"
    if update:
        path.write_text(got)
        return stdout, stderr
    want = path.read_text() if path.exists() else ""
    if got != want:
        failures.append(f"{case.name} [{mode}]: output changed\n{diff(want, got)}")
    return stdout, stderr


def diff(want, got):
    import difflib

    lines = difflib.unified_diff(
        want.splitlines(keepends=True),
        got.splitlines(keepends=True),
        fromfile="golden",
        tofile="now",
    )
    return "".join(lines)


def check_decoration(case, pipe_stdout, tty_stdout, failures):
    """The rule that a terminal changes decoration and never content."""
    if case.withheld:
        # The binary guard. A terminal is told what the body is and is not
        # given it, which is the one deliberate difference in content, so what
        # is checked here is that the difference is the whole body and not part
        # of it.
        if tty_stdout != b"" or pipe_stdout != BINARY_BODY:
            failures.append(
                f"{case.name}: a binary body should reach a pipe whole and a"
                " terminal not at all"
            )
        return
    bare = undecorate(tty_stdout)
    if bare == pipe_stdout:
        return
    if case.json_body:
        # The head is byte for byte the same and the body is the same value.
        # Split on the blank line the head ends with, and where there is no
        # head there is nothing before it.
        bare_head, _, bare_body = bare.rpartition(b"\r\n\r\n")
        pipe_head, _, pipe_body = pipe_stdout.rpartition(b"\r\n\r\n")
        if bare_head == pipe_head and json_equal(bare_body, pipe_body):
            return
    failures.append(
        f"{case.name}: the terminal run differs from the pipe in more than"
        " decoration"
    )


def check_stdout_is_only_the_body(case, stdout, failures):
    """Nothing but what was asked for goes to stdout.

    Only checked on the cases that asked for a body and nothing else, which is
    the default and the one that has to keep working for a pipeline.
    """
    if case.args or case.download:
        return
    body = {
        "/text": TEXT_BODY,
        "/binary": BINARY_BODY,
        "/broken-json": BROKEN_JSON_BODY,
    }.get(case.path)
    if body is None:
        return
    if stdout != body:
        failures.append(
            f"{case.name}: stdout is not exactly the body the server sent"
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--update", action="store_true", help="rewrite the golden files"
    )
    options = parser.parse_args()

    if not BINARY.exists():
        print(f"no binary at {BINARY}. Run `pixi run cli` first.", file=sys.stderr)
        return 2
    GOLDEN.mkdir(parents=True, exist_ok=True)

    server = Server()
    server.start()
    failures = []
    try:
        for case in CASES:
            pipe_stdout, _ = check_case(
                case, server.port, "pipe", options.update, failures
            )
            tty_stdout, _ = check_case(
                case, server.port, "tty", options.update, failures
            )
            check_decoration(case, pipe_stdout, tty_stdout, failures)
            check_stdout_is_only_the_body(case, pipe_stdout, failures)
    finally:
        server.stop()

    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        print(f"{len(failures)} golden check(s) failed", file=sys.stderr)
        return 1
    what = "wrote" if options.update else "checked"
    print(f"golden: {what} {len(CASES) * 2} run(s), all good")
    return 0


if __name__ == "__main__":
    sys.exit(main())
