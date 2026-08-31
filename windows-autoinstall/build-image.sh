#!/bin/bash
set -euo pipefail
export COPYFILE_DISABLE=1

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DEFAULT_IMAGE_SIZE_GB=12

usage() {
  cat >&2 <<'EOF'
usage: build-image.sh \
  --base-iso FILE \
  --base-sha256 HEX \
  --config FILE \
  --private-dir DIR \
  --output FILE \
  [--recovery-report FILE] \
  [--image-size-gb INTEGER]
EOF
  exit 64
}

base_iso=
base_sha256=
config_file=
private_dir=
output=
recovery_report=
image_size_gb=$DEFAULT_IMAGE_SIZE_GB

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --base-iso) base_iso=$2; shift 2 ;;
    --base-sha256) base_sha256=$2; shift 2 ;;
    --config) config_file=$2; shift 2 ;;
    --private-dir) private_dir=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    --recovery-report) recovery_report=$2; shift 2 ;;
    --image-size-gb) image_size_gb=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ -f "$base_iso" && -f "$config_file" && -d "$private_dir" && -n "$output" ]] || usage
[[ "$base_sha256" =~ ^[0-9a-fA-F]{64}$ ]] || usage
[[ "$image_size_gb" =~ ^[0-9]+$ && "$image_size_gb" -ge 10 ]] || usage

if [[ -z "$recovery_report" ]]; then
  recovery_report="${output}.credentials.txt"
fi
if [[ "$output" == "$recovery_report" ]]; then
  echo "output and recovery report must be different files" >&2
  exit 1
fi

for command_name in diskutil go hdiutil openssl python3 rsync shasum ssh-keygen stat wimlib-imagex xmllint; do
  command -v "$command_name" >/dev/null || {
    echo "missing required command: $command_name" >&2
    exit 1
  }
done

python3 "$SCRIPT_DIR/config.py" validate --config "$config_file"
computer_name=$(
  python3 "$SCRIPT_DIR/config.py" get --config "$config_file" --key COMPUTER_NAME
)
admin_username=$(
  python3 "$SCRIPT_DIR/config.py" get --config "$config_file" --key ADMIN_USERNAME
)
app_prefix=$(
  python3 "$SCRIPT_DIR/config.py" get --config "$config_file" --key APP_PREFIX
)

copy_windows_text() {
  python3 - "$1" "$2" <<'PY'
from pathlib import Path
import sys

source, destination = map(Path, sys.argv[1:])
data = source.read_bytes().replace(b"\r\n", b"\n").replace(b"\r", b"\n")
destination.write_bytes(data.replace(b"\n", b"\r\n"))
PY
}

for required in wifi-ssid wifi-password ssh-public-key; do
  [[ -s "$private_dir/$required" ]] || {
    echo "missing private input: $private_dir/$required" >&2
    exit 1
  }
done
ssh-keygen -lf "$private_dir/ssh-public-key" >/dev/null
ssh_fingerprint=$(ssh-keygen -lf "$private_dir/ssh-public-key" | awk '{print $2}')

python3 - "$private_dir/wifi-ssid" "$private_dir/wifi-password" <<'PY'
from pathlib import Path
import sys

ssid = Path(sys.argv[1]).read_text().strip()
password = Path(sys.argv[2]).read_text().strip()
if not 1 <= len(ssid.encode()) <= 32:
    raise SystemExit("Wi-Fi SSID must contain 1..32 UTF-8 bytes")
if not 8 <= len(password) <= 63:
    raise SystemExit("WPA2 passphrase must contain 8..63 characters")
if "\n" in ssid or "\r" in ssid or "\n" in password or "\r" in password:
    raise SystemExit("Wi-Fi inputs must contain exactly one value")
PY

actual_base_sha256=$(shasum -a 256 "$base_iso" | awk '{print $1}')
normalized_actual_sha256=$(printf '%s' "$actual_base_sha256" | tr '[:upper:]' '[:lower:]')
normalized_expected_sha256=$(printf '%s' "$base_sha256" | tr '[:upper:]' '[:lower:]')
if [[ "$normalized_actual_sha256" != "$normalized_expected_sha256" ]]; then
  echo "Windows ISO checksum mismatch." >&2
  echo "expected: $normalized_expected_sha256" >&2
  echo "actual:   $normalized_actual_sha256" >&2
  exit 1
