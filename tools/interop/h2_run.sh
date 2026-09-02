#!/usr/bin/env bash
#
# Bring up four HTTP/2 servers in Docker, run the interop cases against all of
# them, and take them down again.
#
#   pixi run interop-h2                 all four
#   pixi run interop-h2 --keep          leave them running afterwards
#   pixi run interop-h2 --only nginx    one server, repeat the flag for more
#
# This is a local tool, not CI. It needs Docker and it opens listening ports on
# the loopback address. See docs/testing.md.
#
# Written for bash 3.2 so it works on a stock macOS shell.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONF="$ROOT/tools/interop"
CERTS="$CONF/.h2certs"
NET="mojo-httpx-h2"
IMAGE_NGHTTPX="mojo-httpx-nghttpx:alpine3.20"

# Docker Desktop on macOS does not share /tmp by default, so everything that
# gets mounted lives inside the repository instead of in a temporary directory.
# The certificates are generated, not checked in, and .gitignore covers them.

keep=0
only=""

while [ $# -gt 0 ]; do
  case "$1" in
    --keep) keep=1; shift ;;
    --only) only="$only $2 "; shift 2 ;;
    -h|--help) sed -n '3,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

wanted() {
  [ -z "$only" ] && return 0
  case "$only" in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

if ! docker info >/dev/null 2>&1; then
  echo "docker is not running" >&2
  exit 2
fi

teardown() {
  [ "$keep" -eq 1 ] && return 0
  docker rm -f origin nginx-h2 caddy-h2 envoy-h2 nghttpx-h2 >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap teardown EXIT

teardown
keep_after_teardown=$keep

echo "=== certificates"
# Thirty days, because a suite that has to be run today to work is a suite
# somebody will find broken on a Monday. Regenerated whenever the CA is missing
# or within a week of expiring.
if ! openssl x509 -in "$CERTS/ca.pem" -checkend 604800 >/dev/null 2>&1; then
  rm -rf "$CERTS"
  mkdir -p "$CERTS"
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
    -keyout "$CERTS/ca.key" -out "$CERTS/ca.pem" \
    -subj "/CN=mojo.httpx interop CA" >/dev/null 2>&1
  openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$CERTS/server.key" -out "$CERTS/server.csr" \
    -subj "/CN=localhost" >/dev/null 2>&1
  printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n' \
    > "$CERTS/ext.cnf"
  openssl x509 -req -in "$CERTS/server.csr" -days 30 \
    -CA "$CERTS/ca.pem" -CAkey "$CERTS/ca.key" -CAcreateserial \
    -extfile "$CERTS/ext.cnf" -out "$CERTS/server.pem" >/dev/null 2>&1
  # The servers run as their own users and all of them have to read the key.
  # These certificates are for a loopback listener that lives for the length of
  # one run, so there is nothing here worth protecting.
  chmod 644 "$CERTS/server.key" "$CERTS/ca.key"
  echo "    made a new CA and leaf, good for 30 days"
else
  echo "    reusing the existing CA and leaf"
fi

docker network create "$NET" >/dev/null

echo
echo "=== servers"

docker run -d --name origin --network "$NET" \
  -v "$CONF:/conf:ro" \
  python:3.12-alpine python /conf/h2_origin.py >/dev/null
echo "    origin"

if wanted nginx; then
  docker run -d --name nginx-h2 --network "$NET" -p 127.0.0.1:8443:8443 \
    -v "$CONF/h2_nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "$CERTS:/certs:ro" \
    nginx:1.27-alpine >/dev/null
  echo "    nginx      https://localhost:8443"
fi

if wanted caddy; then
  docker run -d --name caddy-h2 --network "$NET" -p 127.0.0.1:8444:8444 \
    -v "$CONF/h2_caddyfile:/etc/caddy/Caddyfile:ro" \
    -v "$CERTS:/certs:ro" \
    caddy:2-alpine >/dev/null
  echo "    caddy      https://localhost:8444"
fi

if wanted envoy; then
  docker run -d --name envoy-h2 --network "$NET" -p 127.0.0.1:8445:8445 \
    -v "$CONF/h2_envoy.yaml:/etc/envoy/envoy.yaml:ro" \
    -v "$CERTS:/certs:ro" \
    envoyproxy/envoy:v1.31-latest >/dev/null
  echo "    envoy      https://localhost:8445"
fi

if wanted nghttpx; then
  docker build -q -t "$IMAGE_NGHTTPX" -f "$CONF/h2_nghttpx.Dockerfile" "$CONF" >/dev/null
  docker run -d --name nghttpx-h2 --network "$NET" -p 127.0.0.1:8446:8446 \
    -v "$CERTS:/certs:ro" \
    "$IMAGE_NGHTTPX" >/dev/null
  echo "    nghttpx    https://localhost:8446"
fi

echo
echo "=== waiting"
# Poll the port rather than sleeping. Envoy is the slow one and takes about a
# second here, but a fixed sleep long enough for the slowest machine in the
# fleet is a fixed sleep everybody else pays for on every run.
for port in 8443 8444 8445 8446; do
  case "$port" in
    8443) name=nginx ;; 8444) name=caddy ;;
    8445) name=envoy ;; 8446) name=nghttpx ;;
  esac
  wanted "$name" || continue
  ready=0
  for _ in $(seq 1 100); do
    # -servername because Caddy routes by SNI and refuses a handshake that
    # carries none, which looks exactly like a server that has not started yet.
    if openssl s_client -connect "127.0.0.1:$port" -servername localhost \
        -alpn h2 </dev/null >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 0.2
  done
  if [ "$ready" -eq 0 ]; then
    echo "    $name never came up. Its log:" >&2
    docker logs "$name-h2" 2>&1 | tail -20 >&2
    exit 1
  fi
  echo "    $name ready"
done

echo
status=0
export HTTPX_INTEROP_CA="$CERTS/ca.pem"
export HTTPX_INTEROP_ONLY="$only"
pixi run mojo run -I "$ROOT" "$CONF/h2.mojo" || status=$?

if [ "$keep_after_teardown" -eq 1 ]; then
  echo
  echo "servers left running. Take them down with:"
  echo "  docker rm -f origin nginx-h2 caddy-h2 envoy-h2 nghttpx-h2"
  echo "  docker network rm $NET"
fi

exit "$status"
