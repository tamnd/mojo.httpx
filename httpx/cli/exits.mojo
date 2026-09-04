"""What the process exits with.

A command line tool is something scripts run, and a script can only act on what
it is told. One exit code for every failure would mean a wrapper had to read
the message to find out whether to retry, and messages are for people. So the
failures that call for different handling get different codes.

    0  the request was made and the response arrived
    1  the command line was wrong, or something named on it could not be used
    2  the network refused, dropped or garbled the exchange
    3  a phase of the request ran out of time
    4  TLS could not be established or the certificate was rejected
    5  the redirect chain went on too long
    6  the status was 4xx or 5xx and --fail was given

They follow curl closely enough to script against, which is the point. Nobody
learns a second table.

A status of 4xx or 5xx without `--fail` is a zero, because the request worked:
the server answered, and what it answered is on stdout for the caller to read.
That is curl's reading rather than httpx2's, whose CLI exits 1 on any status
that is not a success. The difference is deliberate and it is in the
compatibility guide, because a shell script that treats a 404 page as a failed
command is usually right and a shell script that cannot tell a 404 from a DNS
failure never is.
"""

from httpx._exceptions import (
    ErrorKind,
    is_invalid_url,
    is_timeout,
    is_too_many_redirects,
    is_unsupported_protocol,
    kind_of,
    message_of,
)

comptime EXIT_OK = 0
comptime EXIT_USAGE = 1
comptime EXIT_NETWORK = 2
comptime EXIT_TIMEOUT = 3
comptime EXIT_TLS = 4
comptime EXIT_REDIRECTS = 5
comptime EXIT_STATUS = 6


def is_tls_failure(imm e: Error) -> Bool:
    """Whether a failure was TLS rather than the connection underneath it.

    There is no TLS error class to ask, and there is not going to be one:
    httpx2 has no such class either, the kinds here are httpx2's kinds, and
    inventing one would change the name every one of these errors carries.
    What the TLS layer does have is a small set of messages it writes itself,
    every one of which names TLS, so that is what this reads.

    It is a private contract between two files in one repository rather than a
    guess about somebody else's text, and the tests pin it against a real
    failed handshake so it cannot rot quietly.
    """
    if kind_of(e) != ErrorKind.CONNECT_ERROR:
        return False
    return message_of(e).find("TLS") >= 0


def code_for(imm e: Error) -> Int:
    """The exit code for a failure that happened while sending.

    Only for the send. Anything raised before the request went out is the
    command line's fault, whatever it was raised as, and `run` answers that
    with the usage code without asking here.
    """
    if is_timeout(e):
        return EXIT_TIMEOUT
    if is_too_many_redirects(e):
        return EXIT_REDIRECTS
    if is_tls_failure(e):
        return EXIT_TLS
    if is_invalid_url(e) or is_unsupported_protocol(e):
        # Both of these are about what was typed rather than about the
        # network, even when they surface late, so they read as usage.
        return EXIT_USAGE
    # Everything else that happens while a request is in flight is the network
    # in the broad sense: a refused connection, a dropped one, a reply that was
    # not HTTP. A caller who wants the detail has the message on stderr.
    return EXIT_NETWORK
