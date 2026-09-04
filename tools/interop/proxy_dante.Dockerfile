# Dante for the proxy interop suite. See tools/interop/proxy.mojo.
#
# One image, two containers, the same as tinyproxy: the configuration file is
# the argument, and the two files differ in which authentication method they
# offer.
#
# The account exists because Dante's `username` method checks the password
# against the system account database rather than against a file of its own, so
# there has to be a real user for the credentials case to authenticate as. It
# is a shell-less account with a password that is in the repository, on a proxy
# reachable only from the loopback address of the machine running the suite.

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends dante-server \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --no-create-home --shell /usr/sbin/nologin interop \
    && echo 'interop:hunter2' | chpasswd

# The binary is danted rather than the sockd it is called upstream, which is
# Debian's renaming and not a different program. -N 1 is one worker process,
# which is all a suite needs, and without -D it stays in the foreground.
ENTRYPOINT ["danted", "-N", "1", "-f"]
CMD ["/conf/proxy_danted.conf"]
