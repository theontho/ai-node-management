#!/bin/bash
set -euo pipefail

docker_version=29.1.3-0ubuntu3~24.04.2
compose_version=2.40.3+ds1-0ubuntu1~24.04.1
data_root=${1:-/srv/orca-node/state}
workspace_root=${2:-/srv/orca-node/workspaces}

(( EUID == 0 )) || {
  echo "$0 must run as root" >&2
  exit 77
}

[[ "$data_root" == /* && "$workspace_root" == /* ]] || {
  echo "data and workspace roots must be absolute paths" >&2
  exit 64
}

# shellcheck disable=SC1091
. /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == "24.04" ]] || {
  echo "Ubuntu 24.04 is required" >&2
  exit 1
}
[[ "$(dpkg --print-architecture)" == amd64 ]] || {
  echo "amd64 is required" >&2
  exit 1
}
[[ -c /dev/net/tun ]] || {
  echo "/dev/net/tun is required for Tailscale" >&2
  exit 1
}

if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  apt-get update
  apt-get install -y --no-install-recommends \
    "docker.io=$docker_version" \
    "docker-compose-v2=$compose_version"
fi

systemctl enable --now docker

install -d -o root -g root -m 0755 /opt/orca-node
install -d -o root -g root -m 0700 "$data_root" "$data_root/secrets"
install -d -o root -g root -m 0700 "$data_root/tailscale"
install -d -o 1000 -g 1000 -m 0700 "$data_root/orca-home"
install -d -o 1000 -g 1000 -m 0750 "$workspace_root"

docker version >/dev/null
docker compose version >/dev/null
