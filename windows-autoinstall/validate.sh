#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
work="$SCRIPT_DIR/.validate-work.$$"
mkdir "$work"
export PYTHONPYCACHEPREFIX="$work/pycache"

cleanup() {
  if [[ -d "$work" && "$work" == "$SCRIPT_DIR"/.validate-work.* ]]; then
    find "$work" -depth -delete
  fi
}
trap cleanup EXIT

for script in \
  "$SCRIPT_DIR/build-image.sh" \
  "$SCRIPT_DIR/build-existing-setup.sh" \
  "$SCRIPT_DIR/flash-image.sh" \
  "$SCRIPT_DIR/validate.sh"; do
  bash -n "$script"
  shellcheck "$script"
done

xmllint --noout "$SCRIPT_DIR/autounattend.xml.in"
python3 "$SCRIPT_DIR/config.py" validate --config "$SCRIPT_DIR/config.example.env"
python3 "$SCRIPT_DIR/config.py" render \
  --config "$SCRIPT_DIR/config.example.env" \
  --template "$SCRIPT_DIR/autounattend.xml.in" \
  --output "$work/autounattend.xml.in" \
  --admin-password aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
xmllint --noout "$work/autounattend.xml.in"
for asset in prepare.cmd winpe-start.cmd SetupComplete.cmd provision.ps1 install-existing.ps1; do
  python3 "$SCRIPT_DIR/config.py" render \
    --config "$SCRIPT_DIR/config.example.env" \
    --template "$SCRIPT_DIR/assets/$asset" \
    --output "$work/$asset"
done
python3 "$SCRIPT_DIR/config.py" render \
  --config "$SCRIPT_DIR/config.example.env" \
  --template "$SCRIPT_DIR/assets/existing-setup-README.txt" \
  --output "$work/existing-setup-README.txt"
ssh-keygen -q -t ed25519 -N "" -f "$work/validation-key"
"$SCRIPT_DIR/build-existing-setup.sh" \
  --config "$SCRIPT_DIR/config.example.env" \
  --ssh-public-key-file "$work/validation-key.pub" \
  --output-dir "$work/existing-setup"
[[ -f "$work/existing-setup/install-existing.ps1" ]]
[[ -f "$work/existing-setup/provision.ps1" ]]
[[ -f "$work/existing-setup/SetupComplete.cmd" ]]
[[ -f "$work/existing-setup/config/ssh-public-key" ]]
[[ -f "$work/existing-setup/manifest.sha256" ]]
(
  cd "$work/existing-setup"
  shasum -a 256 -c manifest.sha256
)
if find "$work/existing-setup" -name '._*' -print -quit | grep -q .; then
  echo "existing-Windows payload contains AppleDouble metadata" >&2
  exit 1
fi
if "$SCRIPT_DIR/build-existing-setup.sh" \
  --config "$SCRIPT_DIR/config.example.env" \
  --ssh-public-key-file "$work/validation-key.pub" \
  --output-dir "$work/existing-setup" 2>/dev/null; then
  echo "existing-Windows builder overwrote an existing output directory" >&2
  exit 1
fi

if ! gofmt -d \
  "$SCRIPT_DIR/diskpolicy.go" \
  "$SCRIPT_DIR/diskpolicy_test.go" \
  "$SCRIPT_DIR/diskselector.go" > "$work/gofmt.diff"; then
  cat "$work/gofmt.diff" >&2
  exit 1
fi
if [[ -s "$work/gofmt.diff" ]]; then
  cat "$work/gofmt.diff" >&2
  exit 1
fi
go test "$SCRIPT_DIR/diskpolicy.go" "$SCRIPT_DIR/diskpolicy_test.go"
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 \
  go vet "$SCRIPT_DIR/diskselector.go" "$SCRIPT_DIR/diskpolicy.go"
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 \
  go build -trimpath -ldflags="-s -w" \
    -o "$work/diskselector.exe" \
    "$SCRIPT_DIR/diskselector.go" \
    "$SCRIPT_DIR/diskpolicy.go"
