#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
VOLUME_ID=AI_NODE_LINUX

usage() {
  cat >&2 <<'EOF'
usage: build-image.sh \
  --base-iso FILE \
  --base-sha256 HEX \
  --config FILE \
  --private-dir DIR \
  --output FILE \
  [--recovery-report FILE]
EOF
  exit 64
}

base_iso=
base_sha256=
config_file=
private_dir=
output=
recovery_report=
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --base-iso) base_iso=$2; shift 2 ;;
    --base-sha256) base_sha256=$2; shift 2 ;;
    --config) config_file=$2; shift 2 ;;
    --private-dir) private_dir=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    --recovery-report) recovery_report=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ -f "$base_iso" && -f "$config_file" && -d "$private_dir" && -n "$output" ]] || usage
[[ "$base_sha256" =~ ^[0-9a-fA-F]{64}$ ]] || usage
if [[ -z "$recovery_report" ]]; then
  recovery_report="${output%.iso}-recovery.txt"
fi
[[ "$output" != "$recovery_report" ]] || {
  echo "output and recovery report must be different files" >&2
  exit 1
}

for command_name in openssl python3 shasum ssh-keygen xorriso; do
  command -v "$command_name" >/dev/null || {
    echo "missing required command: $command_name" >&2
    exit 1
  }
done

set -a
# The config is trusted operator input and is intentionally kept outside Git.
# shellcheck disable=SC1090
. "$config_file"
set +a

: "${NODE_NAME:?NODE_NAME is required}"
: "${ADMIN_USER:?ADMIN_USER is required}"
: "${TIMEZONE:?TIMEZONE is required}"
: "${SYSTEM_DISK:?SYSTEM_DISK is required}"
: "${DATA_DISK:=}"
: "${DATA_MOUNT:=/data}"
: "${SWAP_SIZE_GIB:=16}"
: "${SWAPPINESS:=10}"
: "${CONSOLE_IDLE_SECONDS:=60}"

