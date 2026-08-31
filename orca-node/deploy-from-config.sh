#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
config_file=${1:-"$SCRIPT_DIR/local/deploy.env"}

[[ -f "$config_file" ]] || {
  echo "missing deployment config: $config_file" >&2
  echo "copy deploy.example.env to local/deploy.env and customize it" >&2
  exit 64
}
config_dir=$(cd "$(dirname "$config_file")" && pwd)
config_file="$config_dir/$(basename "$config_file")"
cd "$SCRIPT_DIR"

set -a
# The config is trusted operator input and is intentionally kept outside Git.
# shellcheck disable=SC1090
. "$config_file"
set +a

: "${SSH_TARGET:?SSH_TARGET is required}"
: "${NODE_NAME:?NODE_NAME is required}"
: "${TAILSCALE_AUTH_KEY_FILE:?TAILSCALE_AUTH_KEY_FILE is required}"

args=(
  --host "$SSH_TARGET"
  --node-name "$NODE_NAME"
  --tailscale-auth-key-file "$TAILSCALE_AUTH_KEY_FILE"
)
[[ -z "${ENVIRONMENT_NAME:-}" ]] \
  || args+=(--environment-name "$ENVIRONMENT_NAME")
[[ -z "${ORCA_KEYRING_PASSWORD_FILE:-}" ]] \
  || args+=(--orca-keyring-password-file "$ORCA_KEYRING_PASSWORD_FILE")
[[ -z "${PAIRING_ADDRESS:-}" ]] \
  || args+=(--pairing-address "$PAIRING_ADDRESS")
[[ -z "${DATA_ROOT:-}" ]] \
  || args+=(--data-root "$DATA_ROOT")
[[ -z "${WORKSPACE_ROOT:-}" ]] \
  || args+=(--workspace-root "$WORKSPACE_ROOT")

exec "$SCRIPT_DIR/deploy.sh" "${args[@]}"