file "$work/diskselector.exe" | grep -Fq "PE32+ executable (console) x86-64"

if command -v pwsh >/dev/null; then
  # PowerShell, rather than Bash, expands variables inside this command.
  # shellcheck disable=SC2016
  pwsh -NoLogo -NoProfile -Command '
    $ErrorActionPreference = "Stop"
    Get-ChildItem -LiteralPath "'"$work"'" -Filter "*.ps1" |
      ForEach-Object {
        [void][scriptblock]::Create((Get-Content -LiteralPath $_.FullName -Raw))
      }
  '
fi

python3 - "$SCRIPT_DIR" "$work" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
work = Path(sys.argv[2])
sys.path.insert(0, str(root))
import config as config_module

answer_source = (root / "autounattend.xml.in").read_text()
prepare_source = (root / "assets" / "prepare.cmd").read_text()
setup_source = (root / "assets" / "SetupComplete.cmd").read_text()
provision_source = (root / "assets" / "provision.ps1").read_text()
answer = (work / "autounattend.xml.in").read_text()
prepare = (work / "prepare.cmd").read_text()
winpe_start = (work / "winpe-start.cmd").read_text()
setup_complete = (work / "SetupComplete.cmd").read_text()
provision = (work / "provision.ps1").read_text()
install_existing = (work / "install-existing.ps1").read_text()
existing_setup_readme = (work / "existing-setup-README.txt").read_text()
build = (root / "build-image.sh").read_text()
build_existing = (root / "build-existing-setup.sh").read_text()
flash = (root / "flash-image.sh").read_text()
winpeshl = (root / "assets" / "winpeshl.ini").read_text()
example = (root / "config.example.env").read_text()
readme = (root / "README.md").read_text()
gitignore = (root / ".gitignore").read_text()

for name, script in (("prepare.cmd", prepare), ("winpe-start.cmd", winpe_start)):
    labels = {
        line.strip()[1:].lower()
        for line in script.splitlines()
        if line.strip().startswith(":")
    }
    targets = {
        line.lower().split("goto :", 1)[1].split()[0]
        for line in script.splitlines()
        if "goto :" in line.lower()
    }
    assert targets <= labels, f"{name} has missing labels: {targets - labels}"

expected_config = {
    "COMPUTER_NAME": "AI-NODE",
    "ADMIN_USERNAME": "ai-admin",
    "TIME_ZONE": "UTC",
    "PREFERRED_MIN_TARGET_DISK_BYTES": "60000000000",
    "APP_PREFIX": "AiNode",
}
assert config_module.load_config(root / "config.example.env") == expected_config
assert "__COMPUTER_NAME_XML__" in answer_source
assert "__ADMIN_USERNAME_XML__" in answer_source
assert "__TIME_ZONE_XML__" in answer_source
assert "__ADMIN_PASSWORD_XML__" in answer_source
assert "__PREFERRED_MIN_TARGET_DISK_BYTES_CMD__" in prepare_source
assert "__APP_PREFIX_CMD__" in setup_source
for placeholder in (
    "__APP_PREFIX_PS__",
    "__COMPUTER_NAME_PS__",
    "__ADMIN_USERNAME_PS__",
):
    assert placeholder in provision_source

assert "<ComputerName>AI-NODE</ComputerName>" in answer
assert "<Name>ai-admin</Name>" in answer
assert "<TimeZone>UTC</TimeZone>" in answer
assert "<Group>Administrators</Group>" in answer
assert "<AutoLogon>" not in answer
assert "<WillWipeDisk>true</WillWipeDisk>" in answer
assert answer.count("__TARGET_DISK_ID__") == 2
assert "<DiskID>0</DiskID>" not in answer
assert "<Size>512</Size>" in answer
assert "<PartitionID>3</PartitionID>" in answer
assert set(config_module.PLACEHOLDER_RE.findall(answer)) == {"__TARGET_DISK_ID__"}

