#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
CONFIG_FILE=${1:-}

if [[ -n "$CONFIG_FILE" ]]; then
  [[ -f "$CONFIG_FILE" ]] || {
    echo "Benchmark configuration not found: $CONFIG_FILE" >&2
    exit 1
  }
  # The operator-owned file contains paths only and remains outside Git.
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

INSTALL_ROOT=${BENCHMARK_INSTALL_ROOT:-"$HOME/.local/share/cli-benchmark"}
OUTPUT=${BENCHMARK_OUTPUT:-"$ROOT/output/agent-cli-benchmark"}
AGENTS=${BENCHMARK_AGENTS:-"opencode pi copilot moltis hermes crush openclaw"}
OPENCODE_AUTH_FILE=${OPENCODE_AUTH_FILE:-"$HOME/.local/share/opencode/auth.json"}
PI_AUTH_DIR=${PI_AUTH_DIR:-"$HOME/.pi/agent"}
COPILOT_HOME=${COPILOT_HOME:-"$HOME/.copilot"}
MOLTIS_AUTH_CONFIG_DIR=${MOLTIS_AUTH_CONFIG_DIR:-"$HOME/.config/moltis"}
HERMES_AUTH_FILE=${HERMES_AUTH_FILE:-"$HOME/.hermes/auth.json"}
CRUSH_CONFIG_DIR=${CRUSH_CONFIG_DIR:-"$ROOT/benchmark-config/crush"}
CRUSH_DATA_DIR=${CRUSH_DATA_DIR:-"$HOME/.local/share/crush"}
OPENCLAW_STATE_DIR=${OPENCLAW_STATE_DIR:-"$HOME/.openclaw"}

HARNESS="$ROOT/benchmark-agent-clis.py"
ACP_CLIENT="$ROOT/moltis-acp-client.py"
REPORT="$OUTPUT/benchmark-report.md"
RUNTIME_ROOT=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/agent-cli-benchmark.XXXXXX")
OPENCODE_AUTH="$RUNTIME_ROOT/opencode"
HERMES_HOME="$RUNTIME_ROOT/hermes"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/agent-cli-benchmark-${UID}.lock"
MARKER_FILE="$LOCK_FILE.marker"
RUN_ID=

cleanup() {
  rm -rf -- "$RUNTIME_ROOT"
  if [[ -n "$RUN_ID" && -f "$MARKER_FILE" ]] &&
    [[ $(< "$MARKER_FILE") == "$RUN_ID" ]]; then
    rm -f -- "$MARKER_FILE"
  fi
}
trap cleanup EXIT

exec 9>"$LOCK_FILE"
flock -n 9 || {
  echo "Another agent CLI benchmark is already running for this user." >&2
  exit 1
}
PREVIOUS_RUN_ID=
if [[ -f "$MARKER_FILE" ]]; then
  read -r PREVIOUS_RUN_ID < "$MARKER_FILE" || true
fi
RUN_ID=$(< /proc/sys/kernel/random/uuid)
printf '%s\n' "$RUN_ID" > "$MARKER_FILE"

for required in \
  "$HARNESS" \
  "$ACP_CLIENT" \
  "$ROOT/benchmark_tasks.py" \
  "$ROOT/generate-benchmark-report.py"; do
  [[ -f "$required" ]] || {
    echo "Missing required benchmark file: $required" >&2
    exit 1
  }
done

