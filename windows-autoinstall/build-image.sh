#!/bin/bash
set -euo pipefail
export COPYFILE_DISABLE=1

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DEFAULT_IMAGE_SIZE_GB=12

usage() {
  cat >&2 <<'EOF'
usage: build-image.sh \
  (--base-iso FILE --base-sha256 HEX | --base-dir DIR) \
  --config FILE \
  --private-dir DIR \
  --openssh-msi FILE \
  --openssh-sha256 HEX \
  --tailscale-msi FILE \
  --tailscale-sha256 HEX \
  --output FILE \
  [--recovery-report FILE] \
  [--image-size-gb INTEGER]
EOF
  exit 64
}

base_iso=
base_sha256=
base_dir=
config_file=
private_dir=
openssh_msi=
openssh_sha256=
tailscale_msi=
tailscale_sha256=
output=
recovery_report=
image_size_gb=$DEFAULT_IMAGE_SIZE_GB

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --base-iso) base_iso=$2; shift 2 ;;
    --base-sha256) base_sha256=$2; shift 2 ;;
    --base-dir) base_dir=$2; shift 2 ;;
    --config) config_file=$2; shift 2 ;;
    --private-dir) private_dir=$2; shift 2 ;;
    --openssh-msi) openssh_msi=$2; shift 2 ;;
    --openssh-sha256) openssh_sha256=$2; shift 2 ;;
    --tailscale-msi) tailscale_msi=$2; shift 2 ;;
    --tailscale-sha256) tailscale_sha256=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    --recovery-report) recovery_report=$2; shift 2 ;;
    --image-size-gb) image_size_gb=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ -f "$config_file" &&
  -d "$private_dir" &&
  -f "$openssh_msi" &&
  -f "$tailscale_msi" &&
  -n "$output" ]] || usage
if [[ -n "$base_dir" ]]; then
  [[ -d "$base_dir" && -z "$base_iso" && -z "$base_sha256" ]] || usage
else
  [[ -f "$base_iso" && "$base_sha256" =~ ^[0-9a-fA-F]{64}$ ]] || usage
