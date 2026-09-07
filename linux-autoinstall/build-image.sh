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
  --tailscale-deb FILE \
  --tailscale-sha256 HEX \
  --output FILE \
  [--recovery-report FILE]
EOF
  exit 64
}

base_iso=
base_sha256=
config_file=
private_dir=
tailscale_deb=
tailscale_sha256=
output=
recovery_report=
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --base-iso) base_iso=$2; shift 2 ;;
    --base-sha256) base_sha256=$2; shift 2 ;;
    --config) config_file=$2; shift 2 ;;
    --private-dir) private_dir=$2; shift 2 ;;
    --tailscale-deb) tailscale_deb=$2; shift 2 ;;
    --tailscale-sha256) tailscale_sha256=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    --recovery-report) recovery_report=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ -f "$base_iso" &&
  -f "$config_file" &&
  -d "$private_dir" &&
  -f "$tailscale_deb" &&
  -n "$output" ]] || usage
[[ "$base_sha256" =~ ^[0-9a-fA-F]{64}$ ]] || usage
[[ "$tailscale_sha256" =~ ^[0-9a-fA-F]{64}$ ]] || usage
if [[ -z "$recovery_report" ]]; then
  recovery_report="${output%.iso}-recovery.txt"
fi
[[ "$output" != "$recovery_report" ]] || {
  echo "output and recovery report must be different files" >&2
  exit 1
}
[[ ! -e "$recovery_report" ]] || {
  echo "recovery report already exists; refusing to overwrite: $recovery_report" >&2
  exit 1
}

for command_name in ar openssl python3 shasum ssh-keygen tar xorriso; do
  command -v "$command_name" >/dev/null || {
    echo "missing required command: $command_name" >&2
    exit 1
  }
done

python3 "$SCRIPT_DIR/config.py" validate --config "$config_file"
config_get() {
  python3 "$SCRIPT_DIR/config.py" get --config "$config_file" --key "$1"
}
NODE_NAME_PREFIX=$(config_get NODE_NAME_PREFIX)
ADMIN_USER=$(config_get ADMIN_USER)
TIMEZONE=$(config_get TIMEZONE)
SYSTEM_DISK=$(config_get SYSTEM_DISK)
DATA_MOUNT=$(config_get DATA_MOUNT)
PREFERRED_MIN_TARGET_DISK_BYTES=$(config_get PREFERRED_MIN_TARGET_DISK_BYTES)
SWAP_SIZE_GIB=$(config_get SWAP_SIZE_GIB)
SWAPPINESS=$(config_get SWAPPINESS)
CONSOLE_IDLE_SECONDS=$(config_get CONSOLE_IDLE_SECONDS)
MINIMUM_SYSTEM_DISK_BYTES=$((SWAP_SIZE_GIB * 1024 * 1024 * 1024 + 16000000000))

for required in ssh-public-key tailscale-auth-key; do
  [[ -s "$private_dir/$required" ]] || {
    echo "missing private input: $private_dir/$required" >&2
    exit 1
  }
done
openssl passwd -6 preflight >/dev/null
ssh-keygen -lf "$private_dir/ssh-public-key" >/dev/null
ssh_fingerprint=$(ssh-keygen -lf "$private_dir/ssh-public-key" | awk '{print $2}')

python3 - "$private_dir/tailscale-auth-key" <<'PY'
from pathlib import Path
import re
import sys

value = Path(sys.argv[1]).read_text(encoding="utf-8").strip()
if not re.fullmatch(r"tskey-[A-Za-z0-9_-]+", value):
    raise SystemExit("Tailscale auth key file must contain exactly one tskey-* value")
PY

wifi_enabled=false
if [[ -e "$private_dir/wifi-ssid" || -e "$private_dir/wifi-password" ]]; then
  [[ -s "$private_dir/wifi-ssid" && -s "$private_dir/wifi-password" ]] || {
    echo "wifi-ssid and wifi-password must either both be present or both be absent" >&2
    exit 1
  }
  wifi_enabled=true
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
fi

