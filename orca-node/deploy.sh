#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

file_mode() {
  if stat -f %Lp "$1" >/dev/null 2>&1; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

usage() {
  cat >&2 <<'EOF'
usage: deploy.sh \
  --host USER@HOST \
  --node-name NAME \
  --tailscale-auth-key-file FILE \
  [--orca-keyring-password-file FILE] \
  [--pairing-address HOST] \
  [--environment-name NAME] \
  [--data-root PATH] \
  [--workspace-root PATH]
EOF
  exit 64
}

ssh_target=
node_name=
pairing_address=
environment_name=
tailscale_auth_key_file=
orca_keyring_password_file="$SCRIPT_DIR/local/private/orca-keyring-password"
data_root=/data/orca-node
workspace_root=/srv/orca-node/workspaces

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --host) ssh_target=$2; shift 2 ;;
    --node-name) node_name=$2; shift 2 ;;
    --pairing-address) pairing_address=$2; shift 2 ;;
    --environment-name) environment_name=$2; shift 2 ;;
    --tailscale-auth-key-file) tailscale_auth_key_file=$2; shift 2 ;;
    --orca-keyring-password-file) orca_keyring_password_file=$2; shift 2 ;;
    --data-root) data_root=$2; shift 2 ;;
    --workspace-root) workspace_root=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$ssh_target" && "$ssh_target" != -* && "$ssh_target" != *[[:space:]]* ]] || usage
