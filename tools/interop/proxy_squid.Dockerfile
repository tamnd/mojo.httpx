# Squid for the proxy interop suite. See tools/interop/proxy.mojo.
#
# Built rather than pulled. The images on Docker Hub that carry a squid are all
# somebody's own arrangement with their own entry point and their own idea of
# where the configuration lives, and the package in a distribution image is
# both shorter to read and pinned by the tag on the line below.

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends squid \
    && rm -rf /var/lib/apt/lists/*

# -N keeps it in the foreground, which is what a container wants, and -d 1
# sends the little it has to say to stderr where `docker logs` finds it.
ENTRYPOINT ["squid", "-N", "-d", "1", "-f"]
CMD ["/conf/proxy_squid.conf"]
