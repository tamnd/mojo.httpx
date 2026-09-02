# nghttpx for the interop suite. See tools/interop/h2.mojo.
#
# There is no published nghttpx image, and the Alpine package is the shortest
# way to a pinned one. The Alpine tag is what pins the nghttp2 version, so
# moving the tag is the deliberate step that changes what is being tested
# against.

FROM alpine:3.20

RUN apk add --no-cache nghttp2

# nghttpx wants the key before the certificate, which is the opposite order to
# every other server here and is worth writing down rather than rediscovering.
ENTRYPOINT ["nghttpx", \
    "--frontend=*,8446", \
    "--backend=origin,8080", \
    "--errorlog-file=/dev/stderr", \
    "--accesslog-file=/dev/null", \
    "/certs/server.key", \
    "/certs/server.pem"]
