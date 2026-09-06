#!/bin/bash
set -euo pipefail
export COPYFILE_DISABLE=1

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

usage() {
  cat >&2 <<'EOF'
usage: build-existing-setup.sh \
  --config FILE \
  --ssh-public-key-file FILE \
  --openssh-msi FILE \
  --openssh-sha256 HEX \
  --tailscale-msi FILE \
  --tailscale-sha256 HEX \
  --tailscale-auth-key-file FILE \
  --output-dir DIR
EOF
  exit 64
}

config_file=
ssh_public_key_file=
openssh_msi=
openssh_sha256=
tailscale_msi=
tailscale_sha256=
tailscale_auth_key_file=
output_dir=

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --config) config_file=$2; shift 2 ;;
    --ssh-public-key-file) ssh_public_key_file=$2; shift 2 ;;
    --openssh-msi) openssh_msi=$2; shift 2 ;;
    --openssh-sha256) openssh_sha256=$2; shift 2 ;;
    --tailscale-msi) tailscale_msi=$2; shift 2 ;;
    --tailscale-sha256) tailscale_sha256=$2; shift 2 ;;
    --tailscale-auth-key-file) tailscale_auth_key_file=$2; shift 2 ;;
    --output-dir) output_dir=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ -f "$config_file" &&
  -f "$ssh_public_key_file" &&
  -f "$openssh_msi" &&
  -f "$tailscale_msi" &&
  -s "$tailscale_auth_key_file" &&
  -n "$output_dir" ]] || usage
[[ "$openssh_sha256" =~ ^[0-9a-fA-F]{64}$ ]] || usage
[[ "$tailscale_sha256" =~ ^[0-9a-fA-F]{64}$ ]] || usage
[[ ! -e "$output_dir" ]] || {
  echo "refusing to overwrite existing output directory: $output_dir" >&2
  exit 1
}

for command_name in python3 shasum ssh-keygen; do
  command -v "$command_name" >/dev/null || {
    echo "missing required command: $command_name" >&2
    exit 1
  }
done

python3 "$SCRIPT_DIR/config.py" validate --config "$config_file"
ssh-keygen -lf "$ssh_public_key_file" >/dev/null
python3 - "$tailscale_auth_key_file" <<'PY'
from pathlib import Path
import re
import sys

value = Path(sys.argv[1]).read_text(encoding="utf-8").strip()
if not re.fullmatch(r"tskey-[A-Za-z0-9_-]+", value):
    raise SystemExit("Tailscale auth key file must contain exactly one tskey-* value")
PY
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

copy_windows_text() {
  python3 - "$1" "$2" <<'PY'
from pathlib import Path
import sys

source, destination = map(Path, sys.argv[1:])
data = source.read_bytes().replace(b"\r\n", b"\n").replace(b"\r", b"\n")
destination.write_bytes(data.replace(b"\n", b"\r\n"))
PY
}

temp_root=${TMPDIR:-/tmp}
temp_root=${temp_root%/}
work=$(mktemp -d "$temp_root/ai-node-existing-windows.XXXXXX")
output_parent=$(dirname "$output_dir")
output_name=$(basename "$output_dir")
output_partial="$output_parent/.${output_name}.partial.$$"

cleanup() {
  if [[ -d "$work" && "$work" == "$temp_root"/* ]]; then
    find "$work" -depth -delete
  fi
  if [[ -d "$output_partial" ]]; then
    find "$output_partial" -depth -delete
  fi
}
trap cleanup EXIT

rendered="$work/rendered"
payload="$work/payload"
mkdir -p "$rendered" "$payload/config" "$payload/packages"

for asset in SetupComplete.cmd provision.ps1 install-existing.ps1; do
  python3 "$SCRIPT_DIR/config.py" render \
    --config "$config_file" \
    --template "$SCRIPT_DIR/assets/$asset" \
    --output "$rendered/$asset"
  copy_windows_text "$rendered/$asset" "$payload/$asset"
done
install -m 0600 "$ssh_public_key_file" "$payload/config/ssh-public-key"
install -m 0600 "$tailscale_auth_key_file" "$payload/config/tailscale-auth-key"
install -m 0600 "$openssh_msi" "$payload/packages/OpenSSH-Win64.msi"
install -m 0600 "$tailscale_msi" "$payload/packages/Tailscale-amd64.msi"
python3 "$SCRIPT_DIR/config.py" render \
  --config "$config_file" \
  --template "$SCRIPT_DIR/assets/existing-setup-README.txt" \
  --output "$rendered/README.txt"
copy_windows_text "$rendered/README.txt" "$payload/README.txt"

(
  cd "$payload"
  shasum -a 256 \
    install-existing.ps1 \
    README.txt \
    SetupComplete.cmd \
    provision.ps1 \
    config/ssh-public-key \
    config/tailscale-auth-key \
    packages/OpenSSH-Win64.msi \
    packages/Tailscale-amd64.msi > manifest.sha256
)

mkdir -p "$output_parent"
cp -R "$payload" "$output_partial"
find "$output_partial" -type f -name '._*' -delete
mv "$output_partial" "$output_dir"

echo "Existing-Windows setup payload created without modifying the destination disk:"
printf '%s\n' "$output_dir"
