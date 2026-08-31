#!/bin/bash
set -euo pipefail

usage() {
  echo "usage: $0 --image FILE --device /dev/diskN --confirm ERASE:/dev/diskN" >&2
  exit 64
}

image=
device=
confirmation=
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --image) image=$2; shift 2 ;;
    --device) device=$2; shift 2 ;;
    --confirm) confirmation=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ -f "$image" && "$device" =~ ^/dev/disk[0-9]+$ ]] || usage
[[ "$confirmation" == "ERASE:$device" ]] || {
  echo "confirmation must be exactly ERASE:$device" >&2
  exit 1
}

info=$(diskutil info "$device")
grep -Eq 'Device / Media Name:' <<<"$info"
grep -Eq 'Removable Media:[[:space:]]+(Yes|Removable)' <<<"$info" || {
  echo "refusing non-removable device $device" >&2
  exit 1
}
if grep -Eq 'Internal:[[:space:]]+Yes' <<<"$info"; then
  echo "refusing internal device $device" >&2
  exit 1
fi

raw_device=${device/\/dev\/disk/\/dev\/rdisk}
image_size=$(stat -f %z "$image")
image_sha256=$(shasum -a 256 "$image" | awk '{print $1}')
root_helper=$(cd "$(dirname "$0")" && pwd)/flash-root.sh
report_dir=$(mktemp -d)
report="$report_dir/result"
: > "$report"
chmod 0600 "$report"
cleanup() {
  rm -f "$report"
  rmdir "$report_dir" 2>/dev/null || true
}
trap cleanup EXIT

diskutil unmountDisk "$device"
if sudo -n true 2>/dev/null; then
  sudo "$root_helper" "$image" "$raw_device" "$image_size" "$image_sha256" "$report"
else
  installer=$(cd "$(dirname "$0")" && pwd)/install-flash-helper.sh
  current_user=$(id -un)
  osascript - "$installer" "$current_user" "$root_helper" <<'APPLESCRIPT'
on run argv
  set commandText to quoted form of item 1 of argv
  repeat with argumentIndex from 2 to count of argv
    set commandText to commandText & " " & quoted form of item argumentIndex of argv
  end repeat
  do shell script commandText with administrator privileges
end run
APPLESCRIPT
  sudo -n /usr/local/sbin/ai-node-flash-root \
    "$image" "$raw_device" "$image_size" "$image_sha256" "$report"
fi

flashed_sha256=$(cat "$report")
[[ "$flashed_sha256" == "$image_sha256" ]]
diskutil eject "$device"
echo "Flashed, verified, and ejected $device."
