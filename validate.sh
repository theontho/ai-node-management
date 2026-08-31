#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)

for executable in \
  "$ROOT"/validate.sh \
  "$ROOT"/linux-autoinstall/*.sh \
  "$ROOT"/linux-autoinstall/render-autoinstall.py \
  "$ROOT"/orca-node/*.sh \
  "$ROOT"/orca-node/assets/orca-entrypoint \
  "$ROOT"/windows-autoinstall/*.sh \
  "$ROOT"/windows-autoinstall/config.py; do
  [[ -x "$executable" ]] || {
    echo "expected executable mode: $executable" >&2
    exit 1
  }
done

"$ROOT/linux-autoinstall/validate.sh"
"$ROOT/windows-autoinstall/validate.sh"

for script in \
  "$ROOT"/orca-node/*.sh \
  "$ROOT"/orca-node/assets/orca-entrypoint; do
  bash -n "$script"
done

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck \
    "$ROOT"/orca-node/*.sh \
    "$ROOT"/orca-node/assets/orca-entrypoint
fi

if command -v docker >/dev/null 2>&1; then
  DATA_ROOT=/data/orca-node \
  WORKSPACE_ROOT=/srv/orca-node/workspaces \
  TAILSCALE_AUTH_KEY_FILE=/tmp/tailscale-auth-key \
  ORCA_KEYRING_PASSWORD_FILE=/tmp/orca-keyring-password \
  NODE_NAME=ai-node-validation \
  ORCA_PAIRING_ADDRESS=127.0.0.1 \
  ORCA_PAIRING_ENABLED=false \
    docker compose -f "$ROOT/orca-node/compose.yaml" config --quiet
fi

git -C "$ROOT" diff --check
echo "Repository validation passed."
