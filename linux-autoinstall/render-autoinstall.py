#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
import shlex


def render(args: argparse.Namespace) -> str:
    if args.data_disk:
        data_validation = f"""      data_disk={shlex.quote(args.data_disk)}
      data_block=${{data_disk##*/}}
      if [ ! -b "$data_disk" ] \\
        || [ ! -r "/sys/class/block/$data_block/removable" ] \\
        || [ "$(cat "/sys/class/block/$data_block/removable")" != "0" ]; then
        echo "Configured data disk $data_disk is absent or removable." >&2
        exit 1
      fi"""
        data_storage = f"""      - type: disk
        id: disk-data
        path: {json.dumps(args.data_disk)}
        ptable: gpt
        wipe: superblock-recursive
        preserve: false
        grub_device: false
      - type: partition
        id: partition-data
        device: disk-data
        size: -1
        number: 1
        preserve: false
        wipe: superblock
      - type: format
        id: format-data
        volume: partition-data
        fstype: ext4
        label: ai-node-data
        preserve: false
      - type: mount
        id: mount-data
        device: format-data
        path: {json.dumps(args.data_mount)}"""
    else:
        data_validation = ""
        data_storage = ""

    values = {
        "__SSH_PUBLIC_KEY__": json.dumps(Path(args.ssh_public_key_file).read_text().strip()),
        "__WIFI_SSID__": json.dumps(Path(args.wifi_ssid_file).read_text().strip()),
        "__WIFI_PASSWORD__": json.dumps(Path(args.wifi_password_file).read_text().strip()),
        "__PASSWORD_HASH__": json.dumps(args.password_hash),
        "__NODE_NAME__": json.dumps(args.node_name),
        "__ADMIN_USER__": json.dumps(args.admin_user),
        "__TIMEZONE__": json.dumps(args.timezone),
        "__SYSTEM_DISK_SHELL__": shlex.quote(args.system_disk),
        "__SYSTEM_DISK_YAML__": json.dumps(args.system_disk),
        "__DATA_DISK_VALIDATION__": data_validation,
        "__DATA_STORAGE_CONFIG__": data_storage,
    }
    text = Path(args.template).read_text()
    for placeholder, value in values.items():
        if not value and placeholder not in {
            "__DATA_DISK_VALIDATION__",
            "__DATA_STORAGE_CONFIG__",
        }:
            raise SystemExit(f"{placeholder} is empty")
        text = text.replace(placeholder, value)
    for placeholder in values:
        if placeholder in text:
            raise SystemExit(f"unresolved placeholder remains: {placeholder}")
    return text


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--ssh-public-key-file", required=True)
    parser.add_argument("--wifi-ssid-file", required=True)
    parser.add_argument("--wifi-password-file", required=True)
    parser.add_argument("--password-hash", required=True)
    parser.add_argument("--node-name", required=True)
    parser.add_argument("--admin-user", required=True)
    parser.add_argument("--timezone", required=True)
    parser.add_argument("--system-disk", required=True)
    parser.add_argument("--data-disk", default="")
    parser.add_argument("--data-mount", default="/data")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    Path(args.output).write_text(render(args))


if __name__ == "__main__":
    main()
