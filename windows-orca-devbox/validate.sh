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

for script in "$SCRIPT_DIR/connect-rdp.sh" "$SCRIPT_DIR/deploy.sh" "$SCRIPT_DIR/validate.sh"; do
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
connect_rdp = (root / "connect-rdp.sh").read_text()
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
assert "Add-LocalGroupMember -Group $administratorsGroup -Member $worker" in install
assert "Grant-BatchLogonRight" in install
assert "SeBatchLogonRight" in install
assert '"/areas", "USER_RIGHTS"' in install
assert "Get-VerifiedInstaller" in install
assert "Get-FileHash" in install
assert "checksum mismatch" in install
assert "Start-Process" in install
assert "-Wait" in install
assert "-PassThru" in install
assert "orca-windows-setup.exe" in install
assert "Git-2.55.0.3-64-bit.exe" in install
assert "node-v$nodeVersion-x64.msi" in install
assert "python-$pythonVersion-amd64.exe" in install
assert "gh_$($githubCliVersion)_windows_amd64.msi" in install
assert "winget.exe" not in install
assert "RemoteAddress LocalSubnet" in install
assert "Stop-ScheduledTask" in install
assert "GetOwnerSid" in install
assert "Register-ScheduledTask" in install
assert "-RunLevel Highest" in install
assert '$dashboardFirewallRuleName = "Reddit archive progress dashboard"' in install
assert "-LocalPort 8765" in install
assert '-RemoteAddress @("LocalSubnet", "100.64.0.0/10")' in install
assert "Remove-Item -LiteralPath $WorkerPasswordFile" in install
assert "C:\\Orca\\workspaces" in install

elevate = (root / "elevate-worker.ps1").read_text()
assert "Add-LocalGroupMember -Group $administratorsGroup -Member $worker" in elevate
assert "Register-ScheduledTask" in elevate
assert "-RunLevel Highest" in elevate
assert "-LocalPort 8765" in elevate
assert "Existing Orca worker processes did not stop cleanly" in elevate
assert "Remove-Item -LiteralPath $WorkerPasswordFile" in elevate

assert "C:\\ProgramData\\OrcaDevbox" in serve
assert "Orca runtime must start with an elevated administrator token" in serve
assert "--pairing-address" in serve
assert "--json" in serve
assert "orca.exe" in serve
assert "GitHub CLI" in serve

assert "openssl rand -hex 24" in deploy
assert "orca environment add" in deploy
assert "orca environment rm" in deploy
assert 'orca status --environment "$environment_name"' in deploy
assert "chmod 0600" in deploy
assert "sdl-freerdp" in connect_rdp
assert "/args-from:env:RDP_ARGS" in connect_rdp
assert "/cert:ignore" in connect_rdp
assert "-clipboard" in connect_rdp
assert "confirm_tailscale" in connect_rdp
assert "8#$permissions & 077" in connect_rdp
assert "Administrator password: " in connect_rdp
assert "worker_password" not in readme
assert "local Administrators group" in readme
assert "`TCP 8765`" in readme
PY

echo "Windows Orca devbox validation passed."