fi

temp_root=${TMPDIR:-/tmp}
temp_root=${temp_root%/}
work=$(mktemp -d "$temp_root/ai-node-windows.XXXXXX")
source_mounted=false
target_mounted=false
verify_mounted=false
output_tmp=
report_tmp=
source_mount="$work/source"
target_mount="$work/target"
verify_mount="$work/verify"
mkdir -p "$source_mount" "$target_mount" "$verify_mount"

cleanup() {
  if [[ "$verify_mounted" == "true" ]]; then
    hdiutil detach "$verify_mount" -quiet 2>/dev/null || true
  fi
  if [[ "$target_mounted" == "true" ]]; then
    hdiutil detach "$target_mount" -quiet 2>/dev/null || true
  fi
  if [[ "$source_mounted" == "true" ]]; then
    hdiutil detach "$source_mount" -quiet 2>/dev/null || true
  fi
  if [[ -n "${work:-}" && -d "$work" && "$work" == "$temp_root"/* ]]; then
    find "$work" -depth -delete
  fi
  if [[ -n "${output_tmp:-}" && -f "$output_tmp" && "$output_tmp" == "$output".partial.*.dmg ]]; then
    rm -f "$output_tmp"
  fi
  if [[ -n "${report_tmp:-}" && -f "$report_tmp" && "$report_tmp" == "$recovery_report".partial.* ]]; then
    rm -f "$report_tmp"
  fi
}
trap cleanup EXIT

generated="$work/generated"
oem="$generated/sources/\$OEM\$"
host_root="$oem/\$1/ProgramData/$app_prefix"
config="$host_root/config"
mkdir -p \
  "$generated/ai-node" \
  "$oem/\$\$/Setup/Scripts" \
  "$config"

admin_password=$(openssl rand -hex 24)
media_marker=$(openssl rand -hex 32)

python3 "$SCRIPT_DIR/config.py" render \
  --config "$config_file" \
  --template "$SCRIPT_DIR/autounattend.xml.in" \
  --output "$generated/ai-node/autounattend.xml.in" \
  --admin-password "$admin_password"
if [[ $(grep -Fo "__TARGET_DISK_ID__" "$generated/ai-node/autounattend.xml.in" | wc -l) -ne 2 ]]; then
  echo "answer file must retain exactly two runtime target-disk placeholders" >&2
  exit 1
fi
xmllint --noout "$generated/ai-node/autounattend.xml.in"

python3 - \
  "$private_dir/wifi-ssid" \
  "$private_dir/wifi-password" \
  "$config/wifi-profile.xml" <<'PY'
from pathlib import Path
import sys
from xml.sax.saxutils import escape

ssid_file, password_file, output = sys.argv[1:]
ssid = Path(ssid_file).read_text().strip()
password = Path(password_file).read_text().strip()
xml = f"""<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>{escape(ssid)}</name>
  <SSIDConfig>
    <SSID><name>{escape(ssid)}</name></SSID>
  </SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM>
    <security>
      <authEncryption>
        <authentication>WPA2PSK</authentication>
        <encryption>AES</encryption>
        <useOneX>false</useOneX>
      </authEncryption>
      <sharedKey>
        <keyType>passPhrase</keyType>
        <protected>false</protected>
        <keyMaterial>{escape(password)}</keyMaterial>
      </sharedKey>
    </security>
  </MSM>
</WLANProfile>
"""
Path(output).write_text(xml)
PY
xmllint --noout "$config/wifi-profile.xml"

GOOS=windows GOARCH=amd64 CGO_ENABLED=0 \
  go build -trimpath -ldflags="-s -w" \
    -o "$generated/ai-node/diskselector.exe" \
    "$SCRIPT_DIR/diskselector.go" \
    "$SCRIPT_DIR/diskpolicy.go"

rendered="$work/rendered"
mkdir -p "$rendered"
for asset in prepare.cmd winpe-start.cmd SetupComplete.cmd provision.ps1; do
  python3 "$SCRIPT_DIR/config.py" render \
    --config "$config_file" \
    --template "$SCRIPT_DIR/assets/$asset" \
    --output "$rendered/$asset"
done
copy_windows_text "$rendered/prepare.cmd" "$generated/ai-node/prepare.cmd"
copy_windows_text "$rendered/winpe-start.cmd" "$generated/ai-node/winpe-start.cmd"
copy_windows_text "$SCRIPT_DIR/assets/winpeshl.ini" "$generated/ai-node/winpeshl.ini"
copy_windows_text "$SCRIPT_DIR/assets/ei.cfg" "$generated/sources/ei.cfg"
copy_windows_text "$rendered/SetupComplete.cmd" "$oem/\$\$/Setup/Scripts/SetupComplete.cmd"
copy_windows_text "$rendered/provision.ps1" "$host_root/provision.ps1"
install -m 0600 "$private_dir/wifi-ssid" "$config/wifi-ssid"
install -m 0600 "$private_dir/ssh-public-key" "$config/ssh-public-key"
printf '%s\n' "$media_marker" > "$generated/AI_NODE_MEDIA"

hdiutil attach -readonly -nobrowse -mountpoint "$source_mount" "$base_iso" >/dev/null
source_mounted=true

install_image=
if [[ -f "$source_mount/sources/install.wim" ]]; then
  install_image="$source_mount/sources/install.wim"
elif [[ -f "$source_mount/sources/install.esd" ]]; then
  install_image="$source_mount/sources/install.esd"
else
  echo "official ISO does not contain sources/install.wim or sources/install.esd" >&2
  exit 1
fi
wimlib-imagex info "$install_image" "Windows 11 Pro" >/dev/null
[[ -f "$source_mount/sources/boot.wim" ]] || {
  echo "official ISO does not contain sources/boot.wim" >&2
  exit 1
}

bundle="$work/ai-node.sparsebundle"
hdiutil create \
  -size "${image_size_gb}g" \
  -layout MBRSPUD \
  -fs "MS-DOS FAT32" \
  -volname AI_NODE \
  -type SPARSEBUNDLE \
  "$bundle" >/dev/null
hdiutil attach -nobrowse -mountpoint "$target_mount" "$bundle" >/dev/null
target_mounted=true

rsync -rlt \
  --exclude='/.DS_Store' \
  --exclude='._*' \
  --exclude='/sources/install.wim' \
  --exclude='/sources/install.esd' \
  "$source_mount/" "$target_mount/"

pro_image="$work/install.wim"
wimlib-imagex export \
  "$install_image" \
  "Windows 11 Pro" \
  "$pro_image" \
  "Windows 11 Pro" \
  --compress=LZX
install_size=$(stat -f %z "$pro_image")
if (( install_size > 4000000000 )); then
  wimlib-imagex split "$pro_image" "$target_mount/sources/install.swm" 3800
else
  cp "$pro_image" "$target_mount/sources/install.wim"
fi

rsync -rlt --exclude='._*' "$generated/" "$target_mount/"

cat > "$work/boot-wim-update.txt" <<EOF
add "$generated/ai-node/prepare.cmd" "/Windows/System32/ai-node-prepare.cmd"
add "$generated/ai-node/diskselector.exe" "/Windows/System32/ai-node-diskselector.exe"
add "$generated/ai-node/winpe-start.cmd" "/Windows/System32/ai-node-winpe-start.cmd"
add "$generated/ai-node/winpeshl.ini" "/Windows/System32/winpeshl.ini"
EOF
wimlib-imagex update "$target_mount/sources/boot.wim" 2 < "$work/boot-wim-update.txt"

find "$target_mount" -type f \( -name '._*' -o -name '.DS_Store' \) -delete
sync
hdiutil detach "$target_mount" -quiet
target_mounted=false
hdiutil detach "$source_mount" -quiet
source_mounted=false

mkdir -p "$(dirname "$output")" "$(dirname "$recovery_report")"
output_tmp="${output}.partial.$$.dmg"
report_tmp="${recovery_report}.partial.$$"
rm -f "$output_tmp" "$report_tmp"
hdiutil convert "$bundle" -format UDRW -o "$work/ai-node" >/dev/null
mv "$work/ai-node.dmg" "$output_tmp"
chmod 0600 "$output_tmp"

hdiutil attach -readonly -nobrowse -mountpoint "$verify_mount" "$output_tmp" >/dev/null
verify_mounted=true
verify_whole=$(diskutil info "$verify_mount" | awk -F: '/Part of Whole:/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}')
verify_partition_type=$(diskutil info "$verify_mount" | awk -F: '/Partition Type:/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}')
[[ "$verify_partition_type" == "DOS_FAT_32" ]] || {
  echo "installer media partition is not DOS FAT32" >&2
  exit 1
}
diskutil list "/dev/$verify_whole" | grep -Fq "FDisk_partition_scheme" || {
  echo "installer media does not use the expected MBR partition map" >&2
  exit 1
}
[[ ! -e "$verify_mount/autounattend.xml" ]] || {
  echo "installer media must not expose an auto-discovered root answer template" >&2
  exit 1
}
cmp "$generated/ai-node/autounattend.xml.in" \
  "$verify_mount/ai-node/autounattend.xml.in"
cmp "$generated/AI_NODE_MEDIA" "$verify_mount/AI_NODE_MEDIA"
[[ -f "$verify_mount/efi/boot/bootx64.efi" ]] || {
  echo "installer media is missing the x64 UEFI bootloader" >&2
  exit 1
}
cmp "$oem/\$\$/Setup/Scripts/SetupComplete.cmd" \
  "$verify_mount/sources/\$OEM\$/\$\$/Setup/Scripts/SetupComplete.cmd"
cmp "$host_root/provision.ps1" \
  "$verify_mount/sources/\$OEM\$/\$1/ProgramData/$app_prefix/provision.ps1"
cmp "$config/wifi-ssid" \
  "$verify_mount/sources/\$OEM\$/\$1/ProgramData/$app_prefix/config/wifi-ssid"
cmp "$config/wifi-profile.xml" \
  "$verify_mount/sources/\$OEM\$/\$1/ProgramData/$app_prefix/config/wifi-profile.xml"
cmp "$config/ssh-public-key" \
  "$verify_mount/sources/\$OEM\$/\$1/ProgramData/$app_prefix/config/ssh-public-key"
[[ ! -e "$verify_mount/sources/\$OEM\$/\$1/ProgramData/$app_prefix/packages" ]] || {
  echo "unexpected application packages are present in the minimal image" >&2
  exit 1
}
if find "$verify_mount" -name '._*' -print -quit | grep -q .; then
  echo "unexpected AppleDouble metadata is present in the installer image" >&2
  exit 1
fi

wim_verify="$work/wim-verify"
mkdir -p "$wim_verify"
wimlib-imagex extract \
  "$verify_mount/sources/boot.wim" \
  2 \
  /Windows/System32/ai-node-prepare.cmd \
  /Windows/System32/ai-node-diskselector.exe \
  /Windows/System32/ai-node-winpe-start.cmd \
  /Windows/System32/winpeshl.ini \
  --preserve-dir-structure \
  --dest-dir="$wim_verify" >/dev/null
cmp "$generated/ai-node/prepare.cmd" "$wim_verify/Windows/System32/ai-node-prepare.cmd"
cmp "$generated/ai-node/diskselector.exe" "$wim_verify/Windows/System32/ai-node-diskselector.exe"
cmp "$generated/ai-node/winpe-start.cmd" "$wim_verify/Windows/System32/ai-node-winpe-start.cmd"
cmp "$generated/ai-node/winpeshl.ini" "$wim_verify/Windows/System32/winpeshl.ini"
hdiutil detach "$verify_mount" -quiet
verify_mounted=false

image_sha256=$(shasum -a 256 "$output_tmp" | awk '{print $1}')
cat > "$report_tmp" <<EOF
Windows unattended installer recovery information

Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
Target: General x64 compute node; automatic internal-disk selection
Windows edition: Windows 11 Pro
Host name: $computer_name
Administrator account: $admin_username
Administrator password: $admin_password
SSH authentication: public key only
SSH public-key fingerprint: $ssh_fingerprint
Base ISO SHA-256: $normalized_actual_sha256
Media SHA-256: $image_sha256
Media marker: $media_marker
Activation: no product key is embedded; Windows can use the device's existing firmware or digital license.

This report and installer image contain credentials. Keep both private.
EOF
chmod 0600 "$report_tmp"

mv "$output_tmp" "$output"
output_tmp=
mv "$report_tmp" "$recovery_report"
report_tmp=

echo "Credential-bearing minimal Windows installer media created:"
ls -lh "$output" "$recovery_report"
printf 'SHA-256: %s\n' "$image_sha256"
