#!/bin/bash
set -euo pipefail
export COPYFILE_DISABLE=1

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

usage() {
  cat >&2 <<'EOF'
usage: build-existing-setup.sh \
  --config FILE \
  --ssh-public-key-file FILE \
  --output-dir DIR
EOF
  exit 64
}

config_file=
ssh_public_key_file=
output_dir=

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --config) config_file=$2; shift 2 ;;
    --ssh-public-key-file) ssh_public_key_file=$2; shift 2 ;;
    --output-dir) output_dir=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ -f "$config_file" && -f "$ssh_public_key_file" && -n "$output_dir" ]] || usage
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
mkdir -p "$rendered" "$payload/config"

for asset in SetupComplete.cmd provision.ps1 install-existing.ps1; do
  python3 "$SCRIPT_DIR/config.py" render \
    --config "$config_file" \
    --template "$SCRIPT_DIR/assets/$asset" \
    --output "$rendered/$asset"
  copy_windows_text "$rendered/$asset" "$payload/$asset"
done
install -m 0600 "$ssh_public_key_file" "$payload/config/ssh-public-key"
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
    config/ssh-public-key > manifest.sha256
)

mkdir -p "$output_parent"
cp -R "$payload" "$output_partial"
find "$output_partial" -type f -name '._*' -delete
mv "$output_partial" "$output_dir"

echo "Existing-Windows setup payload created without modifying the destination disk:"
printf '%s\n' "$output_dir"