case "$(realpath -m "$OUTPUT")" in
  "$ROOT/output"/*) ;;
  *)
    echo "BENCHMARK_OUTPUT must be inside $ROOT/output" >&2
    exit 1
    ;;
esac

declare -a ONLY_ARGS=()
for agent in $AGENTS; do
  case "$agent" in
    opencode | pi | copilot | moltis | hermes | crush | openclaw | codex | claude)
      ;;
    *)
      echo "Unknown agent in BENCHMARK_AGENTS: $agent" >&2
      exit 1
      ;;
  esac
  ONLY_ARGS+=(--only "$agent")
done

echo "Stopping stale benchmark-owned processes..."
python3 - "$PREVIOUS_RUN_ID" <<'PY'
import os
import pathlib
import signal
import sys
import time

run_id = sys.argv[1]
marker = f"AGENT_CLI_BENCHMARK={run_id}".encode()
own = {os.getpid()}
pid = os.getppid()
while pid > 1:
    own.add(pid)
    try:
        pid = int(pathlib.Path(f"/proc/{pid}/stat").read_text().split()[3])
    except (FileNotFoundError, IndexError, ValueError):
        break


def benchmark_pids():
    found = []
    for entry in pathlib.Path("/proc").iterdir():
        if not entry.name.isdigit() or int(entry.name) in own:
            continue
        try:
            command = (entry / "cmdline").read_bytes().replace(b"\0", b" ").decode(
                errors="replace"
            )
            environment = (entry / "environ").read_bytes().split(b"\0")
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        if run_id and marker in environment:
            found.append(int(entry.name))
    return sorted(found)


stale = benchmark_pids()
for candidate in stale:
    try:
        os.kill(candidate, signal.SIGTERM)
    except ProcessLookupError:
        pass

deadline = time.monotonic() + 5
while time.monotonic() < deadline and benchmark_pids():
    time.sleep(0.1)

remaining = benchmark_pids()
for candidate in remaining:
    try:
        os.kill(candidate, signal.SIGKILL)
    except ProcessLookupError:
        pass

print(f"Stopped {len(stale)} stale process(es); forced {len(remaining)}.")
PY

rm -rf -- "$OUTPUT"
install -d -m 0700 \
  "$OUTPUT" \
  "$OPENCODE_AUTH/config" \
  "$OPENCODE_AUTH/data/opencode" \
  "$HERMES_HOME"

if [[ " $AGENTS " == *" opencode "* && -f "$OPENCODE_AUTH_FILE" ]]; then
  install -m 0600 "$OPENCODE_AUTH_FILE" "$OPENCODE_AUTH/data/opencode/auth.json"
fi
if [[ " $AGENTS " == *" hermes "* && -f "$HERMES_AUTH_FILE" ]]; then
  install -m 0600 "$HERMES_AUTH_FILE" "$HERMES_HOME/auth.json"
fi

echo "Starting serial benchmark at $(date --iso-8601=seconds)"
echo "Agents: $AGENTS"
echo "Output directory: $OUTPUT"

AGENT_CLI_BENCHMARK="$RUN_ID" python3 "$HARNESS" \
  --runs 1 \
  --skip-warmup \
  --task composite-suite \
  --timeout 300 \
  --output "$OUTPUT" \
  --install-root "$INSTALL_ROOT" \
  --opencode-auth-root "$OPENCODE_AUTH" \
  --opencode-model gpt-5.6-luna \
  --opencode-variant medium \
  --opencode-model-override \
  --pi-auth-dir "$PI_AUTH_DIR" \
  --pi-model gpt-5.6-luna \
  --pi-thinking medium \
  --copilot-home "$COPILOT_HOME" \
  --copilot-model gpt-5.6-luna \
  --copilot-reasoning-effort medium \
  --moltis-auth-config-dir "$MOLTIS_AUTH_CONFIG_DIR" \
  --moltis-data-dir "$OUTPUT/moltis-data" \
  --moltis-model gpt-5.6-luna \
  --moltis-thinking medium \
  --hermes-home "$HERMES_HOME" \
  --hermes-model gpt-5.6-luna \
  --hermes-reasoning medium \
  --crush-config-dir "$CRUSH_CONFIG_DIR" \
  --crush-data-dir "$CRUSH_DATA_DIR" \
  --crush-model copilot/gpt-5.6-luna \
  --openclaw-state-dir "$OPENCLAW_STATE_DIR" \
  --openclaw-model github-copilot/gpt-5.6-luna \
  --openclaw-thinking medium \
  "${ONLY_ARGS[@]}"

python3 "$ROOT/generate-benchmark-report.py" "$OUTPUT/results.json" "$REPORT"
