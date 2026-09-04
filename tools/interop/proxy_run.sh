#!/usr/bin/env bash
#
# Bring up Squid, tinyproxy, mitmproxy and Dante in Docker, run the proxy
# interop cases through all of them, and take them down again.
#
#   pixi run interop-proxy                 all four
#   pixi run interop-proxy --keep          leave them running afterwards
#   pixi run interop-proxy --only squid    one proxy, repeat the flag for more
#
# This is a local tool, not CI. It needs Docker and it opens listening ports on
# the loopback address. See docs/testing.md.
#
# Written for bash 3.2 so it works on a stock macOS shell.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONF="$ROOT/tools/interop"
CERTS="$CONF/.proxycerts"
NET="mojo-httpx-proxy"
IMAGE_SQUID="mojo-httpx-squid:bookworm"
IMAGE_TINYPROXY="mojo-httpx-tinyproxy:bookworm"
IMAGE_DANTE="mojo-httpx-dante:bookworm"

# Docker Desktop on macOS does not share /tmp by default, so everything that
# gets mounted lives inside the repository instead of in a temporary directory.
# The certificates are generated, not checked in, and .gitignore covers them.

CONTAINERS="origin tlsorigin squid-proxy tinyproxy-proxy tinyproxy-auth-proxy mitm-proxy dante-proxy dante-auth-proxy"

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

# The published ports, which are also written down in tools/interop/proxy.mojo.
# They are up in a range nothing much uses rather than on 3128 and 1080 and the
# rest, because those are exactly the ports a proxy somebody else started is
# already sitting on. Inside the containers the standard ports are kept.
PORT_SQUID=13128
PORT_TINYPROXY=18888
PORT_TINYPROXY_AUTH=18889
PORT_MITM=18080
PORT_DANTE=11080
PORT_DANTE_AUTH=11081

remove_all() {
  docker rm -f $CONTAINERS >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}

teardown() {
  [ "$keep" -eq 1 ] && return 0
  remove_all
}
trap teardown EXIT

# Unconditionally, whatever --keep said, because these are the containers this
# script owns and a leftover set from a previous run would take the names and
# the ports it is about to ask for.
remove_all
keep_after_teardown=$keep

# Now that nothing of ours is holding them, the ports have to be free. This is
# not a tidiness check. A port that is already answering means the cases would
# run against whatever is behind it instead, and what that looks like is a
# handful of puzzling failures from a proxy that is not the one under test. It
# has happened here: an ssh dynamic forward, sitting on the SOCKS port.
taken=""
port_taken() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null || return 1
  exec 3<&- 2>/dev/null || true
  return 0
}
check_free() {
  wanted "$1" || return 0
  if port_taken "$2"; then
    taken="$taken $2"
  fi
}
check_free squid "$PORT_SQUID"
check_free tinyproxy "$PORT_TINYPROXY"
check_free tinyproxy "$PORT_TINYPROXY_AUTH"
check_free mitmproxy "$PORT_MITM"
check_free dante "$PORT_DANTE"
check_free dante "$PORT_DANTE_AUTH"
if [ -n "$taken" ]; then
  echo "something is already listening on:$taken" >&2
  echo "the suite needs those ports on 127.0.0.1, and the cases would run" >&2
  echo "against whatever answered instead. Stop it, or run this elsewhere." >&2
  exit 2
fi

