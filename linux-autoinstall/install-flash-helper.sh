#!/bin/bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "usage: $0 USER SOURCE_HELPER" >&2
  exit 64
fi

user=$1
source_helper=$2
[[ "$user" =~ ^[a-z_][a-z0-9_-]*$ ]] || exit 1
[[ -f "$source_helper" ]] || exit 1

install -d -o root -g wheel -m 0755 /usr/local/sbin
install -o root -g wheel -m 0755 "$source_helper" /usr/local/sbin/ai-node-flash-root
printf '%s ALL=(root) NOPASSWD: /usr/local/sbin/ai-node-flash-root\n' "$user" \
  > /etc/sudoers.d/ai-node-flash-once
chmod 0440 /etc/sudoers.d/ai-node-flash-once
visudo -cf /etc/sudoers.d/ai-node-flash-once >/dev/null