assert "diskpart.exe" in prepare
assert "diskselector.exe" in prepare
assert "AI_NODE_MEDIA" in prepare
assert winpe_start.index("ai-node-prepare.cmd") < winpe_start.index("setup.exe")
assert "ai-node-winpe-start.cmd" in winpeshl
assert '/unattend:"X:\\ai-node-autounattend.xml"' in winpe_start
assert '"%SYSTEMDRIVE%\\setup.exe"' in winpe_start
assert "--preferred-min-bytes 60000000000" in prepare
assert '--exclude-volume "%MEDIA%"' in prepare
assert '--answer-template "%MEDIA%\\ai-node\\autounattend.xml.in"' in prepare
assert "ai-node-wipe-secondary.txt" in prepare
assert "findstr" not in prepare
assert 'if not exist "X:\\ai-node-wipe-secondary.txt"' in prepare
assert ":no_secondary_disks" in prepare
assert "ordinary Windows Setup" in prepare
assert "BypassTPMCheck" in prepare
assert "BypassSecureBootCheck" in prepare
assert "BypassCPUCheck" in prepare

assert "C:\\ProgramData\\AiNode" in setup_complete
assert '/SC MINUTE /MO 5' in setup_complete
assert '/RU SYSTEM /RL HIGHEST' in setup_complete
assert 'schtasks.exe /Run /TN "AiNode-Provision"' in setup_complete

assert '$appPrefix = "AiNode"' in provision
assert '$computerName = "AI-NODE"' in provision
assert '$administratorUsername = "ai-admin"' in provision
assert 'OpenSSH.Server~~~~0.0.1.0' in provision
assert "Get-Service -Name sshd" in provision
assert 'netsh.exe wlan add profile' in provision
assert '"PasswordAuthentication no"' in provision
assert '"AllowUsers $administratorUsername"' in provision
assert '"LocalAccountTokenFilterPolicy"' in provision
assert '"ConsentPromptBehaviorAdmin"' in provision
assert '"standby-timeout-ac", "0"' in provision
assert '"hibernate-timeout-ac", "0"' in provision
assert r'$env:WINDIR\System32\OpenSSH\sshd.exe' in provision
assert r'$env:ProgramFiles\OpenSSH\sshd.exe' in provision
assert "Could not find sshd.exe" in provision
assert 'LocalSubnet' in provision
assert 'Unregister-ScheduledTask -TaskName "$appPrefix-Provision"' in provision

assert '$appPrefix = "AiNode"' in install_existing
assert '$computerName = "AI-NODE"' in install_existing
assert '$administratorUsername = "ai-admin"' in install_existing
assert "Test-IsAdministrator" in install_existing
assert 'Get-LocalGroup -SID "S-1-5-32-544"' in install_existing
assert "manifest.sha256" in install_existing
assert "Get-FileHash" in install_existing
assert "This payload targets" in install_existing
assert "is already provisioned" in install_existing
assert 'Unregister-ScheduledTask -TaskName "$appPrefix-Provision"' in install_existing
assert '"Microsoft.OpenSSH.Preview"' in install_existing
assert '"--source", "winget"' in install_existing
assert "WinGet could not install OpenSSH" in install_existing
assert "SetupComplete.cmd" in install_existing
assert r"C:\ProgramData\AiNode\state\remote-ready.txt" in existing_setup_readme
assert "installs Microsoft OpenSSH with WinGet" in existing_setup_readme