actual_base_sha256=$(shasum -a 256 "$base_iso" | awk '{print $1}')
normalized_actual_sha256=$(printf '%s' "$actual_base_sha256" | tr '[:upper:]' '[:lower:]')
normalized_expected_sha256=$(printf '%s' "$base_sha256" | tr '[:upper:]' '[:lower:]')
[[ "$normalized_actual_sha256" == "$normalized_expected_sha256" ]] || {
  echo "Ubuntu ISO checksum mismatch." >&2
  echo "expected: $normalized_expected_sha256" >&2
  echo "actual:   $normalized_actual_sha256" >&2
  exit 1
}
actual_tailscale_sha256=$(shasum -a 256 "$tailscale_deb" | awk '{print $1}')
normalized_tailscale_sha256=$(printf '%s' "$tailscale_sha256" | tr '[:upper:]' '[:lower:]')
if [[ "$actual_tailscale_sha256" != "$normalized_tailscale_sha256" ]]; then
  echo "Tailscale DEB checksum mismatch." >&2
  echo "expected: $normalized_tailscale_sha256" >&2
  echo "actual:   $actual_tailscale_sha256" >&2
  exit 1
fi
ar t "$tailscale_deb" | grep -Fxq 'debian-binary' || {
  echo "Tailscale package is not a Debian binary archive." >&2
  exit 1
}
control_member=$(ar t "$tailscale_deb" | awk '/^control\.tar(\..+)?$/ { print; exit }')
[[ -n "$control_member" ]] || {
  echo "Tailscale package does not contain control metadata." >&2
  exit 1
}
control_path=$(
  ar p "$tailscale_deb" "$control_member" \
    | tar -tf - \
    | awk '$0 == "./control" || $0 == "control" { print; exit }'
)
[[ -n "$control_path" ]] || {
  echo "Tailscale package control metadata is unreadable." >&2
  exit 1
}
control_metadata=$(
  ar p "$tailscale_deb" "$control_member" \
    | tar -xOf - "$control_path"
)
grep -Eq '^Package:[[:space:]]+tailscale$' <<<"$control_metadata" || {
  echo "DEB package name must be tailscale." >&2
  exit 1
}
grep -Eq '^Architecture:[[:space:]]+amd64$' <<<"$control_metadata" || {
  echo "Tailscale DEB architecture must be amd64." >&2
  exit 1
}
tailscale_version=$(
  awk -F ': ' '$1 == "Version" { print $2; exit }' <<<"$control_metadata"
)
[[ "$tailscale_version" =~ ^[A-Za-z0-9.+:~_-]+$ ]] || {
  echo "Tailscale DEB has an invalid or missing version." >&2
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
mkdir -p "$seed/assets" "$seed/packages" "$seed/private"
for asset in \
  apt-noninteractive.conf \
  ai-node-console-power.service \
  ai-node-console-health.service \
  ai-node-console-health.timer \
  ai-node-tailscale-enroll.service \
  getty-console-health.conf; do
  install -m 0644 "$SCRIPT_DIR/assets/$asset" "$seed/assets/$asset"
done
install -m 0755 "$SCRIPT_DIR/assets/configure-swap" "$seed/assets/configure-swap"
install -m 0755 "$SCRIPT_DIR/configure-wifi.py" \
  "$seed/assets/configure-wifi.py"
install -m 0755 "$SCRIPT_DIR/diskselector.py" "$seed/assets/diskselector.py"
install -m 0755 "$SCRIPT_DIR/assets/enroll-tailscale" \
  "$seed/assets/enroll-tailscale"
install -m 0755 "$SCRIPT_DIR/assets/generate-node-name" \
  "$seed/assets/generate-node-name"
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
python3 - "$SCRIPT_DIR/assets/render-console-health" \
  "$seed/assets/render-console-health" \
  "$DATA_MOUNT" <<'PY'
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
install -m 0600 "$private_dir/tailscale-auth-key" \
  "$seed/private/tailscale-auth-key"
install -m 0644 "$tailscale_deb" "$seed/packages/tailscale.deb"

printf 'instance-id: %s-installer\nlocal-hostname: %s-installer\n' \
  "$NODE_NAME_PREFIX" "$NODE_NAME_PREFIX" > "$seed/meta-data"
printf '#cloud-config\n' > "$seed/vendor-data"

controller_password=$(
  "$SCRIPT_DIR/generate-password.py" \
    --word-list "$SCRIPT_DIR/assets/eff-large-wordlist.txt"
)
password_hash=$(printf '%s\n' "$controller_password" | openssl passwd -6 -stdin)

render_args=(
  --template "$SCRIPT_DIR/autoinstall.yaml.in"
  --ssh-public-key-file "$private_dir/ssh-public-key"
  --password-hash "$password_hash"
  --node-name-prefix "$NODE_NAME_PREFIX"
  --admin-user "$ADMIN_USER"
  --timezone "$TIMEZONE"
  --system-disk-policy "$SYSTEM_DISK"
  --data-mount "$DATA_MOUNT"
  --preferred-min-target-disk-bytes "$PREFERRED_MIN_TARGET_DISK_BYTES"
  --minimum-system-disk-bytes "$MINIMUM_SYSTEM_DISK_BYTES"
)
if [[ "$wifi_enabled" == "true" ]]; then
  render_args+=(
    --wifi-ssid-file "$private_dir/wifi-ssid"
    --wifi-password-file "$private_dir/wifi-password"
  )
fi
"$SCRIPT_DIR/render-autoinstall.py" \
  "${render_args[@]}" \
  --output "$seed/user-data"
"$SCRIPT_DIR/render-autoinstall.py" \
  "${render_args[@]}" \
  --interactive-storage \
  --output "$seed/storage-fallback-user-data"
chmod 0600 "$seed/user-data" "$seed/storage-fallback-user-data"

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

menuentry "Install $NODE_NAME_PREFIX node (ERASES SELECTED INTERNAL DISKS)" {
    set gfxpayload=keep
    linux /casper/vmlinuz autoinstall noprompt ds=nocloud\\;s=file:///cdrom/nocloud/ ---
    initrd /casper/initrd
}
menuentry "Boot installed $NODE_NAME_PREFIX node" {
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

menuentry "Install $NODE_NAME_PREFIX node (ERASES SELECTED INTERNAL DISKS)" {
    set gfxpayload=keep
    linux /casper/vmlinuz iso-scan/filename=\${iso_path} autoinstall noprompt ds=nocloud\\;s=file:///cdrom/nocloud/ ---
    initrd /casper/initrd
}
menuentry "Boot installed $NODE_NAME_PREFIX node" {
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
xorriso -osirrox on -indev "$output_tmp" \
  -extract /nocloud/storage-fallback-user-data \
  "$work/verify-storage-fallback-user-data" >/dev/null 2>&1
cmp "$seed/storage-fallback-user-data" "$work/verify-storage-fallback-user-data"
xorriso -osirrox on -indev "$output_tmp" \
  -extract /nocloud/private/tailscale-auth-key \
  "$work/verify-tailscale-auth-key" >/dev/null 2>&1
cmp "$seed/private/tailscale-auth-key" "$work/verify-tailscale-auth-key"
xorriso -osirrox on -indev "$output_tmp" \
  -extract /nocloud/packages/tailscale.deb \
  "$work/verify-tailscale.deb" >/dev/null 2>&1
cmp "$seed/packages/tailscale.deb" "$work/verify-tailscale.deb"

image_sha256=$(shasum -a 256 "$output_tmp" | awk '{print $1}')
{
  echo "AI node Linux recovery login"
  echo
  echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "Host name pattern: $NODE_NAME_PREFIX-ADJECTIVE-NOUN"
  echo "Local console account: $ADMIN_USER"
  echo "Local console password: $controller_password"
  echo "SSH authentication: public key only"
  echo "SSH public-key fingerprint: $ssh_fingerprint"
  echo
  echo "System disk policy: $SYSTEM_DISK"
  echo "Data disk policy: all eligible secondary disks mounted at $DATA_MOUNT, ${DATA_MOUNT}2, ..."
  if [[ "$wifi_enabled" == "true" ]]; then
    echo "Wi-Fi: embedded profile enabled"
  else
    echo "Wi-Fi: not configured; Ethernet remains enabled"
  fi
  echo "Tailscale: automatic host enrollment enabled"
  echo "Tailscale package: tailscale $tailscale_version (amd64)"
  echo "Tailscale DEB SHA-256: $normalized_tailscale_sha256"
  echo "Base ISO SHA-256: $normalized_actual_sha256"
  echo "Media SHA-256: $image_sha256"
  echo "Installer image: $output"
  echo "Keep this file and installer image private."
} > "$report_tmp"
chmod 0600 "$report_tmp"

ln "$report_tmp" "$recovery_report"
rm -f "$report_tmp"
report_tmp=
mv -f "$output_tmp" "$output"
output_tmp=
unset controller_password password_hash

echo "Credential-bearing SSH-bootstrap image created:"
ls -lh "$output" "$recovery_report"
printf 'SHA-256: %s\n' "$image_sha256"
