#!/usr/bin/env python3
import argparse
import json
import re
import shlex
from pathlib import Path


def render_storage() -> str:
    return f"""  storage:
    swap:
      size: 0
    config:
      - type: disk
        id: disk-system
        path: {json.dumps("AI_NODE_RUNTIME_SYSTEM_DISK")}
        ptable: gpt
        wipe: superblock-recursive
        preserve: false
        grub_device: true
      - type: partition
        id: partition-bios-grub
        device: disk-system
        size: 2M
        flag: bios_grub
        number: 1
        preserve: false
        wipe: superblock
      - type: partition
        id: partition-efi
        device: disk-system
        size: 1G
        flag: boot
        grub_device: true
        number: 2
        preserve: false
        wipe: superblock
      - type: format
        id: format-efi
        volume: partition-efi
        fstype: fat32
        label: AI_NODE_EFI
        preserve: false
      - type: mount
        id: mount-efi
        device: format-efi
        path: /boot/efi
      - type: partition
        id: partition-root
        device: disk-system
        size: -1
        number: 3
        preserve: false
        wipe: superblock
      - type: format
        id: format-root
        volume: partition-root
        fstype: ext4
        label: ai-node-root
        preserve: false
      - type: mount
        id: mount-root
        device: format-root
        path: /"""


def render_wifi(args: argparse.Namespace) -> tuple[str, str, str, str]:
    if bool(args.wifi_ssid_file) != bool(args.wifi_password_file):
        raise SystemExit(
            "wifi-ssid-file and wifi-password-file must both be provided or omitted"
        )
    if not args.wifi_ssid_file:
        return "", "", "", ""

    ssid = json.dumps(Path(args.wifi_ssid_file).read_text().strip())
    password = json.dumps(Path(args.wifi_password_file).read_text().strip())
    early_commands = f"""    - |
      pcsc_package=$(find /cdrom/pool/main/p/pcsc-lite -maxdepth 1 -name 'libpcsclite1_*_amd64.deb' -print -quit)
      wpa_package=$(find /cdrom/pool/main/w/wpa -maxdepth 1 -name 'wpasupplicant_*_amd64.deb' -print -quit)
      if [ -z "$pcsc_package" ] || [ -z "$wpa_package" ]; then
        echo "Offline Wi-Fi packages are missing from the installer media." >&2
        exit 1
      fi
      dpkg -i "$pcsc_package" "$wpa_package"
    - |
      wifi_interface=
      for attempt in $(seq 1 30); do
        for interface_path in /sys/class/net/*; do
          if [ -d "$interface_path/wireless" ]; then
            wifi_interface=${{interface_path##*/}}
            break 2
          fi
        done
        sleep 2
      done
      if [ -z "$wifi_interface" ]; then
        echo "No wireless interface was detected after 60 seconds." >&2
        exit 1
      fi
      /cdrom/nocloud/assets/configure-wifi.py \\
        --autoinstall /autoinstall.yaml \\
        --persistent-output /tmp/60-ai-node-wifi.yaml \\
        --interface "$wifi_interface" """
    network = f"""    wifis:
      "AI_NODE_WIFI_INTERFACE":
        dhcp4: true
        optional: false
        access-points:
          {ssid}:
            password: {password}"""
    late_command = (
        "    - install -D -m 0600 /tmp/60-ai-node-wifi.yaml "
        "/target/etc/netplan/60-ai-node-wifi.yaml"
    )
    return early_commands, network, late_command, "    - wpasupplicant"


def render(args: argparse.Namespace) -> str:
    wifi_early, wifi_network, wifi_late, wifi_package = render_wifi(args)
    if args.interactive_storage:
        interactive_sections = "[storage]"
        disk_early = ""
        storage = """  storage:
    layout:
      name: direct"""
    else:
        interactive_sections = "[]"
        disk_early = f"""    - |
      if ! /cdrom/nocloud/assets/diskselector.py \\
        --autoinstall /autoinstall.yaml \\
        --system-policy {shlex.quote(args.system_disk_policy)} \\
        --preferred-min-bytes {args.preferred_min_target_disk_bytes} \\
        --minimum-system-bytes {args.minimum_system_disk_bytes} \\
        --data-mount {shlex.quote(args.data_mount)}; then
        echo "Safe automatic disk selection failed; enabling interactive storage selection." >&2
        cp /cdrom/nocloud/storage-fallback-user-data /autoinstall.yaml
      fi"""
        storage = render_storage()

    values = {
        "__INTERACTIVE_SECTIONS__": interactive_sections,
        "__DISK_SELECTION_EARLY_COMMAND__": disk_early,
        "__WIFI_EARLY_COMMANDS__": wifi_early,
        "__WIFI_NETWORK__": wifi_network,
        "__WIFI_LATE_COMMAND__": wifi_late,
        "__WIFI_PACKAGE__": wifi_package,
        "__STORAGE_CONFIG__": storage,
        "__SSH_PUBLIC_KEY__": json.dumps(
            Path(args.ssh_public_key_file).read_text().strip()
        ),
        "__PASSWORD_HASH__": json.dumps(args.password_hash),
        "__NODE_NAME_PREFIX_SHELL__": shlex.quote(args.node_name_prefix),
        "__ADMIN_USER__": json.dumps(args.admin_user),
        "__TIMEZONE__": json.dumps(args.timezone),
    }
    text = Path(args.template).read_text()
    unresolved = set(re.findall(r"__[A-Z][A-Z0-9_]*__", text)) - values.keys()
    if unresolved:
        raise SystemExit(
            f"unknown template placeholders: {', '.join(sorted(unresolved))}"
        )
    placeholder_pattern = re.compile(
        "|".join(re.escape(placeholder) for placeholder in values)
    )
    return placeholder_pattern.sub(lambda match: values[match.group(0)], text)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--ssh-public-key-file", required=True)
    parser.add_argument("--wifi-ssid-file", default="")
    parser.add_argument("--wifi-password-file", default="")
    parser.add_argument("--password-hash", required=True)
    parser.add_argument("--node-name-prefix", required=True)
    parser.add_argument("--admin-user", required=True)
    parser.add_argument("--timezone", required=True)
    parser.add_argument("--system-disk-policy", required=True)
    parser.add_argument("--data-mount", default="/data")
    parser.add_argument("--preferred-min-target-disk-bytes", required=True, type=int)
    parser.add_argument("--minimum-system-disk-bytes", required=True, type=int)
    parser.add_argument("--interactive-storage", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    Path(args.output).write_text(render(args))


if __name__ == "__main__":
    main()