fi
[[ "$openssh_sha256" =~ ^[0-9a-fA-F]{64}$ ]] || usage
[[ "$tailscale_sha256" =~ ^[0-9a-fA-F]{64}$ ]] || usage
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
computer_name_prefix=$(
  python3 "$SCRIPT_DIR/config.py" get --config "$config_file" --key COMPUTER_NAME_PREFIX
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

[[ -s "$private_dir/ssh-public-key" ]] || {
  echo "missing private input: $private_dir/ssh-public-key" >&2
  exit 1
}
[[ -s "$private_dir/tailscale-auth-key" ]] || {
  echo "missing private input: $private_dir/tailscale-auth-key" >&2
  exit 1
}
wifi_enabled=false
if [[ -e "$private_dir/wifi-ssid" || -e "$private_dir/wifi-password" ]]; then
  [[ -s "$private_dir/wifi-ssid" && -s "$private_dir/wifi-password" ]] || {
    echo "wifi-ssid and wifi-password must either both be present or both be absent" >&2
    exit 1
  }
  wifi_enabled=true
fi
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

if [[ "$wifi_enabled" == "true" ]]; then
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
fi

base_media_description="trusted mounted Windows installer"
if [[ -z "$base_dir" ]]; then
  actual_base_sha256=$(shasum -a 256 "$base_iso" | awk '{print $1}')
  normalized_actual_sha256=$(printf '%s' "$actual_base_sha256" | tr '[:upper:]' '[:lower:]')
  normalized_expected_sha256=$(printf '%s' "$base_sha256" | tr '[:upper:]' '[:lower:]')
  if [[ "$normalized_actual_sha256" != "$normalized_expected_sha256" ]]; then
    echo "Windows ISO checksum mismatch." >&2
    echo "expected: $normalized_expected_sha256" >&2
    echo "actual:   $normalized_actual_sha256" >&2
    exit 1
  fi
  base_media_description="ISO SHA-256 $normalized_actual_sha256"
fi
actual_openssh_sha256=$(shasum -a 256 "$openssh_msi" | awk '{print $1}')
normalized_openssh_sha256=$(printf '%s' "$openssh_sha256" | tr '[:upper:]' '[:lower:]')
if [[ "$actual_openssh_sha256" != "$normalized_openssh_sha256" ]]; then
  echo "OpenSSH MSI checksum mismatch." >&2
  echo "expected: $normalized_openssh_sha256" >&2
  echo "actual:   $actual_openssh_sha256" >&2
  exit 1
fi
actual_tailscale_sha256=$(shasum -a 256 "$tailscale_msi" | awk '{print $1}')
normalized_tailscale_sha256=$(printf '%s' "$tailscale_sha256" | tr '[:upper:]' '[:lower:]')
if [[ "$actual_tailscale_sha256" != "$normalized_tailscale_sha256" ]]; then
  echo "Tailscale MSI checksum mismatch." >&2
  echo "expected: $normalized_tailscale_sha256" >&2
  echo "actual:   $actual_tailscale_sha256" >&2
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
source_mount=
target_mount="$work/target"
verify_mount="$work/verify"
mkdir -p "$target_mount" "$verify_mount"

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
  "$config" \
  "$host_root/packages"

admin_password=$(
  python3 "$SCRIPT_DIR/config.py" generate-password \
    --word-list "$SCRIPT_DIR/assets/eff-large-wordlist.txt"
)
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

if [[ "$wifi_enabled" == "true" ]]; then
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
fi

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
if [[ "$wifi_enabled" == "true" ]]; then
  install -m 0600 "$private_dir/wifi-ssid" "$config/wifi-ssid"
fi
install -m 0600 "$private_dir/ssh-public-key" "$config/ssh-public-key"
install -m 0600 "$private_dir/tailscale-auth-key" "$config/tailscale-auth-key"
install -m 0600 "$openssh_msi" "$host_root/packages/OpenSSH-Win64.msi"
install -m 0600 "$tailscale_msi" "$host_root/packages/Tailscale-amd64.msi"
printf '%s\n' "$media_marker" > "$generated/AI_NODE_MEDIA"

if [[ -n "$base_dir" ]]; then
  source_mount=$(cd "$base_dir" && pwd)
else
  source_mount="$work/source"
  mkdir -p "$source_mount"
  hdiutil attach -readonly -nobrowse -mountpoint "$source_mount" "$base_iso" >/dev/null
  source_mounted=true
fi

install_image=
if [[ -f "$source_mount/sources/install.wim" ]]; then
  install_image="$source_mount/sources/install.wim"
elif [[ -f "$source_mount/sources/install.esd" ]]; then
  install_image="$source_mount/sources/install.esd"
elif [[ -f "$source_mount/sources/install.swm" ]]; then
  install_image="$source_mount/sources/install.swm"
  install_ref="$source_mount/sources/install*.swm"
else
  echo "official media does not contain install.wim, install.esd, or install.swm" >&2
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
  --exclude='/sources/install*.swm' \
  "$source_mount/" "$target_mount/"

pro_image="$work/install.wim"
export_arguments=(
  "$install_image"
  "Windows 11 Pro"
  "$pro_image"
  "Windows 11 Pro"
  "--compress=LZX"
)
if [[ -n "${install_ref:-}" ]]; then
  export_arguments+=("--ref=$install_ref")
fi
wimlib-imagex export "${export_arguments[@]}"
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
if [[ "$source_mounted" == "true" ]]; then
  hdiutil detach "$source_mount" -quiet
  source_mounted=false
fi

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
if [[ "$wifi_enabled" == "true" ]]; then
  cmp "$config/wifi-ssid" \
    "$verify_mount/sources/\$OEM\$/\$1/ProgramData/$app_prefix/config/wifi-ssid"
  cmp "$config/wifi-profile.xml" \
    "$verify_mount/sources/\$OEM\$/\$1/ProgramData/$app_prefix/config/wifi-profile.xml"
else
  [[ ! -e "$verify_mount/sources/\$OEM\$/\$1/ProgramData/$app_prefix/config/wifi-ssid" ]]
  [[ ! -e "$verify_mount/sources/\$OEM\$/\$1/ProgramData/$app_prefix/config/wifi-profile.xml" ]]
fi
cmp "$config/ssh-public-key" \
  "$verify_mount/sources/\$OEM\$/\$1/ProgramData/$app_prefix/config/ssh-public-key"
cmp "$config/tailscale-auth-key" \
  "$verify_mount/sources/\$OEM\$/\$1/ProgramData/$app_prefix/config/tailscale-auth-key"
cmp "$host_root/packages/OpenSSH-Win64.msi" \
  "$verify_mount/sources/\$OEM\$/\$1/ProgramData/$app_prefix/packages/OpenSSH-Win64.msi"
cmp "$host_root/packages/Tailscale-amd64.msi" \
  "$verify_mount/sources/\$OEM\$/\$1/ProgramData/$app_prefix/packages/Tailscale-amd64.msi"
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
Host name pattern: $computer_name_prefix-ADJECTIVE-NOUN
Administrator account: $admin_username
Administrator password: $admin_password
SSH authentication: public key only
SSH public-key fingerprint: $ssh_fingerprint
Base media: $base_media_description
OpenSSH MSI SHA-256: $normalized_openssh_sha256
Tailscale: automatic unattended enrollment enabled
Tailscale MSI SHA-256: $normalized_tailscale_sha256
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
