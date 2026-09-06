#!/bin/bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: connect-rdp.sh \
  --host HOST \
  --domain WINDOWS_HOSTNAME \
  --user USER \
  --credentials-report FILE \
  --confirm-tailscale HOST
EOF
  exit 64
}

host=
domain=
user=
credentials_report=
confirm_tailscale=

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --host) host=$2; shift 2 ;;
    --domain) domain=$2; shift 2 ;;
    --user) user=$2; shift 2 ;;
    --credentials-report) credentials_report=$2; shift 2 ;;
    --confirm-tailscale) confirm_tailscale=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || usage
[[ "$domain" =~ ^[A-Za-z0-9-]+$ ]] || usage
[[ "$user" =~ ^[A-Za-z0-9._-]+$ ]] || usage
[[ -f "$credentials_report" && "$confirm_tailscale" == "$host" ]] || usage
command -v sdl-freerdp >/dev/null || {
  echo "missing required command: sdl-freerdp (install with: brew install freerdp)" >&2
  exit 1
}

permissions=$(stat -f '%Lp' "$credentials_report")
if (( (8#$permissions & 077) != 0 )); then
  echo "credentials report must not be readable by group or others" >&2
  exit 1
fi

password=
while IFS= read -r line; do
  case "$line" in
    "Administrator password: "*)
      [[ -z "$password" ]] || {
        echo "credentials report contains multiple administrator passwords" >&2
        exit 1
      }
      password=${line#Administrator password: }
      ;;
  esac
done < "$credentials_report"
[[ -n "$password" ]] || {
  echo "credentials report does not contain an administrator password" >&2
  exit 1
}

# Tailscale authenticates and encrypts the endpoint; the Windows RDP
# certificate is self-signed and cannot be validated by a public CA.
export RDP_ARGS
RDP_ARGS=$(printf '%s\n' \
  "/v:$host" \
  "/u:$user" \
  "/d:$domain" \
  "/p:$password" \
  "/cert:ignore" \
  "/sec:nla" \
  "/size:1280x800" \
  "/network:lan" \
  "-clipboard")
unset password

exec sdl-freerdp /args-from:env:RDP_ARGS