[[ "$NODE_NAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || {
  echo "NODE_NAME must be a lowercase DNS label" >&2
  exit 1
}
[[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || {
  echo "ADMIN_USER is not a valid Linux account name" >&2
  exit 1
}
[[ "$TIMEZONE" =~ ^[A-Za-z0-9_+-]+/[A-Za-z0-9_+./-]+$ ]] \
  && [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] || {
  echo "TIMEZONE must name an installed IANA timezone" >&2
  exit 1
}
[[ "$SYSTEM_DISK" =~ ^/dev/[A-Za-z0-9._/-]+$ ]] || {
  echo "SYSTEM_DISK must be an absolute /dev path" >&2
  exit 1
}
if [[ -n "$DATA_DISK" ]]; then
  [[ "$DATA_DISK" =~ ^/dev/[A-Za-z0-9._/-]+$ && "$DATA_DISK" != "$SYSTEM_DISK" ]] || {
    echo "DATA_DISK must be a distinct absolute /dev path" >&2
    exit 1
  }
  [[ "$DATA_MOUNT" =~ ^/[A-Za-z0-9._/-]+$ && "$DATA_MOUNT" != "/" ]] || {
    echo "DATA_MOUNT must be a non-root absolute path" >&2
    exit 1
  }
fi
[[ "$SWAP_SIZE_GIB" =~ ^[0-9]+$ && "$SWAP_SIZE_GIB" -ge 1 ]] || {
  echo "SWAP_SIZE_GIB must be a positive integer" >&2
  exit 1
}
[[ "$SWAPPINESS" =~ ^[0-9]+$ && "$SWAPPINESS" -le 100 ]] || {
  echo "SWAPPINESS must be an integer from 0 through 100" >&2
  exit 1
}
[[ "$CONSOLE_IDLE_SECONDS" =~ ^[0-9]+$ ]] \
  && (( CONSOLE_IDLE_SECONDS >= 10 && CONSOLE_IDLE_SECONDS <= 3600 )) || {
  echo "CONSOLE_IDLE_SECONDS must be an integer from 10 through 3600" >&2
  exit 1
}

for required in wifi-ssid wifi-password ssh-public-key controller-password; do
  [[ -s "$private_dir/$required" ]] || {
    echo "missing private input: $private_dir/$required" >&2
    exit 1
  }
done
openssl passwd -6 preflight >/dev/null
ssh-keygen -lf "$private_dir/ssh-public-key" >/dev/null

python3 - "$private_dir/wifi-ssid" "$private_dir/wifi-password" <<'PY'
from pathlib import Path
import sys

ssid = Path(sys.argv[1]).read_text().strip()
password = Path(sys.argv[2]).read_text().strip()
if not 1 <= len(ssid.encode()) <= 32:
    raise SystemExit("Wi-Fi SSID must contain 1..32 UTF-8 bytes")
if not 8 <= len(password) <= 63:
    raise SystemExit("WPA2 passphrase must contain 8..63 characters")
if any(character in ssid + password for character in "\r\n"):
    raise SystemExit("Wi-Fi inputs must each contain one value")
PY

actual_base_sha256=$(shasum -a 256 "$base_iso" | awk '{print $1}')
normalized_actual_sha256=$(printf '%s' "$actual_base_sha256" | tr '[:upper:]' '[:lower:]')
normalized_expected_sha256=$(printf '%s' "$base_sha256" | tr '[:upper:]' '[:lower:]')
[[ "$normalized_actual_sha256" == "$normalized_expected_sha256" ]] || {
  echo "Ubuntu ISO checksum mismatch." >&2
  echo "expected: $normalized_expected_sha256" >&2
  echo "actual:   $normalized_actual_sha256" >&2
  exit 1
}

temp_root=${TMPDIR:-/tmp}
temp_root=${temp_root%/}
work=$(mktemp -d "$temp_root/ai-node-linux.XXXXXX")
output_tmp=
report_tmp=
cleanup() {
  if [[ -n "${work:-}" && -d "$work" && "$work" == "$temp_root"/* ]]; then
    find "$work" -depth -delete
  fi
  if [[ -n "${output_tmp:-}" && -f "$output_tmp" && "$output_tmp" == "$output".partial.* ]]; then
    rm -f "$output_tmp"
  fi
  if [[ -n "${report_tmp:-}" && -f "$report_tmp" && "$report_tmp" == "$recovery_report".partial.* ]]; then
    rm -f "$report_tmp"
  fi
}
trap cleanup EXIT

seed="$work/nocloud"
mkdir -p "$seed/assets"
for asset in \
  apt-noninteractive.conf \
  ai-node-console-power.service \
  ai-node-console-health.service \
  ai-node-console-health.timer \
  getty-console-health.conf; do
  install -m 0644 "$SCRIPT_DIR/assets/$asset" "$seed/assets/$asset"
done
install -m 0755 "$SCRIPT_DIR/assets/configure-swap" "$seed/assets/configure-swap"
install -m 0755 "$SCRIPT_DIR/assets/manage-console-backlight" \
  "$seed/assets/manage-console-backlight"

python3 - \
  "$SCRIPT_DIR/assets/admin-sudoers.in" \
  "$seed/assets/admin-sudoers" \
  "$SCRIPT_DIR/assets/ssh-access.conf.in" \
  "$seed/assets/ssh-access.conf" \
  "$SCRIPT_DIR/assets/debconf-selections.in" \
  "$seed/assets/debconf-selections" \
  "$ADMIN_USER" \
  "$TIMEZONE" <<'PY'
from pathlib import Path
import sys

sudo_in, sudo_out, ssh_in, ssh_out, debconf_in, debconf_out, user, timezone = sys.argv[1:]
area, zone = timezone.split("/", 1)
replacements = {
    "__ADMIN_USER__": user,
    "__TZ_AREA__": area,
    "__TZ_ZONE__": zone,
}
for source, destination in (
    (sudo_in, sudo_out),
    (ssh_in, ssh_out),
    (debconf_in, debconf_out),
):
    text = Path(source).read_text()
    for placeholder, value in replacements.items():
        text = text.replace(placeholder, value)
    if "__" in text:
        raise SystemExit(f"unresolved placeholder in {source}")
    Path(destination).write_text(text)
PY
chmod 0440 "$seed/assets/admin-sudoers"
chmod 0644 "$seed/assets/ssh-access.conf" "$seed/assets/debconf-selections"
health_data_mount=
[[ -z "$DATA_DISK" ]] || health_data_mount=$DATA_MOUNT
python3 - "$SCRIPT_DIR/assets/render-console-health" \
  "$seed/assets/render-console-health" \
  "$health_data_mount" <<'PY'
from pathlib import Path
import shlex
import sys

source, destination, data_mount = sys.argv[1:]
text = Path(source).read_text().replace(
    "__DATA_MOUNT_SHELL__", shlex.quote(data_mount)
)
if "__DATA_MOUNT_SHELL__" in text:
    raise SystemExit("unresolved data-mount placeholder")
Path(destination).write_text(text)
PY
chmod 0755 "$seed/assets/render-console-health"
printf 'SWAP_SIZE_GIB=%s\nSWAPPINESS=%s\n' "$SWAP_SIZE_GIB" "$SWAPPINESS" \
  > "$seed/assets/swap.conf"
chmod 0644 "$seed/assets/swap.conf"
printf 'CONSOLE_IDLE_SECONDS=%s\n' "$CONSOLE_IDLE_SECONDS" \
  > "$seed/assets/console-power.conf"
chmod 0644 "$seed/assets/console-power.conf"

printf 'instance-id: %s-installer\nlocal-hostname: %s\n' "$NODE_NAME" "$NODE_NAME" \
  > "$seed/meta-data"
printf '#cloud-config\n' > "$seed/vendor-data"

controller_password=$(
  python3 - "$private_dir/controller-password" <<'PY'
from pathlib import Path
import sys

value = Path(sys.argv[1]).read_text()
if value.endswith("\n"):
    value = value[:-1]
if not value or "\n" in value or "\r" in value:
    raise SystemExit("controller-password must contain exactly one non-empty line")
if len(value) < 16:
    raise SystemExit("controller-password must be at least 16 characters")
print(value, end="")
PY
)
password_hash=$(printf '%s\n' "$controller_password" | openssl passwd -6 -stdin)

"$SCRIPT_DIR/render-autoinstall.py" \
  --template "$SCRIPT_DIR/autoinstall.yaml.in" \
  --output "$seed/user-data" \
  --ssh-public-key-file "$private_dir/ssh-public-key" \
  --wifi-ssid-file "$private_dir/wifi-ssid" \
  --wifi-password-file "$private_dir/wifi-password" \
  --password-hash "$password_hash" \
  --node-name "$NODE_NAME" \
  --admin-user "$ADMIN_USER" \
  --timezone "$TIMEZONE" \
  --system-disk "$SYSTEM_DISK" \
  --data-disk "$DATA_DISK" \
  --data-mount "$DATA_MOUNT"
chmod 0600 "$seed/user-data"

cat > "$work/grub.cfg" <<EOF
if search --no-floppy --file /EFI/ubuntu/.ai-node-install-complete --set=installed; then
    set timeout=1
    set default=1
else
    set timeout=3
    set default=0
fi

loadfont unicode
set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "Install $NODE_NAME (ERASES CONFIGURED INTERNAL DISKS)" {
    set gfxpayload=keep
    linux /casper/vmlinuz autoinstall ds=nocloud\\;s=file:///cdrom/nocloud/ ---
    initrd /casper/initrd
}
menuentry "Boot installed $NODE_NAME" {
    search --no-floppy --label AI_NODE_EFI --set=root
    chainloader /EFI/ubuntu/shimx64.efi
}
EOF

cat > "$work/loopback.cfg" <<EOF
if search --no-floppy --file /EFI/ubuntu/.ai-node-install-complete --set=installed; then
    set timeout=1
    set default=1
else
    set timeout=3
    set default=0
fi

menuentry "Install $NODE_NAME (ERASES CONFIGURED INTERNAL DISKS)" {
    set gfxpayload=keep
    linux /casper/vmlinuz iso-scan/filename=\${iso_path} autoinstall ds=nocloud\\;s=file:///cdrom/nocloud/ ---
    initrd /casper/initrd
}
menuentry "Boot installed $NODE_NAME" {
    search --no-floppy --label AI_NODE_EFI --set=root
    chainloader /EFI/ubuntu/shimx64.efi
}
EOF

mkdir -p "$(dirname "$output")" "$(dirname "$recovery_report")"
output_tmp="${output}.partial.$$"
report_tmp="${recovery_report}.partial.$$"
rm -f "$output_tmp" "$report_tmp"
xorriso \
  -indev "$base_iso" \
  -outdev "$output_tmp" \
  -boot_image any replay \
  -volid "$VOLUME_ID" \
  -map "$work/grub.cfg" /boot/grub/grub.cfg \
  -map "$work/loopback.cfg" /boot/grub/loopback.cfg \
  -map "$seed" /nocloud
chmod 0600 "$output_tmp"

xorriso -osirrox on -indev "$output_tmp" \
  -extract /nocloud/user-data "$work/verify-user-data" >/dev/null 2>&1 || {
  echo "Could not verify embedded autoinstall data." >&2
  exit 1
}
cmp "$seed/user-data" "$work/verify-user-data"

{
  echo "AI node Linux recovery login"
  echo
  echo "Host: $NODE_NAME.local"
  echo "SSH/local account: $ADMIN_USER"
  echo "Password: $controller_password"
  echo "SSH public-key authentication: enabled"
  echo
  echo "System disk: $SYSTEM_DISK"
  if [[ -n "$DATA_DISK" ]]; then
    echo "Data disk: $DATA_DISK mounted at $DATA_MOUNT"
  else
    echo "Data disk: none"
  fi
  echo "Base ISO SHA-256: $normalized_actual_sha256"
  echo "Installer image: $output"
  echo "Keep this file and installer image private."
} > "$report_tmp"
chmod 0600 "$report_tmp"

mv -f "$report_tmp" "$recovery_report"
report_tmp=
mv -f "$output_tmp" "$output"
output_tmp=
unset controller_password password_hash

echo "Credential-bearing SSH-bootstrap image created:"
ls -lh "$output" "$recovery_report"
shasum -a 256 "$output"
