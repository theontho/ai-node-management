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
device_size=$(diskutil info "$device" | awk -F'[()]' '/Disk Size:/ {gsub(/ Bytes/, "", $2); print $2; exit}')
[[ "$device_size" =~ ^[0-9]+$ ]] || {
  echo "could not determine device size" >&2
  exit 1
}
if (( device_size < image_size )); then
  echo "installer image is larger than $device" >&2
  exit 1
fi

image_sha256=$(shasum -a 256 "$image" | awk '{print $1}')
diskutil unmountDisk "$device"
sudo dd if="$image" of="$raw_device" bs=4m
sync
read_mebibytes=$(( (image_size + 1048575) / 1048576 ))
flashed_sha256=$(
  sudo dd if="$raw_device" bs=1m count="$read_mebibytes" 2>/dev/null \
    | head -c "$image_size" \
    | shasum -a 256 \
    | awk '{print $1}'
)
if [[ "$flashed_sha256" != "$image_sha256" ]]; then
  echo "flashed media verification failed" >&2
  exit 1
fi
diskutil eject "$device"
echo "Flashed, verified, and ejected $device."