echo "=== certificates"
# The same thirty day CA and leaf the HTTP/2 suite makes, in its own directory
# so that running one suite does not invalidate the other's servers. The leaf
# is for `tlsorigin`, which is the name the tunnelling cases ask for, and that
# name only resolves inside the Docker network. That is deliberate: a client
# that resolved the target itself rather than handing the name to the proxy
# would fail to resolve it at all.
if ! openssl x509 -in "$CERTS/ca.pem" -checkend 604800 >/dev/null 2>&1; then
  rm -rf "$CERTS"
  mkdir -p "$CERTS"
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
    -keyout "$CERTS/ca.key" -out "$CERTS/ca.pem" \
    -subj "/CN=mojo.httpx proxy interop CA" >/dev/null 2>&1
  openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$CERTS/server.key" -out "$CERTS/server.csr" \
    -subj "/CN=tlsorigin" >/dev/null 2>&1
  printf 'subjectAltName=DNS:tlsorigin,DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n' \
    > "$CERTS/ext.cnf"
  openssl x509 -req -in "$CERTS/server.csr" -days 30 \
    -CA "$CERTS/ca.pem" -CAkey "$CERTS/ca.key" -CAcreateserial \
    -extfile "$CERTS/ext.cnf" -out "$CERTS/server.pem" >/dev/null 2>&1
  chmod 644 "$CERTS/server.key" "$CERTS/ca.key"
  echo "    made a new CA and leaf, good for 30 days"
else
  echo "    reusing the existing CA and leaf"
fi

# mitmproxy generates a CA of its own on first start and keeps it in this
# directory. It runs as its own unprivileged user inside the container, so the
# directory has to be writable by somebody this side does not know the id of.
# There is nothing in it but a throwaway CA for a proxy on the loopback address.
mkdir -p "$CERTS/mitm"
chmod 777 "$CERTS/mitm"

docker network create "$NET" >/dev/null

echo
echo "=== building images"
# Squid, tinyproxy and Dante are built from a distribution image rather than
# pulled, because every published image for them is somebody's own arrangement.
# The builds are cached, so this is only slow the first time.
for image in squid tinyproxy dante; do
  case "$image" in
    squid) wanted squid || continue ;;
    tinyproxy) wanted tinyproxy || continue ;;
    dante) wanted dante || continue ;;
  esac
  case "$image" in
    squid) tag="$IMAGE_SQUID" ;;
    tinyproxy) tag="$IMAGE_TINYPROXY" ;;
    dante) tag="$IMAGE_DANTE" ;;
  esac
  docker build -q -t "$tag" -f "$CONF/proxy_$image.Dockerfile" "$CONF" >/dev/null
  echo "    $image"
done

echo
echo "=== origins"

docker run -d --name origin --network "$NET" \
  -v "$CONF:/conf:ro" \
  python:3.12-alpine python /conf/origin.py >/dev/null
echo "    origin      http://origin:8080 inside the network"

docker run -d --name tlsorigin --network "$NET" \
  -v "$CONF/proxy_nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$CERTS:/certs:ro" \
  nginx:1.27-alpine >/dev/null
echo "    tlsorigin   https://tlsorigin inside the network"

echo
echo "=== proxies"

if wanted squid; then
  docker run -d --name squid-proxy --network "$NET" -p "127.0.0.1:$PORT_SQUID:3128" \
    -v "$CONF:/conf:ro" "$IMAGE_SQUID" >/dev/null
  echo "    squid            http://127.0.0.1:$PORT_SQUID"
fi

if wanted tinyproxy; then
  docker run -d --name tinyproxy-proxy --network "$NET" -p "127.0.0.1:$PORT_TINYPROXY:8888" \
    -v "$CONF:/conf:ro" "$IMAGE_TINYPROXY" >/dev/null
  echo "    tinyproxy        http://127.0.0.1:$PORT_TINYPROXY"
  docker run -d --name tinyproxy-auth-proxy --network "$NET" \
    -p "127.0.0.1:$PORT_TINYPROXY_AUTH:8889" \
    -v "$CONF:/conf:ro" "$IMAGE_TINYPROXY" \
    /conf/proxy_tinyproxy_auth.conf >/dev/null
  echo "    tinyproxy-auth   http://127.0.0.1:$PORT_TINYPROXY_AUTH"
fi

