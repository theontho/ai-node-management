#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

usage() {
  cat >&2 <<'EOF'
usage: deploy.sh \
  --host USER@HOST \
  --pairing-address HOST \
  --environment-name NAME \
  --recovery-report FILE \
  [--port INTEGER]
EOF
  exit 64
}

ssh_target=
pairing_address=
environment_name=
recovery_report=
port=6768

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --host) ssh_target=$2; shift 2 ;;
    --pairing-address) pairing_address=$2; shift 2 ;;
    --environment-name) environment_name=$2; shift 2 ;;
    --recovery-report) recovery_report=$2; shift 2 ;;
    --port) port=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$ssh_target" && "$ssh_target" != -* && "$ssh_target" != *[[:space:]]* ]] || usage
[[ "$pairing_address" =~ ^[A-Za-z0-9.-]+$ ]] || usage
[[ "$environment_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] || usage
[[ -n "$recovery_report" ]] || usage
[[ "$port" =~ ^[0-9]+$ && "$port" -ge 1024 && "$port" -le 65535 ]] || usage

for command_name in openssl orca scp ssh; do
  command -v "$command_name" >/dev/null || {
    echo "missing required command: $command_name" >&2
    exit 1
  }
done

mkdir -p "$SCRIPT_DIR/local" "$(dirname "$recovery_report")"
work="$SCRIPT_DIR/local/.deploy-work.$$"
remote_stage="C:/Windows/Temp/OrcaDevboxDeploy-$$"
password_file="$work/worker-password"
pairing_file="$work/pairing-code"
report_tmp="${recovery_report}.partial.$$"
mkdir -m 0700 "$work"

cleanup() {
  ssh -o BatchMode=yes "$ssh_target" \
    "Remove-Item -LiteralPath '$remote_stage' -Recurse -Force -ErrorAction SilentlyContinue" \
    >/dev/null 2>&1 || true
  if [[ -d "$work" && "$work" == "$SCRIPT_DIR"/local/.deploy-work.* ]]; then
    find "$work" -depth -delete
  fi
  if [[ -f "$report_tmp" && "$report_tmp" == "$recovery_report".partial.* ]]; then
    rm -f "$report_tmp"
  fi
}
trap cleanup EXIT

umask 077
worker_password=$(openssl rand -hex 24)
printf '%s\n' "$worker_password" > "$password_file"

ssh -o BatchMode=yes "$ssh_target" \
  "New-Item -ItemType Directory -Force -Path '$remote_stage' | Out-Null"
scp -q \
  "$SCRIPT_DIR/install.ps1" \
  "$SCRIPT_DIR/serve.ps1" \
  "$password_file" \
  "$ssh_target:$remote_stage/"

ssh -o BatchMode=yes "$ssh_target" \
  "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '$remote_stage/install.ps1' -WorkerPasswordFile '$remote_stage/worker-password' -PairingAddress '$pairing_address' -Port '$port'"

for _ in {1..30}; do
  if ssh -o BatchMode=yes "$ssh_target" \
    "Get-Content -LiteralPath 'C:/ProgramData/OrcaDevbox/logs/serve.log' -ErrorAction SilentlyContinue | ForEach-Object { try { (\$_ | ConvertFrom-Json).pairing.url } catch {} } | Where-Object { \$_ -like 'orca://pair*' } | Select-Object -Last 1" \
    | tr -d '\r' > "$pairing_file" &&
    grep -Eq '^orca://pair\?code=[A-Za-z0-9._~%+/=&?-]+$' "$pairing_file"; then
    break
  fi
  sleep 2
done
grep -Eq '^orca://pair\?code=[A-Za-z0-9._~%+/=&?-]+$' "$pairing_file" || {
  echo "Orca pairing code was not produced" >&2
  exit 1
}

pairing_code=$(tr -d '\r\n' < "$pairing_file")
if orca environment show --environment "$environment_name" --json >/dev/null 2>&1; then
  if ! orca status --environment "$environment_name" --json >/dev/null 2>&1; then
    orca environment rm --environment "$environment_name" --json >/dev/null
    orca environment add \
      --name "$environment_name" \
      --pairing-code "$pairing_code" \
      --json >/dev/null
  fi
else
  orca environment add \
    --name "$environment_name" \
    --pairing-code "$pairing_code" \
    --json >/dev/null
fi
orca status --environment "$environment_name" --json >/dev/null

cat > "$report_tmp" <<EOF
Windows Orca devbox recovery information

Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
Host: $pairing_address
Orca environment: $environment_name
Runtime account: orca-worker
Runtime account password: $worker_password
Runtime account privileges: standard local user; not an administrator
Runtime endpoint: ws://$pairing_address:$port
Workspace root: C:\\Orca\\workspaces

This report contains a credential. Keep it private.
EOF
chmod 0600 "$report_tmp"
mv "$report_tmp" "$recovery_report"
report_tmp=

echo "WINBOX is configured and associated as Orca environment: $environment_name"
