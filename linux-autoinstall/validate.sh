#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/ai-node-linux-validate.XXXXXX")
trap 'find "$work" -depth -delete' EXIT

for script in "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/assets/*; do
  [[ -x "$script" || "$script" == *.sh ]] || continue
  if head -n 1 "$script" | grep -Fq 'python'; then
    PYTHONPYCACHEPREFIX="$work/pycache" python3 -m py_compile "$script"
  else
    bash -n "$script"
  fi
done
for python_script in "$SCRIPT_DIR"/*.py; do
  PYTHONPYCACHEPREFIX="$work/pycache" python3 -m py_compile "$python_script"
done
PYTHONPYCACHEPREFIX="$work/pycache" \
  python3 -m unittest discover -s "$SCRIPT_DIR" -p 'test_*.py'

python3 "$SCRIPT_DIR/config.py" validate \
  --config "$SCRIPT_DIR/config.example.env"
[[ "$(python3 "$SCRIPT_DIR/config.py" get \
  --config "$SCRIPT_DIR/config.example.env" \
  --key SYSTEM_DISK)" == "auto" ]]

printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestOnlyValidationKey node-admin\n' \
  > "$work/ssh-public-key"
printf 'Validation Network\n' > "$work/wifi-ssid"
printf 'validation-passphrase\n' > "$work/wifi-password"
printf 'WIFI_BOOT\n' > "$work/adversarial-wifi-ssid"
printf 'AI_NODE_RUNTIME_HOSTNAME__TIMEZONE__\n' \
  > "$work/adversarial-wifi-password"

render() {
  local output=$1
  shift
  "$SCRIPT_DIR/render-autoinstall.py" \
    --template "$SCRIPT_DIR/autoinstall.yaml.in" \
    --output "$output" \
    --ssh-public-key-file "$work/ssh-public-key" \
    --password-hash '$6$validation$not-a-real-password-hash' \
    --node-name-prefix lin \
    --admin-user node-admin \
    --timezone Etc/UTC \
    --system-disk-policy auto \
    --preferred-min-target-disk-bytes 60000000000 \
    --minimum-system-disk-bytes 33179869184 \
    "$@"
}

render "$work/ethernet.yaml"
render "$work/wifi.yaml" \
  --wifi-ssid-file "$work/wifi-ssid" \
  --wifi-password-file "$work/wifi-password"
render "$work/dual.yaml" --data-mount /srv/data
render "$work/fallback.yaml" --interactive-storage
render "$work/adversarial.yaml" \
  --wifi-ssid-file "$work/adversarial-wifi-ssid" \
  --wifi-password-file "$work/adversarial-wifi-password"

python3 - \
  "$work/ethernet.yaml" \
  "$work/wifi.yaml" \
  "$work/dual.yaml" \
  "$work/fallback.yaml" \
  "$work/adversarial.yaml" <<'PY'
from pathlib import Path
import sys

ethernet, wifi, dual, fallback, adversarial = (
    Path(path).read_text() for path in sys.argv[1:]
)
for name, text in (
    ("ethernet", ethernet),
    ("wifi", wifi),
    ("dual", dual),
    ("fallback", fallback),
):
    if "__" in text:
        raise SystemExit(f"{name}: unresolved template marker")
    if 'layout: us' not in text or 'locale: en_US.UTF-8' not in text:
        raise SystemExit(f"{name}: expected US locale configuration missing")
    if "hostname: AI_NODE_RUNTIME_HOSTNAME" not in text:
        raise SystemExit(f"{name}: runtime hostname placeholder missing")
    if "allow-pw: false" not in text:
        raise SystemExit(f"{name}: SSH password authentication is enabled")

if "interactive-sections: []" not in ethernet:
    raise SystemExit("ethernet: unattended installation disabled")
if "AI_NODE_RUNTIME_SYSTEM_DISK" not in ethernet:
    raise SystemExit("ethernet: runtime system-disk token missing")
if "AI_NODE_RUNTIME_DATA_STORAGE" in ethernet or "disk-data" in ethernet:
    raise SystemExit("ethernet: unexpected data-disk configuration")
if "AI_NODE_WIFI_INTERFACE" in ethernet or "wpasupplicant" in ethernet:
    raise SystemExit("ethernet: unexpected Wi-Fi configuration")

if "AI_NODE_WIFI_INTERFACE" not in wifi or "Validation Network" not in wifi:
    raise SystemExit("wifi: embedded Wi-Fi configuration missing")
if "/tmp/60-ai-node-wifi.yaml" not in wifi or "wpasupplicant" not in wifi:
    raise SystemExit("wifi: persistent Wi-Fi setup missing")

if "AI_NODE_RUNTIME_DATA_STORAGE" in dual or "disk-data" in dual:
    raise SystemExit("dual: data-disk configuration must be added at runtime")
if "--data-mount /srv/data" not in dual:
    raise SystemExit("dual: data-mount policy missing")

if "interactive-sections: [storage]" not in fallback:
    raise SystemExit("fallback: interactive storage section missing")
if "AI_NODE_RUNTIME_SYSTEM_DISK" in fallback or "disk-system" in fallback:
    raise SystemExit("fallback: destructive storage configuration remains")
if "layout:\n      name: direct" not in fallback:
    raise SystemExit("fallback: safe direct layout missing")

if '"WIFI_BOOT":' not in adversarial:
    raise SystemExit("adversarial: SSID was changed during rendering")
if 'password: "AI_NODE_RUNTIME_HOSTNAME__TIMEZONE__"' not in adversarial:
    raise SystemExit("adversarial: password was reprocessed as a template token")
PY

cp "$work/dual.yaml" "$work/dual-runtime.yaml"
PYTHONPYCACHEPREFIX="$work/pycache" python3 - \
  "$SCRIPT_DIR" \
  "$work/dual-runtime.yaml" <<'PY'
from pathlib import Path
import sys
import yaml

sys.path.insert(0, sys.argv[1])
from diskselector import Disk, rewrite_autoinstall


def disk(path):
    return Disk(
        path=path,
        size_bytes=500 * 1024**3,
        transport="sata",
        removable=False,
        read_only=False,
        rotational=True,
        hotplug=False,
        aliases=frozenset({path}),
        installer_backing=False,
    )


path = Path(sys.argv[2])
# Reproduce Subiquity's parse-and-dump normalization before early commands.
path.write_text(
    yaml.safe_dump(yaml.safe_load(path.read_text()), sort_keys=False)
)
rewrite_autoinstall(
    path,
    disk("/dev/nvme0n1"),
    [disk("/dev/sda"), disk("/dev/sdb")],
    "/srv/data",
)
document = yaml.safe_load(path.read_text())
config = document["autoinstall"]["storage"]["config"]
disks = {
    entry["id"]: entry["path"]
    for entry in config
    if entry["type"] == "disk"
}
mounts = {
    entry["id"]: entry["path"]
    for entry in config
    if entry["type"] == "mount"
}
assert disks["disk-system"] == "/dev/nvme0n1"
assert disks["disk-data-1"] == "/dev/sda"
assert disks["disk-data-2"] == "/dev/sdb"
assert mounts["mount-data-1"] == "/srv/data"
assert mounts["mount-data-2"] == "/srv/data2"
assert "AI_NODE_RUNTIME_SYSTEM_DISK" not in path.read_text()
PY

generated_password=$(
  "$SCRIPT_DIR/generate-password.py" \
    --word-list "$SCRIPT_DIR/assets/eff-large-wordlist.txt"
)
[[ "$generated_password" =~ ^[A-Z][a-z]+-[A-Z][a-z]+-[A-Z][a-z]+-[0-9]{4}$ ]]
generated_node_name=$("$SCRIPT_DIR/assets/generate-node-name" lin)
[[ "$generated_node_name" =~ ^lin-[a-z]+-[a-z]+$ ]]

mkdir -p "$work/tailscale-success"
cat > "$work/tailscale-success/tailscale" <<'SH'
#!/bin/bash
set -euo pipefail
state_file=${FAKE_TAILSCALE_STATE_FILE:?}
case "$1" in
  status)
    if [[ -f "$state_file" ]]; then
      printf '{"BackendState":"Running"}\n'
    else
      printf '{"BackendState":"NeedsLogin"}\n'
    fi
    ;;
  up)
    [[ "$2" == "--auth-key=file:"* ]]
    : > "$state_file"
    ;;
  *)
    exit 64
    ;;
esac
SH
chmod 0755 "$work/tailscale-success/tailscale"
printf 'tskey-auth-validation\n' > "$work/tailscale-auth-key"
FAKE_TAILSCALE_STATE_FILE="$work/tailscale-state" \
AI_NODE_TAILSCALE_AUTH_KEY_FILE="$work/tailscale-auth-key" \
AI_NODE_TAILSCALE_BIN="$work/tailscale-success/tailscale" \
  "$SCRIPT_DIR/assets/enroll-tailscale"
[[ -f "$work/tailscale-state" && ! -e "$work/tailscale-auth-key" ]]

cat > "$work/tailscale-failure" <<'SH'
#!/bin/bash
exit 1
SH
chmod 0755 "$work/tailscale-failure"
printf 'tskey-auth-validation\n' > "$work/tailscale-auth-key"
if AI_NODE_TAILSCALE_AUTH_KEY_FILE="$work/tailscale-auth-key" \
  AI_NODE_TAILSCALE_BIN="$work/tailscale-failure" \
  "$SCRIPT_DIR/assets/enroll-tailscale"; then
  echo "Tailscale enrollment unexpectedly succeeded" >&2
  exit 1
fi
[[ -s "$work/tailscale-auth-key" ]]

grep -Fq 'NODE_NAME_PREFIX=lin' "$SCRIPT_DIR/config.example.env"
grep -Fq 'SYSTEM_DISK=auto' "$SCRIPT_DIR/config.example.env"
grep -Fq 'PREFERRED_MIN_TARGET_DISK_BYTES=60000000000' \
  "$SCRIPT_DIR/config.example.env"
grep -Fq 'PasswordAuthentication no' "$SCRIPT_DIR/assets/ssh-access.conf.in"
grep -Fq 'storage-fallback-user-data' "$SCRIPT_DIR/render-autoinstall.py"
grep -Fq 'ai-node-tailscale-enroll.service' \
  "$SCRIPT_DIR/autoinstall.yaml.in"
grep -Fq -- '--auth-key="file:$key_file"' \
  "$SCRIPT_DIR/assets/enroll-tailscale"
grep -Fq 'BackendState' "$SCRIPT_DIR/assets/enroll-tailscale"
grep -Fq 'rm -f "$key_file"' "$SCRIPT_DIR/assets/enroll-tailscale"
grep -Fq 'Restart=on-failure' \
  "$SCRIPT_DIR/assets/ai-node-tailscale-enroll.service"
if grep -Fq 'Requires=tailscaled.service' \
  "$SCRIPT_DIR/assets/ai-node-tailscale-enroll.service"; then
  echo "Tailscale enrollment retries are blocked by a hard service dependency" >&2
  exit 1
fi
grep -Fq 'generate-password.py' "$SCRIPT_DIR/build-image.sh"
[[ "$(grep -c 'autoinstall noprompt' "$SCRIPT_DIR/build-image.sh")" -eq 2 ]]
grep -Fq 'recovery report already exists; refusing to overwrite' \
  "$SCRIPT_DIR/build-image.sh"
grep -Fq 'ln "$report_tmp" "$recovery_report"' \
  "$SCRIPT_DIR/build-image.sh"
grep -Fq 'config.py" validate' "$SCRIPT_DIR/build-image.sh"
grep -Fq -- '--tailscale-deb FILE' "$SCRIPT_DIR/build-image.sh"
grep -Fq 'wifi_enabled=false' "$SCRIPT_DIR/build-image.sh"
grep -Fq 'diskselector.py' "$SCRIPT_DIR/build-image.sh"
grep -Fq 'configure-wifi.py' "$SCRIPT_DIR/build-image.sh"
grep -Fq -- '--persistent-output /tmp/60-ai-node-wifi.yaml' \
  "$SCRIPT_DIR/render-autoinstall.py"
if grep -R -Fq 'DATA_DISK' \
  "$SCRIPT_DIR/config.py" \
  "$SCRIPT_DIR/config.example.env" \
  "$SCRIPT_DIR/build-image.sh" \
  "$SCRIPT_DIR/render-autoinstall.py" \
  "$SCRIPT_DIR/README.md"; then
  echo "Linux installer still exposes a secondary-disk preservation policy" >&2
  exit 1
fi
if grep -Fq -- '--data-policy' "$SCRIPT_DIR/diskselector.py"; then
  echo "Linux disk selector still accepts a secondary-disk policy" >&2
  exit 1
fi
grep -Fq 'media remains attached' "$SCRIPT_DIR/flash-image.sh"
if grep -Fq 'diskutil eject' "$SCRIPT_DIR/flash-image.sh"; then
  echo "Linux flasher still ejects media automatically" >&2
  exit 1
fi
grep -Fq 'Package:[[:space:]]+tailscale' "$SCRIPT_DIR/build-image.sh"
grep -Fq 'Architecture:[[:space:]]+amd64' "$SCRIPT_DIR/build-image.sh"
grep -Fq 'apt-get install -y /tmp/tailscale.deb' \
  "$SCRIPT_DIR/autoinstall.yaml.in"
grep -Fq 'Tailscale %s' "$SCRIPT_DIR/assets/render-console-health"
if grep -Eq '(^|[[:space:]])\.[[:space:]]+"\$config_file"' \
  "$SCRIPT_DIR/build-image.sh"; then
  echo "Linux builder still sources its configuration as shell code" >&2
  exit 1
fi
if grep -Fq 'controller-password' "$SCRIPT_DIR/build-image.sh"; then
  echo "Linux builder still requires a manually supplied controller password" >&2
  exit 1
fi
grep -Fq 'self.brightness_path.write_text("0\n")' \
  "$SCRIPT_DIR/assets/manage-console-backlight"
grep -Fq 'INPUT_KEYWORDS = ("keyboard", "mouse", "touchpad", "hotkeys")' \
  "$SCRIPT_DIR/assets/manage-console-backlight"
grep -Fq 'ai-node-console-power.service' "$SCRIPT_DIR/autoinstall.yaml.in"
grep -Fq 'ConditionDirectoryNotEmpty=/sys/class/backlight' \
  "$SCRIPT_DIR/assets/ai-node-console-power.service"

if command -v ruby >/dev/null 2>&1; then
  ruby -e 'require "yaml"; ARGV.each { |path| YAML.safe_load(File.read(path), aliases: true) }' \
    "$work/ethernet.yaml" "$work/wifi.yaml" "$work/dual.yaml" \
    "$work/dual-runtime.yaml" "$work/fallback.yaml" "$work/adversarial.yaml"
fi

echo "Linux installer validation passed."
