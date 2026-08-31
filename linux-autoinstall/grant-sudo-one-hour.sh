#!/bin/bash
set -euo pipefail

if [[ "$EUID" -ne 0 || "$#" -ne 1 || ! "$1" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "usage: sudo $0 USER" >&2
  exit 64
fi

user=$1
uid=$(id -u "$user")
rule="/etc/sudoers.d/copilot-${uid}-one-hour"
cleanup="/var/run/copilot-${uid}-sudo-cleanup"
expiry="/var/run/copilot-${uid}-sudo-expires"
pid_file="/var/run/copilot-${uid}-sudo-cleanup.pid"
expiry_epoch=$(($(date +%s) + 3600))

if [[ -f "$pid_file" ]]; then
  read -r previous_pid < "$pid_file"
  if [[ "$previous_pid" =~ ^[0-9]+$ ]] && kill -0 "$previous_pid" 2>/dev/null; then
    kill "$previous_pid"
  fi
fi

printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$user" > "$rule"
chmod 0440 "$rule"
visudo -cf "$rule" >/dev/null
date -r "$expiry_epoch" '+%Y-%m-%dT%H:%M:%S%z' > "$expiry"
chmod 0644 "$expiry"

cat > "$cleanup" <<EOF
#!/bin/sh
set -eu
while [ "\$(date +%s)" -lt "$expiry_epoch" ]; do
  sleep 60
done
rm -f "$rule" "$expiry" "$pid_file" "$cleanup"
logger -t copilot-sudo "Expired one-hour sudo grant for $user"
EOF
chmod 0700 "$cleanup"
nohup "$cleanup" </dev/null >/dev/null 2>&1 &
printf '%s\n' "$!" > "$pid_file"
chmod 0600 "$pid_file"
logger -t copilot-sudo "Granted one-hour sudo access to $user"
