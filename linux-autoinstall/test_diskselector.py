import tempfile
import unittest
from pathlib import Path

from diskselector import (
    Disk,
    SelectionError,
    choose_system,
    parse_inventory,
    rewrite_autoinstall,
    select_disks,
)


GIB = 1024 * 1024 * 1024


def disk(
    path: str,
    size_gib: int,
    transport: str,
    *,
    removable: bool = False,
    read_only: bool = False,
    hotplug: bool = False,
    installer_backing: bool = False,
) -> Disk:
    return Disk(
        path=path,
        size_bytes=size_gib * GIB,
        transport=transport,
        removable=removable,
        read_only=read_only,
        rotational=transport == "sata",
        hotplug=hotplug,
        aliases=frozenset({path}),
        installer_backing=installer_backing,
    )


class DiskSelectorTests(unittest.TestCase):
    def test_prefers_nvme_meeting_capacity(self) -> None:
        selected = choose_system(
            [
                disk("/dev/mmcblk0", 120, "mmc"),
                disk("/dev/nvme0n1", 120, "nvme"),
            ],
            60_000_000_000,
            32_000_000_000,
        )
        self.assertEqual(selected.path, "/dev/nvme0n1")

    def test_capacity_precedes_performance(self) -> None:
        selected = choose_system(
            [
                disk("/dev/nvme0n1", 32, "nvme"),
                disk("/dev/mmcblk0", 120, "mmc"),
            ],
            60_000_000_000,
            32_000_000_000,
        )
        self.assertEqual(selected.path, "/dev/mmcblk0")

    def test_falls_back_to_largest_below_preferred_size(self) -> None:
        selected = choose_system(
            [
                disk("/dev/nvme0n1", 32, "nvme"),
                disk("/dev/mmcblk0", 48, "mmc"),
            ],
            60_000_000_000,
            32_000_000_000,
        )
        self.assertEqual(selected.path, "/dev/mmcblk0")

    def test_auto_excludes_unsafe_disks(self) -> None:
        selected = choose_system(
            [
                disk("/dev/sda", 500, "usb"),
                disk("/dev/sdb", 500, "sata", removable=True),
                disk("/dev/sdc", 500, "sata", read_only=True),
                disk("/dev/sdd", 500, "nvme", installer_backing=True),
                disk("/dev/sde", 500, "nvmeof"),
                disk("/dev/sdf", 500, "iscsi"),
                disk("/dev/sdg", 500, ""),
                disk("/dev/sdh", 500, "nvme", hotplug=True),
                disk("/dev/mmcblk0", 64, "mmc"),
            ],
            60_000_000_000,
            32_000_000_000,
        )
        self.assertEqual(selected.path, "/dev/mmcblk0")

    def test_auto_data_uses_all_remaining_internal_disks(self) -> None:
        system, data = select_disks(
            [
                disk("/dev/nvme0n1", 128, "nvme"),
                disk("/dev/sdb", 500, "sata"),
                disk("/dev/sda", 1_000, "sata"),
                disk("/dev/sdc", 2_000, "usb"),
                disk("/dev/sdd", 2_000, "sata", hotplug=True),
            ],
            "auto",
            "auto",
            60_000_000_000,
            32_000_000_000,
        )
        self.assertEqual(system.path, "/dev/nvme0n1")
        self.assertEqual(
            [selected.path for selected in data],
            ["/dev/sda", "/dev/sdb"],
        )

    def test_auto_data_allows_no_secondary_disks(self) -> None:
        system, data = select_disks(
            [disk("/dev/nvme0n1", 128, "nvme")],
            "auto",
            "auto",
            60_000_000_000,
            32_000_000_000,
        )
        self.assertEqual(system.path, "/dev/nvme0n1")
        self.assertEqual(data, [])

    def test_explicit_system_does_not_weaken_automatic_data_safety(self) -> None:
        system, data = select_disks(
            [
                disk("/dev/sda", 128, "usb"),
                disk("/dev/nvme0n1", 500, "nvme"),
                disk("/dev/sdb", 500, "usb"),
            ],
            "/dev/sda",
            "auto",
            60_000_000_000,
            32_000_000_000,
        )
        self.assertEqual(system.path, "/dev/sda")
        self.assertEqual(
            [selected.path for selected in data],
            ["/dev/nvme0n1"],
        )

    def test_explicit_nonremovable_usb_disk_is_allowed(self) -> None:
        selected, _ = select_disks(
            [disk("/dev/sda", 128, "usb")],
            "/dev/sda",
            "",
            60_000_000_000,
            32_000_000_000,
        )
        self.assertEqual(selected.path, "/dev/sda")

    def test_explicit_installer_disk_is_rejected(self) -> None:
        with self.assertRaises(SelectionError):
            select_disks(
                [disk("/dev/sda", 128, "usb", installer_backing=True)],
                "/dev/sda",
                "",
                60_000_000_000,
                32_000_000_000,
            )

    def test_explicit_partition_is_rejected(self) -> None:
        candidate = Disk(
            path="/dev/sda",
            size_bytes=128 * GIB,
            transport="sata",
            removable=False,
            read_only=False,
            rotational=True,
            hotplug=False,
            aliases=frozenset({"/dev/sda", "/dev/sda1"}),
            installer_backing=False,
        )
        with self.assertRaises(SelectionError):
            select_disks(
                [candidate],
                "/dev/sda1",
                "",
                60_000_000_000,
                32_000_000_000,
            )

    def test_rejects_system_disk_below_hard_minimum(self) -> None:
        with self.assertRaises(SelectionError):
            select_disks(
                [disk("/dev/nvme0n1", 24, "nvme")],
                "auto",
                "",
                60_000_000_000,
                32_000_000_000,
            )

    def test_inventory_maps_installer_partition_to_parent_disk(self) -> None:
        inventory = {
            "blockdevices": [
                {
                    "name": "sda",
                    "path": "/dev/sda",
                    "type": "disk",
                    "size": 64 * GIB,
                    "rota": True,
                    "rm": False,
                    "ro": False,
                    "hotplug": False,
                    "tran": "usb",
                    "children": [
                        {
                            "name": "sda1",
                            "path": "/dev/sda1",
                            "type": "part",
                            "mountpoints": ["/cdrom"],
                        }
                    ],
                }
            ]
        }
        parsed = parse_inventory(inventory, ["/dev/sda1"])
        self.assertTrue(parsed[0].installer_backing)

    def test_inventory_allows_optical_installer_source(self) -> None:
        inventory = {
            "blockdevices": [
                {
                    "name": "sr0",
                    "path": "/dev/sr0",
                    "type": "rom",
                    "mountpoints": ["/cdrom"],
                },
                {
                    "name": "nvme0n1",
                    "path": "/dev/nvme0n1",
                    "type": "disk",
                    "size": 128 * GIB,
                    "rota": False,
                    "rm": False,
                    "ro": False,
                    "hotplug": False,
                    "tran": "nvme",
                },
            ]
        }
        parsed = parse_inventory(inventory, ["/dev/sr0"])
        self.assertFalse(parsed[0].installer_backing)
        self.assertEqual(parsed[0].transport, "nvme")

    def test_inventory_rejects_unmapped_installer_source(self) -> None:
        inventory = {
            "blockdevices": [
                {
                    "name": "nvme0n1",
                    "path": "/dev/nvme0n1",
                    "type": "disk",
                    "size": 128 * GIB,
                    "rota": False,
                    "rm": False,
                    "ro": False,
                    "hotplug": False,
                    "tran": "nvme",
                }
            ]
        }
        with self.assertRaises(SelectionError):
            parse_inventory(inventory, ["/dev/loop0"])

    def test_rewrites_only_expected_runtime_tokens(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "user-data"
            path.write_text(
                '        path: "AI_NODE_RUNTIME_SYSTEM_DISK"\n'
                "# AI_NODE_RUNTIME_DATA_STORAGE\n",
                encoding="utf-8",
            )
            rewrite_autoinstall(
                path,
                disk("/dev/nvme0n1", 128, "nvme"),
                [
                    disk("/dev/sdb", 500, "sata"),
                    disk("/dev/sdc", 750, "nvme"),
                ],
                "/data",
            )
            rendered = path.read_text(encoding="utf-8")
            self.assertIn('        path: "/dev/nvme0n1"', rendered)
            self.assertIn('        path: "/dev/sdb"', rendered)
            self.assertIn('        path: "/dev/sdc"', rendered)
            self.assertIn('        path: "/data"', rendered)
            self.assertIn('        path: "/data2"', rendered)
            self.assertNotIn("AI_NODE_RUNTIME", rendered)

    def test_rewrite_removes_marker_when_no_secondary_disk_exists(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "user-data"
            path.write_text(
                '        path: "AI_NODE_RUNTIME_SYSTEM_DISK"\n'
                "# AI_NODE_RUNTIME_DATA_STORAGE\n",
                encoding="utf-8",
            )
            rewrite_autoinstall(
                path,
                disk("/dev/nvme0n1", 128, "nvme"),
                [],
                "/data",
            )
            self.assertEqual(
                path.read_text(encoding="utf-8"),
                '        path: "/dev/nvme0n1"\n\n',
            )


if __name__ == "__main__":
    unittest.main()
