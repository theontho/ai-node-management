#!/bin/bash
set -euo pipefail

cleanup() {
  if [[ "$0" == "/usr/local/sbin/ai-node-flash-root" ]]; then
    rm -f /etc/sudoers.d/ai-node-flash-once
    rm -f /usr/local/sbin/ai-node-flash-root
  fi
}
trap cleanup EXIT

if [[ "$#" -ne 5 ]]; then
  echo "usage: $0 IMAGE RAW_DEVICE IMAGE_SIZE EXPECTED_SHA256 REPORT" >&2
  exit 64
fi

image=$1
raw_device=$2
image_size=$3
expected_sha256=$4
report=$5

[[ -f "$image" ]] || exit 1
[[ "$raw_device" =~ ^/dev/rdisk[0-9]+$ ]] || exit 1
[[ "$image_size" =~ ^[0-9]+$ ]] || exit 1
[[ "$expected_sha256" =~ ^[0-9a-f]{64}$ ]] || exit 1
[[ -f "$report" && ! -L "$report" ]] || exit 1

device=${raw_device/\/dev\/rdisk/\/dev\/disk}
/usr/sbin/diskutil unmountDisk force "$device"
dd if="$image" of="$raw_device" bs=4m
sync
actual_sha256=$(head -c "$image_size" "$raw_device" | shasum -a 256 | awk '{print $1}')
[[ "$actual_sha256" == "$expected_sha256" ]] || {
  echo "flashed media verification failed" >&2
  exit 1
}
printf '%s\n' "$actual_sha256" > "$report"
chmod 0644 "$report"