[[ "$node_name" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || usage
[[ "$data_root" =~ ^/[A-Za-z0-9._/-]+$ && "$workspace_root" =~ ^/[A-Za-z0-9._/-]+$ ]] || usage
[[ -s "$tailscale_auth_key_file" ]] || usage
[[ "$(file_mode "$tailscale_auth_key_file")" == 600 ]] || {
  echo "Tailscale auth key file must have mode 0600" >&2
  exit 1
}

if [[ ! -e "$orca_keyring_password_file" ]]; then
  install -d -m 0700 "$(dirname "$orca_keyring_password_file")"
  umask 077
  openssl rand -base64 48 > "$orca_keyring_password_file"
fi
[[ -s "$orca_keyring_password_file" ]] || {
  echo "Orca keyring password file is empty" >&2
  exit 1
}
[[ "$(file_mode "$orca_keyring_password_file")" == 600 ]] || {
  echo "Orca keyring password file must have mode 0600" >&2
  exit 1
}

pairing_address_auto=false
if [[ -z "$pairing_address" ]]; then
  pairing_address=$node_name
  pairing_address_auto=true
fi
environment_name=${environment_name:-$node_name}
[[ "$pairing_address" =~ ^[A-Za-z0-9.-]+$ ]] || usage
[[ "$environment_name" =~ ^[A-Za-z0-9._-]+$ ]] || usage

deploy_id="$$"
remote_stage=".orca-node-stage-$deploy_id"

cleanup() {
  ssh -o BatchMode=yes "$ssh_target" "rm -rf '$remote_stage'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

ssh -o BatchMode=yes "$ssh_target" "install -d -m 0700 '$remote_stage'"
scp -q \
  "$SCRIPT_DIR/Dockerfile" \
  "$SCRIPT_DIR/compose.yaml" \
  "$SCRIPT_DIR/assets/orca-entrypoint" \
  "$SCRIPT_DIR/assets/orca-node.service" \
  "$SCRIPT_DIR/bootstrap-host.sh" \
  "$ssh_target:$remote_stage/"
scp -q "$tailscale_auth_key_file" \
  "$ssh_target:$remote_stage/tailscale-auth-key"
scp -q "$orca_keyring_password_file" \
  "$ssh_target:$remote_stage/orca-keyring-password"

ssh -o BatchMode=yes "$ssh_target" bash -s -- \
  "$remote_stage" \
  "$node_name" \
  "$pairing_address" \
  "$data_root" \
  "$workspace_root" <<'REMOTE'
set -euo pipefail

stage=$1
node_name=$2
pairing_address=$3
data_root=$4
workspace_root=$5

sudo bash "$stage/bootstrap-host.sh" "$data_root" "$workspace_root"
sudo install -o root -g root -m 0644 "$stage/Dockerfile" /opt/orca-node/Dockerfile
sudo install -o root -g root -m 0644 "$stage/compose.yaml" /opt/orca-node/compose.yaml
sudo install -o root -g root -m 0755 "$stage/orca-entrypoint" /opt/orca-node/orca-entrypoint
sudo install -o root -g root -m 0600 "$stage/tailscale-auth-key" "$data_root/secrets/tailscale-auth-key"
sudo install -o root -g 1000 -m 0440 "$stage/orca-keyring-password" "$data_root/secrets/orca-keyring-password"
sudo install -o root -g root -m 0644 "$stage/orca-node.service" /etc/systemd/system/orca-node.service

sudo install -d -o root -g root -m 0755 /opt/orca-node/assets
sudo install -o root -g root -m 0755 "$stage/orca-entrypoint" /opt/orca-node/assets/orca-entrypoint

node_env=$(mktemp)
trap 'rm -f "$node_env"' EXIT
{
  printf 'NODE_NAME=%s\n' "$node_name"
  printf 'ORCA_PAIRING_ADDRESS=%s\n' "$pairing_address"
  printf 'ORCA_PAIRING_ENABLED=true\n'
  printf 'ORCA_MOBILE_PAIRING=false\n'
  printf 'DATA_ROOT=%s\n' "$data_root"
  printf 'WORKSPACE_ROOT=%s\n' "$workspace_root"
  printf 'TAILSCALE_AUTH_KEY_FILE=%s/secrets/tailscale-auth-key\n' "$data_root"
  printf 'ORCA_KEYRING_PASSWORD_FILE=%s/secrets/orca-keyring-password\n' "$data_root"
} > "$node_env"
sudo install -o root -g root -m 0600 "$node_env" /opt/orca-node/node.env

cd /opt/orca-node
sudo docker compose --env-file node.env build --pull orca
sudo systemctl daemon-reload
sudo systemctl enable orca-node.service
sudo systemctl restart orca-node.service
REMOTE

for _ in $(seq 1 60); do
  if ssh -o BatchMode=yes "$ssh_target" \
    "sudo docker inspect --format='{{.State.Health.Status}}' orca-node-orca-1 2>/dev/null" \
    | grep -Fxq healthy; then
    break
  fi
  sleep 5
done

health=$(
  ssh -o BatchMode=yes "$ssh_target" \
    "sudo docker inspect --format='{{.State.Health.Status}}' orca-node-orca-1 2>/dev/null" \
    || true
)
[[ "$health" == healthy ]] || {
  ssh -o BatchMode=yes "$ssh_target" \
    "sudo docker compose --env-file /opt/orca-node/node.env -f /opt/orca-node/compose.yaml ps; sudo docker compose --env-file /opt/orca-node/node.env -f /opt/orca-node/compose.yaml logs --tail=100"
  echo "Orca appliance did not become healthy" >&2
  exit 1
}

if [[ "$pairing_address_auto" == true ]]; then
  pairing_address=$(
    ssh -o BatchMode=yes "$ssh_target" \
      "sudo docker exec orca-node-tailscale-1 tailscale --socket=/var/run/tailscale/tailscaled.sock ip -4" \
      | head -n1
  )
  [[ "$pairing_address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || {
    echo "Could not determine the Tailscale IPv4 address" >&2
    exit 1
  }
  ssh -o BatchMode=yes "$ssh_target" \
    "sudo sed -i 's/^ORCA_PAIRING_ADDRESS=.*/ORCA_PAIRING_ADDRESS=$pairing_address/' /opt/orca-node/node.env; cd /opt/orca-node && sudo docker compose --env-file node.env up --detach --force-recreate --no-deps orca"

  for _ in $(seq 1 30); do
    health=$(
      ssh -o BatchMode=yes "$ssh_target" \
        "sudo docker inspect --format='{{.State.Health.Status}}' orca-node-orca-1 2>/dev/null" \
        || true
    )
    [[ "$health" == healthy ]] && break
    sleep 2
  done
  [[ "$health" == healthy ]] || {
    echo "Orca did not become healthy with its Tailscale address" >&2
    exit 1
  }
fi

pairing_code=$(
  ssh -o BatchMode=yes "$ssh_target" \
    "sudo docker logs orca-node-orca-1 2>&1" \
    | grep -Eo 'orca://pair\\?[^[:space:]\"'\"']+' \
    | tail -n1
)
[[ -n "$pairing_code" ]] || {
  echo "Orca pairing code was not found in container logs" >&2
  exit 1
}

if ! orca status --environment "$environment_name" --json 2>/dev/null \
  | python3 -c 'import json, sys; value=json.load(sys.stdin); raise SystemExit(not (value.get("result", {}).get("runtime", {}).get("state") == "ready" and value.get("result", {}).get("runtime", {}).get("reachable") is True))'
then
  if orca environment show --environment "$environment_name" --json >/dev/null 2>&1; then
    orca environment rm --environment "$environment_name" --json >/dev/null
  fi
  orca environment add \
    --name "$environment_name" \
    --pairing-code "$pairing_code" \
    --json
fi

for _ in $(seq 1 30); do
  if orca status --environment "$environment_name" --json 2>/dev/null \
    | python3 -c 'import json, sys; value=json.load(sys.stdin); raise SystemExit(not (value.get("result", {}).get("runtime", {}).get("state") == "ready" and value.get("result", {}).get("runtime", {}).get("reachable") is True))'
  then
    paired_ready=true
    break
  fi
  sleep 2
done
[[ "${paired_ready:-false}" == true ]] || {
  echo "Saved Orca environment did not become reachable after pairing" >&2
  exit 1
}

ssh -o BatchMode=yes "$ssh_target" \
  "sudo sed -i 's/^ORCA_PAIRING_ENABLED=.*/ORCA_PAIRING_ENABLED=false/' /opt/orca-node/node.env; cd /opt/orca-node && sudo docker compose --env-file node.env up --detach --force-recreate --no-deps orca"

for _ in $(seq 1 30); do
  final_health=$(
    ssh -o BatchMode=yes "$ssh_target" \
      "sudo docker inspect --format='{{.State.Health.Status}}' orca-node-orca-1 2>/dev/null" \
      || true
  )
  [[ "$final_health" == healthy ]] && break
  sleep 2
done
[[ "$final_health" == healthy ]] || {
  echo "Orca did not become healthy after disabling pairing offers" >&2
  exit 1
}

for _ in $(seq 1 30); do
  if orca status --environment "$environment_name" --json 2>/dev/null \
    | python3 -c 'import json, sys; value=json.load(sys.stdin); raise SystemExit(not (value.get("result", {}).get("runtime", {}).get("state") == "ready" and value.get("result", {}).get("runtime", {}).get("reachable") is True))'
  then
    remote_ready=true
    break
  fi
  sleep 2
done
[[ "${remote_ready:-false}" == true ]] || {
  echo "Saved Orca environment did not reconnect after pairing was disabled" >&2
  exit 1
}

printf 'Orca node %s is healthy and saved as environment %s.\n' \
  "$node_name" "$environment_name"
