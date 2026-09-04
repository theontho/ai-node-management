#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
work="$SCRIPT_DIR/local/.validate-work.$$"
mkdir -p "$work"

cleanup() {
  if [[ -d "$work" && "$work" == "$SCRIPT_DIR"/local/.validate-work.* ]]; then
    find "$work" -depth -delete
  fi
}
trap cleanup EXIT

for script in "$SCRIPT_DIR/deploy.sh" "$SCRIPT_DIR/validate.sh"; do
  bash -n "$script"
  shellcheck "$script"
done

if command -v pwsh >/dev/null; then
  # PowerShell, rather than Bash, expands variables inside this command.
  # shellcheck disable=SC2016
  pwsh -NoLogo -NoProfile -Command '
    $ErrorActionPreference = "Stop"
    Get-ChildItem -LiteralPath "'"$SCRIPT_DIR"'" -Filter "*.ps1" |
      ForEach-Object {
        [void][scriptblock]::Create((Get-Content -LiteralPath $_.FullName -Raw))
      }
  '
fi

python3 - "$SCRIPT_DIR" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
install = (root / "install.ps1").read_text()
serve = (root / "serve.ps1").read_text()
deploy = (root / "deploy.sh").read_text()
readme = (root / "README.md").read_text()

for value in (
    'orcaVersion = "1.4.196"',
    'gitVersion = "2.55.0.3"',
    'nodeVersion = "24.19.0"',
    'pythonVersion = "3.13.15"',
    'githubCliVersion = "2.100.0"',
    'copilotCliVersion = "1.0.82"',
):
    assert value in install

assert '$workerName = "orca-worker"' in install
assert 'Get-LocalGroup -SID "S-1-5-32-544"' in install
assert "must not be a member of the local Administrators group" in install
assert "Grant-BatchLogonRight" in install
assert "SeBatchLogonRight" in install
assert '"/areas", "USER_RIGHTS"' in install
assert '"StablyAI.Orca"' in install
assert '"Git.Git"' in install
assert '"OpenJS.NodeJS.LTS"' in install
assert '"Python.Python.3.13"' in install
assert '"GitHub.cli"' in install
assert "RemoteAddress LocalSubnet" in install
assert "Stop-ScheduledTask" in install
assert "Register-ScheduledTask" in install
assert "-RunLevel Limited" in install
assert "Remove-Item -LiteralPath $WorkerPasswordFile" in install
assert "C:\\Orca\\workspaces" in install

assert "C:\\ProgramData\\OrcaDevbox" in serve
assert "--pairing-address" in serve
assert "--json" in serve
assert "orca.exe" in serve
assert "GitHub CLI" in serve

assert "openssl rand -hex 24" in deploy
assert "orca environment add" in deploy
assert "orca environment rm" in deploy
assert 'orca status --environment "$environment_name"' in deploy
assert "chmod 0600" in deploy
assert "worker_password" not in readme
assert "does not receive administrator rights" in readme
PY

echo "Windows Orca devbox validation passed."
