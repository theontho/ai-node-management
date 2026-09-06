#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)

for executable in \
  "$ROOT"/validate.sh \
  "$ROOT"/linux-autoinstall/*.sh \
  "$ROOT"/linux-autoinstall/config.py \
  "$ROOT"/linux-autoinstall/diskselector.py \
  "$ROOT"/linux-autoinstall/generate-password.py \
  "$ROOT"/linux-autoinstall/render-autoinstall.py \
  "$ROOT"/orca-node/*.sh \
  "$ROOT"/orca-node/assets/orca-entrypoint \
  "$ROOT"/windows-orca-devbox/*.sh \
  "$ROOT"/windows-autoinstall/*.sh \
  "$ROOT"/windows-autoinstall/config.py; do
  [[ -x "$executable" ]] || {
    echo "expected executable mode: $executable" >&2
    exit 1
  }
done

"$ROOT/linux-autoinstall/validate.sh"
"$ROOT/windows-autoinstall/validate.sh"
"$ROOT/windows-orca-devbox/validate.sh"
bash "$ROOT/system-inventory/validate.sh"

for script in \
  "$ROOT"/orca-node/*.sh \
  "$ROOT"/orca-node/assets/orca-entrypoint; do
  bash -n "$script"
done
bash -n "$ROOT/orca-node/benchmark.example.env"

python3 - "$ROOT" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for path in (
    root / "orca-node/benchmark-agent-clis.py",
    root / "orca-node/benchmark_tasks.py",
    root / "orca-node/generate-benchmark-report.py",
    root / "orca-node/moltis-acp-client.py",
):
    compile(path.read_text(), str(path), "exec")
PY

python3 "$ROOT/orca-node/benchmark-agent-clis.py" --help >/dev/null
python3 "$ROOT/orca-node/generate-benchmark-report.py" --help >/dev/null

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck \
    "$ROOT"/orca-node/*.sh \
    "$ROOT"/orca-node/assets/orca-entrypoint
fi

if command -v docker >/dev/null 2>&1; then
  DATA_ROOT=/srv/orca-node/state \
  WORKSPACE_ROOT=/srv/orca-node/workspaces \
  ORCA_KEYRING_PASSWORD_FILE=/tmp/orca-keyring-password \
  ORCA_BIND_ADDRESS=100.64.0.10 \
  ORCA_CONTAINER_HOSTNAME=lin-lunar-maple-orca \
  ORCA_PAIRING_ADDRESS=127.0.0.1 \
  ORCA_PAIRING_ENABLED=false \
    docker compose -f "$ROOT/orca-node/compose.yaml" config --quiet
fi

git -C "$ROOT" diff --check

grep -Fq 'ARG NODE_VERSION=22.23.2' "$ROOT/orca-node/Dockerfile"
grep -Fq 'ARG COPILOT_CLI_VERSION=1.0.82' "$ROOT/orca-node/Dockerfile"
grep -Fq 'ARG GH_VERSION=2.98.0' "$ROOT/orca-node/Dockerfile"
grep -Fq 'python -m venv /tmp/python-smoke' "$ROOT/orca-node/Dockerfile"
grep -Fq 'python-is-python3' "$ROOT/orca-node/Dockerfile"
grep -Fq 'copilot --version' "$ROOT/orca-node/Dockerfile"
grep -Fq 'gh --version' "$ROOT/orca-node/Dockerfile"
grep -Fq '"${ORCA_BIND_ADDRESS}:6768:6768"' "$ROOT/orca-node/compose.yaml"
grep -Fq 'hostname: "${ORCA_CONTAINER_HOSTNAME}"' "$ROOT/orca-node/compose.yaml"
grep -Fq 'container_hostname="${host_hostname:0:58}-orca"' \
  "$ROOT/orca-node/deploy.sh"
grep -Fq 'host tailscaled.service must be running' \
  "$ROOT/orca-node/bootstrap-host.sh"
grep -Fq 'ExecStartPre=/usr/bin/tailscale ip -4' \
  "$ROOT/orca-node/assets/orca-node.service"
if grep -Eq 'tailscale/tailscale|network_mode:[[:space:]]*service:tailscale|TS_AUTHKEY' \
  "$ROOT/orca-node/compose.yaml"; then
  echo "Orca Compose still embeds a Tailscale sidecar" >&2
  exit 1
fi

echo "Repository validation passed."
