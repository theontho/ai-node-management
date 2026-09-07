import tempfile
import unittest
from pathlib import Path

from config import ConfigError, load_config


VALID_CONFIG = """\
NODE_NAME_PREFIX=lin
ADMIN_USER=node-admin
TIMEZONE=Etc/UTC
SYSTEM_DISK=auto
DATA_MOUNT=/data
PREFERRED_MIN_TARGET_DISK_BYTES=60000000000
SWAP_SIZE_GIB=16
SWAPPINESS=10
CONSOLE_IDLE_SECONDS=60
"""


class ConfigTests(unittest.TestCase):
    def load(self, text: str) -> dict[str, str]:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "config.env"
            path.write_text(text, encoding="utf-8")
            return load_config(path)

    def test_accepts_automatic_system_storage(self) -> None:
        config = self.load(VALID_CONFIG)
        self.assertEqual(config["SYSTEM_DISK"], "auto")

    def test_accepts_explicit_system_storage(self) -> None:
        config = self.load(
            VALID_CONFIG.replace("SYSTEM_DISK=auto", "SYSTEM_DISK=/dev/nvme0n1")
        )
        self.assertEqual(config["SYSTEM_DISK"], "/dev/nvme0n1")

    def test_rejects_legacy_data_disk_policy(self) -> None:
        with self.assertRaises(ConfigError):
            self.load(VALID_CONFIG + "DATA_DISK=auto\n")

    def test_rejects_unknown_setting(self) -> None:
        with self.assertRaises(ConfigError):
            self.load(VALID_CONFIG + "UNEXPECTED=value\n")

    def test_rejects_duplicate_setting(self) -> None:
        with self.assertRaises(ConfigError):
            self.load(VALID_CONFIG + "ADMIN_USER=other\n")

    def test_rejects_shell_syntax(self) -> None:
        with self.assertRaises(ConfigError):
            self.load(VALID_CONFIG.replace("ADMIN_USER=node-admin", "export ADMIN_USER=x"))

    def test_rejects_data_mount_with_trailing_slash(self) -> None:
        with self.assertRaises(ConfigError):
            self.load(VALID_CONFIG.replace("DATA_MOUNT=/data", "DATA_MOUNT=/data/"))

    def test_rejects_timezone_traversal(self) -> None:
        with self.assertRaises(ConfigError):
            self.load(
                VALID_CONFIG.replace(
                    "TIMEZONE=Etc/UTC",
                    "TIMEZONE=Etc/../../../../etc/passwd",
                )
            )

    def test_rejects_oversized_swap(self) -> None:
        with self.assertRaises(ConfigError):
            self.load(
                VALID_CONFIG.replace("SWAP_SIZE_GIB=16", "SWAP_SIZE_GIB=2048")
            )


if __name__ == "__main__":
    unittest.main()
