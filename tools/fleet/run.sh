#!/usr/bin/env bash
#
# Run the test suite on the real machines listed in hosts.toml.
#
# This is a local tool, not CI. It copies the working tree to each host over
# SSH, installs the pinned toolchain there, and runs a task. Nothing here needs
# a runner registered with GitHub and nothing here holds a credential.
#
#   tools/fleet/run.sh                 run `pixi run test` on every host
#   tools/fleet/run.sh --role fuzz     only hosts with that role
#   tools/fleet/run.sh --host server3  one host
#   tools/fleet/run.sh -- pixi run bench
#
# Written for bash 3.2 so it works on a stock macOS shell.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOSTS_FILE="$ROOT/tools/fleet/hosts.toml"

role=""
only_host=""
cmd="pixi run test"

while [ $# -gt 0 ]; do
  case "$1" in
    --role) role="$2"; shift 2 ;;
    --host) only_host="$2"; shift 2 ;;
    --) shift; cmd="$*"; break ;;
    -h|--help) sed -n '3,14p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Read the host table. The parsing lives here so the script depends on nothing
# beyond bash, ssh, tar and rsync.
entries="$(
  awk '
    /^\[\[host\]\]/ { if (n) print n "\t" s "\t" r; n=""; s=""; r=""; next }
    /^name *=/      { gsub(/.*= *"|"/, ""); n=$0; next }
    /^shell *=/     { gsub(/.*= *"|"/, ""); s=$0; next }
    /^roles *=/     { gsub(/.*= *\[|\]|"| /, ""); r=$0; next }
    END             { if (n) print n "\t" s "\t" r }
  ' "$HOSTS_FILE"
)"

status=0
matched=0

# Loop over fd 3 so that ssh inside the body cannot eat the host list.
while IFS="$(printf '\t')" read -r name shell roles <&3; do
  [ -z "$name" ] && continue
  if [ -n "$only_host" ] && [ "$name" != "$only_host" ]; then continue; fi
  if [ -n "$role" ] && [ "${roles#*"$role"}" = "$roles" ]; then continue; fi
  matched=$((matched + 1))

  echo
  echo "=== $name"

  # `echo` rather than `true`, because the Windows host answers with cmd.exe
  # and cmd has no `true`.
  if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$name" "echo ok" </dev/null >/dev/null 2>&1; then
    echo "    unreachable, skipping"
    status=1
    continue
  fi

  # On the Windows box everything runs inside the WSL2 guest, because Mojo has
  # no native Windows build.
  if [ "$shell" = "wsl" ]; then
    # The outer shell on this host is cmd.exe, which cannot parse a quoted bash
    # command, so every remote command goes in over stdin instead.
    remote_dir="/tmp/mojo-httpx-fleet"
    remote_sh="wsl -- bash -l -s"
    echo "rm -rf $remote_dir; mkdir -p $remote_dir" | ssh "$name" "$remote_sh"
    # macOS tar writes xattr headers that GNU tar does not know, and it warns
    # once per file about them. The data is fine, so tell the far end to be
    # quiet about it.
    COPYFILE_DISABLE=1 tar -C "$ROOT" \
      --exclude .git --exclude .pixi --exclude build -czf - . \
      | ssh "$name" "wsl -- tar -C $remote_dir --warning=no-unknown-keyword -xzf -"
  else
    remote_dir="\$HOME/.cache/mojo-httpx-fleet"
    remote_sh="bash -l -s"
    echo "mkdir -p ~/.cache/mojo-httpx-fleet" | ssh "$name" "$remote_sh"
    rsync -az --delete \
      --exclude '.git/' --exclude '.pixi/' --exclude 'build/' \
      "$ROOT/" "$name:.cache/mojo-httpx-fleet/"
  fi

  remote_script="set -e
export PATH=\$HOME/.pixi/bin:\$PATH
command -v pixi >/dev/null || curl -fsSL https://pixi.sh/install.sh | bash
export PATH=\$HOME/.pixi/bin:\$PATH
cd $remote_dir
pixi install --locked
$cmd"

  if printf '%s\n' "$remote_script" | ssh "$name" "$remote_sh"; then
    echo "    ok"
  else
    echo "    FAILED on $name"
    status=1
  fi
done 3<<EOF
$entries
EOF

if [ "$matched" -eq 0 ]; then
  echo "no hosts matched" >&2
  exit 2
fi

echo
if [ "$status" -eq 0 ]; then
  echo "fleet run passed on $matched host(s)"
else
  echo "fleet run had failures"
fi
exit "$status"
