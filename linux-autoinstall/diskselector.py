#!/usr/bin/env python3
"""Select safe Linux installation disks from lsblk inventory."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


RUNTIME_SYSTEM_TOKEN = "AI_NODE_RUNTIME_SYSTEM_DISK"
RUNTIME_DATA_STORAGE_MARKER = "# AI_NODE_RUNTIME_DATA_STORAGE"
AUTO_ALLOWED_TRANSPORTS = {
    "ata",
    "mmc",
    "nvme",
    "raid",
    "sas",
    "sata",
    "scsi",
    "sd",
    "ufs",
    "virtio",
}


class SelectionError(ValueError):
    """Raised when automatic disk selection cannot safely continue."""


@dataclass(frozen=True)
class Disk:
    path: str
    size_bytes: int
    transport: str
    removable: bool
    read_only: bool
    rotational: bool
    hotplug: bool
    aliases: frozenset[str]
    installer_backing: bool


def _mountpoints(node: dict[str, Any]) -> list[str]:
    values = node.get("mountpoints")
    if values is None:
        value = node.get("mountpoint")
        return [value] if value else []
    if isinstance(values, str):
        return [values]
    return [value for value in values if value]


def _bool_field(node: dict[str, Any], key: str, default: bool) -> bool:
    value = node.get(key)
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, int):
        return value != 0
    normalized = str(value).strip().lower()
    if normalized in {"0", "false"}:
        return False
    if normalized in {"1", "true"}:
        return True
    return default


def _walk(node: dict[str, Any]) -> Iterable[dict[str, Any]]:
    yield node
    for child in node.get("children") or []:
        yield from _walk(child)


def _transport(node: dict[str, Any]) -> str:
    transport = str(node.get("tran") or "").lower()
    if transport:
        return transport
    name = str(node.get("name") or "")
    if name.startswith("nvme"):
        return "nvme"
    if name.startswith("mmcblk"):
        return "mmc"
    if name.startswith(("vd", "xvd")):
        return "virtio"
    return ""


def parse_inventory(
    inventory: dict[str, Any], installer_sources: Iterable[str]
) -> list[Disk]:
    sources = {
        os.path.realpath(source.split("[", 1)[0])
        for source in installer_sources
        if source.startswith("/dev/")
    }
    if not sources:
        raise SelectionError("installer media source could not be identified")

    all_nodes = [
        node
        for root in inventory.get("blockdevices", [])
        for node in _walk(root)
    ]
    node_types = {
        os.path.realpath(
            str(node.get("path") or f"/dev/{node.get('name', '')}")
        ): str(node.get("type") or "")
        for node in all_nodes
    }
    mapped_sources = {
        source for source in sources if node_types.get(source) == "rom"
    }
    disks = []
    for root in inventory.get("blockdevices", []):
        if root.get("type") != "disk":
            continue
        nodes = list(_walk(root))
        aliases = {
            os.path.realpath(str(node.get("path") or f"/dev/{node.get('name', '')}"))
            for node in nodes
        }
        mountpoints = {
            mountpoint
            for node in nodes
            for mountpoint in _mountpoints(node)
        }
        installer_backing = bool(aliases & sources) or any(
            mountpoint == "/cdrom" or mountpoint.startswith("/cdrom/")
            for mountpoint in mountpoints
        )
        mapped_sources.update(aliases & sources)
        disks.append(
            Disk(
                path=str(root.get("path") or f"/dev/{root['name']}"),
                size_bytes=int(root.get("size") or 0),
                transport=_transport(root),
                removable=_bool_field(root, "rm", True),
                read_only=_bool_field(root, "ro", True),
                rotational=_bool_field(root, "rota", True),
                hotplug=_bool_field(root, "hotplug", True),
                aliases=frozenset(aliases),
                installer_backing=installer_backing,
            )
        )
    unresolved_sources = sources - mapped_sources
    if unresolved_sources:
        raise SelectionError(
            "installer source could not be mapped safely: "
            + ", ".join(sorted(unresolved_sources))
        )
    return disks


def _performance_score(disk: Disk) -> int:
    if disk.transport in {"nvme", "nvmeof"}:
        return 600
    if disk.transport == "ufs":
        return 500
    if disk.transport in {"sata", "sas", "raid"}:
        return 400
    if disk.transport in {"ata", "scsi", "virtio"}:
        return 300
    if disk.transport in {"fc", "iscsi"}:
        return 200
    if disk.transport in {"mmc", "sd"}:
        return 100
    return 250 if not disk.rotational else 150


def _safe_explicit(disk: Disk) -> bool:
    return (
        disk.size_bytes > 0
        and not disk.removable
        and not disk.read_only
        and not disk.installer_backing
    )


def _safe_automatic(disk: Disk) -> bool:
    return (
        _safe_explicit(disk)
        and not disk.hotplug
        and disk.transport in AUTO_ALLOWED_TRANSPORTS
    )


def choose_system(
    candidates: list[Disk],
    preferred_min_bytes: int,
    minimum_system_bytes: int,
) -> Disk:
    eligible = [
        disk
        for disk in candidates
        if _safe_automatic(disk) and disk.size_bytes >= minimum_system_bytes
    ]
    if not eligible:
        raise SelectionError(
            "no usable internal system disk meets the minimum required size "
            f"of {minimum_system_bytes} bytes"
        )

    def rank(disk: Disk) -> tuple[int, int, int, str]:
        large_enough = disk.size_bytes >= preferred_min_bytes
        if large_enough:
            return (1, _performance_score(disk), disk.size_bytes, disk.path)
        return (0, disk.size_bytes, _performance_score(disk), disk.path)

    return max(eligible, key=rank)


def choose_explicit(candidates: list[Disk], configured_path: str, role: str) -> Disk:
    resolved = os.path.realpath(configured_path)
    matching = [
        disk for disk in candidates if resolved == os.path.realpath(disk.path)
    ]
    if len(matching) != 1:
        raise SelectionError(
            f"configured {role} disk {configured_path} is not one whole disk"
        )
    selected = matching[0]
    if not _safe_explicit(selected):
        raise SelectionError(
            f"configured {role} disk {configured_path} is removable, read-only, "
            "or backs the installer"
        )
    return selected


def select_disks(
    candidates: list[Disk],
    system_policy: str,
    data_policy: str,
    preferred_min_bytes: int,
    minimum_system_bytes: int,
) -> tuple[Disk, list[Disk]]:
    if system_policy == "auto":
        system = choose_system(
            candidates, preferred_min_bytes, minimum_system_bytes
        )
    else:
        system = choose_explicit(candidates, system_policy, "system")
        if system.size_bytes < minimum_system_bytes:
            raise SelectionError(
                f"configured system disk {system_policy} is smaller than the "
                f"minimum required {minimum_system_bytes} bytes"
            )

    data: list[Disk] = []
    remaining = [disk for disk in candidates if disk.path != system.path]
    if data_policy == "auto":
        data = sorted(
            (disk for disk in remaining if _safe_automatic(disk)),
            key=lambda disk: disk.path,
        )
    elif data_policy:
        data = [choose_explicit(remaining, data_policy, "data")]
    return system, data


def render_data_storage(disks: list[Disk], mount_root: str) -> str:
    blocks = []
    for index, disk in enumerate(disks, 1):
        suffix = "" if index == 1 else str(index)
        disk_id = f"disk-data-{index}"
        partition_id = f"partition-data-{index}"
        format_id = f"format-data-{index}"
        blocks.append(
            f"""      - type: disk
        id: {disk_id}
        path: {json.dumps(disk.path)}
        ptable: gpt
        wipe: superblock-recursive
        preserve: false
        grub_device: false
      - type: partition
        id: {partition_id}
        device: {disk_id}
        size: -1
        number: 1
        preserve: false
        wipe: superblock
      - type: format
        id: {format_id}
        volume: {partition_id}
        fstype: ext4
        label: ai-data-{index}
        preserve: false
      - type: mount
        id: mount-data-{index}
        device: {format_id}
        path: {json.dumps(f"{mount_root}{suffix}")}"""
        )
    return "\n".join(blocks)


def rewrite_autoinstall(
    path: Path,
    system: Disk,
    data: list[Disk],
    data_mount: str,
) -> None:
    text = path.read_text(encoding="utf-8")
    system_line = f'        path: "{RUNTIME_SYSTEM_TOKEN}"'
    if text.count(system_line) != 1:
        raise SelectionError(
            f"autoinstall document must contain exactly one {RUNTIME_SYSTEM_TOKEN}"
        )
    text = text.replace(system_line, f'        path: "{system.path}"')
    expected_data_markers = (
        1 if data or RUNTIME_DATA_STORAGE_MARKER in text else 0
    )
    if text.count(RUNTIME_DATA_STORAGE_MARKER) != expected_data_markers:
        raise SelectionError(
            f"autoinstall document must contain {expected_data_markers} "
            f"{RUNTIME_DATA_STORAGE_MARKER} marker(s)"
        )
    if RUNTIME_DATA_STORAGE_MARKER in text:
        text = text.replace(
            RUNTIME_DATA_STORAGE_MARKER,
            render_data_storage(data, data_mount),
        )
    temporary = path.with_name(f"{path.name}.diskselector")
    temporary.write_text(text, encoding="utf-8")
    temporary.replace(path)


def load_runtime_inventory() -> tuple[dict[str, Any], list[str]]:
    subprocess.run(
        ["udevadm", "settle", "--timeout=30"],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    inventory_text = subprocess.check_output(
        [
            "lsblk",
            "--json",
            "--bytes",
            "--output",
            "NAME,PATH,TYPE,SIZE,ROTA,RM,RO,HOTPLUG,TRAN,MOUNTPOINTS",
        ],
        text=True,
    )
    source_text = subprocess.check_output(
        ["findmnt", "-rn", "-o", "SOURCE", "--target", "/cdrom"],
        text=True,
    )
    return json.loads(inventory_text), source_text.splitlines()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--autoinstall", required=True, type=Path)
    parser.add_argument("--system-policy", required=True)
    parser.add_argument("--data-policy", default="")
    parser.add_argument("--preferred-min-bytes", required=True, type=int)
    parser.add_argument("--minimum-system-bytes", required=True, type=int)
    parser.add_argument("--data-mount", default="/data")
    args = parser.parse_args()

    try:
        inventory, installer_sources = load_runtime_inventory()
        candidates = parse_inventory(inventory, installer_sources)
        for disk in candidates:
            print(
                f"{disk.path}: size={disk.size_bytes} transport="
                f"{disk.transport or 'unknown'} removable={disk.removable} "
                f"read_only={disk.read_only} hotplug={disk.hotplug} "
                f"installer={disk.installer_backing}"
            )
        system, data = select_disks(
            candidates,
            args.system_policy,
            args.data_policy,
            args.preferred_min_bytes,
            args.minimum_system_bytes,
        )
        if system.size_bytes >= args.preferred_min_bytes:
            reason = "highest-performance internal disk meeting the preferred size"
        else:
            reason = "best available internal disk below the preferred size"
        print(f"Selected system disk {system.path}: {reason}.")
        for index, data_disk in enumerate(data, 1):
            suffix = "" if index == 1 else str(index)
            print(
                f"Selected data disk {data_disk.path}: "
                f"will mount at {args.data_mount}{suffix}."
            )
        rewrite_autoinstall(args.autoinstall, system, data, args.data_mount)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"automatic disk selection unavailable: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