if wanted mitmproxy; then
  # `block_global` off because mitmproxy refuses clients from outside a private
  # range by default, and the address a published port arrives from depends on
  # how Docker is set up on the machine rather than on anything this suite
  # controls. `ssl_insecure` because mitmproxy makes its own connection to the
  # origin and would otherwise refuse the certificate the suite signed for
  # itself, which would turn every intercepted request into a 502 before the
  # client had anything to decide. What the client trusts is still checked, and
  # that is the half these cases are about.
  docker run -d --name mitm-proxy --network "$NET" -p "127.0.0.1:$PORT_MITM:8080" \
    -v "$CERTS/mitm:/home/mitmproxy/.mitmproxy" \
    mitmproxy/mitmproxy:11.1.3 \
    mitmdump -q --listen-host 0.0.0.0 --listen-port 8080 \
    --set block_global=false --ssl-insecure >/dev/null
  echo "    mitmproxy        http://127.0.0.1:$PORT_MITM"
fi

if wanted dante; then
  docker run -d --name dante-proxy --network "$NET" -p "127.0.0.1:$PORT_DANTE:1080" \
    -v "$CONF:/conf:ro" "$IMAGE_DANTE" >/dev/null
  echo "    dante            socks5://127.0.0.1:$PORT_DANTE"
  docker run -d --name dante-auth-proxy --network "$NET" \
    -p "127.0.0.1:$PORT_DANTE_AUTH:1081" \
    -v "$CONF:/conf:ro" "$IMAGE_DANTE" \
    /conf/proxy_danted_auth.conf >/dev/null
  echo "    dante-auth       socks5://127.0.0.1:$PORT_DANTE_AUTH"
fi

echo
echo "=== waiting"
# Poll the port rather than sleeping, the same as the HTTP/2 suite does. A
# fixed sleep long enough for the slowest machine in the fleet is a fixed sleep
# every other machine pays on every run.
ready_port() {
  for _ in $(seq 1 150); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; then
      exec 3<&- 2>/dev/null || true
      return 0
    fi
    sleep 0.2
  done
  return 1
}

check_port() {
  # $1 is the --only name, $2 the container, $3 the port, $4 what to print.
  wanted "$1" || return 0
  if ! ready_port "$3"; then
    echo "    $4 never came up. Its log:" >&2
    docker logs "$2" 2>&1 | tail -20 >&2
    exit 1
  fi
  echo "    $4 ready"
}

check_port squid squid-proxy "$PORT_SQUID" squid
check_port tinyproxy tinyproxy-proxy "$PORT_TINYPROXY" tinyproxy
check_port tinyproxy tinyproxy-auth-proxy "$PORT_TINYPROXY_AUTH" tinyproxy-auth
check_port mitmproxy mitm-proxy "$PORT_MITM" mitmproxy
check_port dante dante-proxy "$PORT_DANTE" dante
check_port dante dante-auth-proxy "$PORT_DANTE_AUTH" dante-auth

if wanted mitmproxy; then
  # The CA is written on first start rather than at build time, and the cases
  # that trust it cannot run until it is on disk.
  found=0
  for _ in $(seq 1 150); do
    if [ -s "$CERTS/mitm/mitmproxy-ca-cert.pem" ]; then
      found=1
      break
    fi
    sleep 0.2
  done
  if [ "$found" -eq 0 ]; then
    echo "    mitmproxy never wrote its CA. Its log:" >&2
    docker logs mitm-proxy 2>&1 | tail -20 >&2
    exit 1
  fi
  echo "    mitmproxy CA written"
fi

echo
status=0
export HTTPX_INTEROP_CA="$CERTS/ca.pem"
export HTTPX_INTEROP_MITM_CA="$CERTS/mitm/mitmproxy-ca-cert.pem"
export HTTPX_INTEROP_ONLY="$only"
pixi run mojo run -I "$ROOT" "$CONF/proxy.mojo" || status=$?

if [ "$status" -ne 0 ]; then
  echo
  echo "=== container logs, in case the failure is on that side"
  for name in $CONTAINERS; do
    if docker inspect "$name" >/dev/null 2>&1; then
      echo "--- $name"
      docker logs "$name" 2>&1 | tail -10
    fi
  done
fi

if [ "$keep_after_teardown" -eq 1 ]; then
  echo
  echo "proxies left running. Take them down with:"
  echo "  docker rm -f $CONTAINERS"
  echo "  docker network rm $NET"
fi

exit "$status"
