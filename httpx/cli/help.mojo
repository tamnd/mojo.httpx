"""The text `--help` and `--version` print.

Written out rather than generated from the parser, because a generated help is
a help that reads like a table. What somebody at a prompt needs is the flag,
what it does, and the shape of the value, in an order that groups the flags
that go together, and none of that is in `args.mojo` to be extracted.

It is a constant and not a function that prints, so that a test can compare it
to what the parser accepts and a later change to one is caught when it is not
made to the other.
"""

from httpx import __version__

comptime HELP = """\
usage: httpx [options] URL

  A command line HTTP client. Sends one request and prints what comes back.

request:
  -m, --method METHOD        The method. GET, or POST when a body was given.
  -p, --params NAME VALUE    A query parameter. Repeatable.
  -h, --headers NAME VALUE   A request header. Repeatable.
      --cookies NAME VALUE   A cookie to send. Repeatable.
  -c, --content TEXT         A raw request body, sent as it is written.
  -d, --data NAME VALUE      A form field. Repeatable. Sends a form body.
  -f, --files NAME PATH      A file to upload. Repeatable. Sends multipart.
  -j, --json TEXT            A JSON request body. Must parse before it is sent.
      --auth USER PASSWORD   Basic authentication.

connection:
      --proxy URL            Send through this proxy.
      --timeout SECONDS      Give up after this long. 0 means do not wait.
      --http2                Offer HTTP/2 as well as HTTP/1.1.
      --verify               Check TLS certificates. This is the default.
      --no-verify            Do not check them. For a server you already trust.
      --follow-redirects     Follow redirects. This is the default here.
      --no-follow-redirects  Print the redirect instead of following it.

output:
  -v, --verbose              Print the request headers and the response
                             headers as well as the body.
      --print LETTERS        Which parts to print. H is the request headers, B
                             the request body, h the response headers, b the
                             response body. The default is b.
      --download PATH        Write the body to this file instead of printing
                             it. - means stdout.
      --fail                 Exit 6 on a 4xx or 5xx instead of printing it.
      --help                 Print this and stop.
      --version              Print the version and stop.

exit codes:
  0  the response arrived
  1  the command line was wrong
  2  the network failed
  3  the request timed out
  4  TLS failed
  5  too many redirects
  6  an error status, with --fail

  Note that -h is --headers and not help, which is what it is in the Python
  httpx it follows. Everything after -- is taken as the URL rather than as a
  flag.

  Colour, the progress bar and the layout of a JSON body only happen when the
  output is a terminal, so a pipe and a file get the bytes the server sent.
  Colour is off as well when NO_COLOR is set or TERM is dumb.
"""
"""What `--help` prints.

Ends with a newline and is written straight to stdout, so `httpx --help | grep
timeout` behaves and the text is the same whether or not it is going to a
terminal.
"""


def version_line() -> String:
    """What `--version` prints.

    The version comes from the package rather than from a copy kept here, so
    releasing cannot leave the binary claiming to be the previous one.
    """
    return String("httpx ", __version__, "\n")
