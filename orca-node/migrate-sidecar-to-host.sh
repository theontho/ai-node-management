#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

usage() {
  cat >&2 <<'EOF'
usage: migrate-sidecar-to-host.sh \
  --host USER@HOST \
  [--environment-name NAME] \
  [--data-root PATH]
EOF
  exit 64
}

ssh_target=
environment_name=
data_root=/srv/orca-node/state
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --host) ssh_target=$2; shift 2 ;;
    --environment-name) environment_name=$2; shift 2 ;;
    --data-root) data_root=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$ssh_target" && "$ssh_target" != -* && "$ssh_target" != *[[:space:]]* ]] || usage
[[ "$data_root" =~ ^/[A-Za-z0-9._/-]+$ ]] || usage
[[ -z "$environment_name" || "$environment_name" =~ ^[A-Za-z0-9._-]+$ ]] || usage

remote_stage=".orca-node-tailscale-migration-$$"
cleanup() {
  ssh -o BatchMode=yes "$ssh_target" \
    "rm -rf '$remote_stage'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

ssh -o BatchMode=yes "$ssh_target" "install -d -m 0700 '$remote_stage'"
scp -q \
  "$SCRIPT_DIR/compose.yaml" \
  "$SCRIPT_DIR/assets/orca-node.service" \
  "$ssh_target:$remote_stage/"

host_tailscale_ip=$(
  ssh -o BatchMode=yes "$ssh_target" sudo -n bash -s -- \
    "$remote_stage" \
    "$data_root" <<'REMOTE'
set -euo pipefail

stage=$1
data_root=$2
compose=/opt/orca-node/compose.yaml
node_env=/opt/orca-node/node.env
service=/etc/systemd/system/orca-node.service
source_state="$data_root/tailscale/tailscaled.state"
source_key="$data_root/secrets/tailscale-auth-key"
host_state=/var/lib/tailscale/tailscaled.state
backup_root=$(mktemp -d /var/tmp/orca-node-tailscale-migration.XXXXXX)
committed=false

rollback() {
  exit_code=$?
  if [[ "$committed" != true ]]; then
    systemctl stop tailscaled.service >/dev/null 2>&1 || true
    systemctl mask tailscaled.service >/dev/null 2>&1 || true
    rm -f "$host_state"
    install -o root -g root -m 0644 "$backup_root/compose.yaml" "$compose"
    install -o root -g root -m 0600 "$backup_root/node.env" "$node_env"
    install -o root -g root -m 0644 "$backup_root/orca-node.service" "$service"
    systemctl daemon-reload
    systemctl restart orca-node.service >/dev/null 2>&1 || true
  fi
  rm -rf "$backup_root"
  exit "$exit_code"
}
trap rollback EXIT

(( EUID == 0 )) || {
  echo "migration must run as root" >&2
  exit 77
}
command -v tailscale >/dev/null || {
  echo "install the host Tailscale package before migration" >&2
  exit 1
}
[[ -f "$source_state" ]] || {
  echo "sidecar Tailscale state is missing: $source_state" >&2
  exit 1
}
[[ ! -e "$host_state" ]] || {
  echo "host Tailscale state already exists; refusing to overwrite it" >&2
  exit 1
}
docker inspect orca-node-tailscale-1 >/dev/null
host_hostname=$(hostname --short)
[[ "$host_hostname" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || {
  echo "host does not have a valid short hostname" >&2
  exit 1
}
container_hostname="${host_hostname:0:58}-orca"
expected_ip=$(
  docker exec orca-node-tailscale-1 \
    tailscale --socket=/var/run/tailscale/tailscaled.sock ip -4 |
    sed -n '1p'
)
[[ "$expected_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "sidecar Tailscale IPv4 address is unavailable" >&2
  exit 1
}

install -m 0644 "$compose" "$backup_root/compose.yaml"
install -m 0600 "$node_env" "$backup_root/node.env"
install -m 0644 "$service" "$backup_root/orca-node.service"

systemctl stop orca-node.service
install -d -o root -g root -m 0700 /var/lib/tailscale
install -o root -g root -m 0600 "$source_state" "$host_state"
systemctl unmask tailscaled.service
systemctl enable --now tailscaled.service

for _ in $(seq 1 30); do
  actual_ip=$(
    tailscale ip -4 2>/dev/null |
      sed -n '1p' ||
      true
  )
  backend_state=$(
    tailscale status --json 2>/dev/null |
      python3 -c 'import json, sys; print(json.load(sys.stdin).get("BackendState", ""))' \
      || true
  )
  [[ "$actual_ip" == "$expected_ip" && "$backend_state" == Running ]] && break
  sleep 2
done
[[ "${actual_ip:-}" == "$expected_ip" && "${backend_state:-}" == Running ]] || {
  echo "host Tailscale did not assume the sidecar identity" >&2
  exit 1
}

install -o root -g root -m 0644 "$stage/compose.yaml" "$compose"
install -o root -g root -m 0644 "$stage/orca-node.service" "$service"
new_env=$(mktemp)
{
  printf 'ORCA_BIND_ADDRESS=%s\n' "$expected_ip"
  printf 'ORCA_CONTAINER_HOSTNAME=%s\n' "$container_hostname"
  printf 'ORCA_PAIRING_ADDRESS=%s\n' "$expected_ip"
  grep -Ev '^(NODE_NAME|ORCA_BIND_ADDRESS|ORCA_CONTAINER_HOSTNAME|ORCA_PAIRING_ADDRESS|TAILSCALE_AUTH_KEY_FILE)=' \
    "$node_env"
} > "$new_env"
install -o root -g root -m 0600 "$new_env" "$node_env"
rm -f "$new_env"

systemctl daemon-reload
systemctl restart orca-node.service
for _ in $(seq 1 60); do
  health=$(
    docker inspect --format='{{.State.Health.Status}}' orca-node-orca-1 \
      2>/dev/null || true
  )
  [[ "$health" == healthy ]] && break
  sleep 2
done
[[ "${health:-}" == healthy ]] || {
  echo "Orca did not become healthy on host Tailscale" >&2
  exit 1
}
if docker inspect orca-node-tailscale-1 >/dev/null 2>&1; then
  echo "Tailscale sidecar still exists after migration" >&2
  exit 1
fi
ss -lnt | grep -Eq "[[:space:]]${expected_ip}:6768[[:space:]]" || {
  echo "Orca is not bound to ${expected_ip}:6768" >&2
  exit 1
}

rm -f "$source_key"
find "$data_root/tailscale" -depth -delete
committed=true
printf '%s\n' "$expected_ip"
REMOTE
)

[[ "$host_tailscale_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || {
  echo "migration did not return a host Tailscale IPv4 address" >&2
  exit 1
}
if [[ -n "$environment_name" ]]; then
  orca status --environment "$environment_name" --json |
    python3 -c '
import json
import sys

runtime = json.load(sys.stdin).get("result", {}).get("runtime", {})
if runtime.get("state") != "ready" or runtime.get("reachable") is not True:
    raise SystemExit(1)
'
fi

printf 'Migrated Orca to host Tailscale at %s; the sidecar and its key are removed.\n' \
  "$host_tailscale_ip"
