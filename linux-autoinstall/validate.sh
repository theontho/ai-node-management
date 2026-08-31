#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/ai-node-linux-validate.XXXXXX")
trap 'find "$work" -depth -delete' EXIT

for script in "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/assets/*; do
  [[ -x "$script" || "$script" == *.sh ]] || continue
  bash -n "$script"
done
PYTHONPYCACHEPREFIX="$work/pycache" python3 -m py_compile \
  "$SCRIPT_DIR/render-autoinstall.py"

printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestOnlyValidationKey node-admin\n' \
  > "$work/ssh-public-key"
printf 'Validation Network\n' > "$work/wifi-ssid"
printf 'validation-passphrase\n' > "$work/wifi-password"

render() {
  local output=$1
  shift
  "$SCRIPT_DIR/render-autoinstall.py" \
    --template "$SCRIPT_DIR/autoinstall.yaml.in" \
    --output "$output" \
    --ssh-public-key-file "$work/ssh-public-key" \
    --wifi-ssid-file "$work/wifi-ssid" \
    --wifi-password-file "$work/wifi-password" \
    --password-hash '$6$validation$not-a-real-password-hash' \
    --node-name ai-node-linux \
    --admin-user node-admin \
    --timezone Etc/UTC \
    --system-disk /dev/disk/by-id/system-validation \
    "$@"
}

render "$work/single.yaml"
render "$work/dual.yaml" \
  --data-disk /dev/disk/by-id/data-validation \
  --data-mount /srv/data

python3 - "$work/single.yaml" "$work/dual.yaml" <<'PY'
from pathlib import Path
import sys

single = Path(sys.argv[1]).read_text()
dual = Path(sys.argv[2]).read_text()
for name, text in (("single", single), ("dual", dual)):
    if "__" in text:
        raise SystemExit(f"{name}: unresolved template marker")
    if "interactive-sections: []" not in text:
        raise SystemExit(f"{name}: unattended installation disabled")
    if 'layout: us' not in text or 'locale: en_US.UTF-8' not in text:
        raise SystemExit(f"{name}: expected US locale configuration missing")
if "disk-data" in single or "data_disk=" in single:
    raise SystemExit("single: unexpected data-disk configuration")
if "disk-data" not in dual or 'path: "/srv/data"' not in dual:
    raise SystemExit("dual: data-disk configuration missing")
PY

if command -v ruby >/dev/null 2>&1; then
  ruby -e 'require "yaml"; ARGV.each { |path| YAML.safe_load(File.read(path), aliases: true) }' \
    "$work/single.yaml" "$work/dual.yaml"
fi

echo "Linux installer validation passed."
