# tinyproxy for the proxy interop suite. See tools/interop/proxy.mojo.
#
# One image, two containers. The configuration file is the argument, so the
# plain listener and the one that wants credentials are the same build with a
# different file handed to it.

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends tinyproxy \
    && rm -rf /var/lib/apt/lists/*

# -d keeps it in the foreground.
ENTRYPOINT ["tinyproxy", "-d", "-c"]
CMD ["/conf/proxy_tinyproxy.conf"]