assert "--config FILE" in build
assert 'config.py" validate --config "$config_file"' in build
assert 'config.py" render' in build
assert "-layout MBRSPUD" in build
assert "-layout GPTSPUD" not in build
assert "COPYFILE_DISABLE=1" in build
assert "copy_windows_text" in build
assert "unexpected AppleDouble metadata" in build
assert "auto-discovered root answer template" in build
assert '$generated/ai-node/autounattend.xml.in' in build
assert 'install -m 0600 "$private_dir/ssh-public-key"' in build
assert "wimlib-imagex split" in build
assert "wimlib-imagex update" in build
assert "winpeshl.ini" in build
assert "diskselector.go" in build
assert "diskpolicy.go" in build
assert "ai-node-diskselector.exe" in build
assert "AI_NODE_MEDIA" in build
assert "artifact-dir" not in build
assert "recipient" not in build
assert "wipe-media" not in build

assert "--ssh-public-key-file FILE" in build_existing
assert "--output-dir DIR" in build_existing
assert "refusing to overwrite existing output directory" in build_existing
assert "manifest.sha256" in build_existing
assert "install-existing.ps1" in build_existing
assert "SetupComplete.cmd" in build_existing
assert "provision.ps1" in build_existing
assert "diskutil" not in build_existing
assert "hdiutil" not in build_existing
assert "wimlib-imagex" not in build_existing

assert '^/dev/disk[0-9]+$' in flash
assert 'confirmation must be exactly ERASE:$device' in flash
assert "refusing non-removable device" in flash
assert "refusing internal device" in flash
assert "flashed media verification failed" in flash

assert "/local/" in gitignore
assert "/output/" in gitignore
assert "--config local/config.env" in readme
assert "build-existing-setup.sh" in readme
assert "does not format" in readme
assert "Microsoft OpenSSH through the built-in WinGet client" in readme
assert "ordinary interactive Windows Setup" in readme
assert "refuses non-removable or internal devices" in readme
for private_name in ("wifi-ssid", "wifi-password", "ssh-public-key"):
    assert not (root / private_name).exists()

def expect_invalid(name, transform):
    path = work / f"invalid-{name}.env"
    path.write_text(transform(example))
    try:
        config_module.load_config(path)
    except config_module.ConfigError:
        return
    raise AssertionError(f"unsafe config was accepted: {name}")

expect_invalid("unknown", lambda text: text + "EXTRA=value\n")
expect_invalid("duplicate", lambda text: text + "APP_PREFIX=Other\n")
expect_invalid("computer", lambda text: text.replace("AI-NODE", "node&erase"))
expect_invalid("username", lambda text: text.replace("ai-admin", "admin user"))
expect_invalid("timezone", lambda text: text.replace("TIME_ZONE=UTC", "TIME_ZONE=UTC&whoami"))
expect_invalid("bytes", lambda text: text.replace("60000000000", "sixty-billion"))
expect_invalid("prefix", lambda text: text.replace("APP_PREFIX=AiNode", "APP_PREFIX=AiNode;evil"))

bad_template = work / "bad-template.txt"
bad_template.write_text("__UNKNOWN_PLACEHOLDER__")
try:
    config_module.render_template(
        bad_template,
        work / "bad-output.txt",
        expected_config,
        None,
    )
except config_module.ConfigError:
    pass
else:
    raise AssertionError("unknown template placeholder was accepted")

behavior = "\n".join(
    (
        answer_source,
        prepare_source,
        (root / "assets" / "winpe-start.cmd").read_text(),
        setup_source,
        provision_source,
        build,
    )
).lower()
for legacy in (
    "windows" + "-box",
    "windows" + "box",
    "windows" + "-admin",
    "pacific" + " standard time",
):
    assert legacy not in behavior, legacy

for obsolete in (
    "fetch-artifacts.sh",
    "assets/Run-Untrusted.ps1",
    "assets/start-orca.ps1",
    "assets/Enter-AgentAdmin.ps1",
    "assets/send-fastmail.py",
    "diskguard.go",
):
    assert not (root / obsolete).exists(), obsolete

combined = "\n".join((answer, setup_complete, provision, build)).lower()
for removed in (
    "copilot",
    "github-cli",
    "antigravity",
    "1password",
    "fastmail",
    "windows sandbox",
):
    assert removed not in combined, removed
PY

echo "Windows unattended installer static validation passed."
