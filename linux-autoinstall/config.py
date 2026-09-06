#!/usr/bin/env python3
"""Validate and read Linux unattended-installer settings."""

from __future__ import annotations

import argparse
import re
from pathlib import Path
from typing import Dict


REQUIRED_KEYS = {
    "ADMIN_USER",
    "CONSOLE_IDLE_SECONDS",
    "DATA_DISK",
    "DATA_MOUNT",
    "NODE_NAME_PREFIX",
    "PREFERRED_MIN_TARGET_DISK_BYTES",
    "SWAPPINESS",
    "SWAP_SIZE_GIB",
    "SYSTEM_DISK",
    "TIMEZONE",
}
ALLOW_EMPTY = {"DATA_DISK"}
DISK_PATH_RE = re.compile(r"/dev/[A-Za-z0-9._/+:-]+")


class ConfigError(ValueError):
    """Raised when local configuration is unsafe or incomplete."""


def _validate_disk_policy(key: str, value: str, allow_empty: bool = False) -> None:
    if allow_empty and not value:
        return
    if value == "auto":
        return
    if not DISK_PATH_RE.fullmatch(value):
        raise ConfigError(f"{key} must be auto or an absolute /dev path")


def _validate(config: Dict[str, str]) -> None:
    prefix = config["NODE_NAME_PREFIX"]
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,19}[a-z0-9])?", prefix):
        raise ConfigError(
            "NODE_NAME_PREFIX must be a lowercase DNS label of at most 21 characters"
        )

    admin_user = config["ADMIN_USER"]
    if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,30}", admin_user):
        raise ConfigError("ADMIN_USER is not a valid Linux account name")

    timezone = config["TIMEZONE"]
    zoneinfo_root = Path("/usr/share/zoneinfo").resolve()
    zoneinfo_path = (zoneinfo_root / timezone).resolve()
    try:
        zoneinfo_path.relative_to(zoneinfo_root)
    except ValueError as error:
        raise ConfigError("TIMEZONE must name an installed IANA timezone") from error
    if (
        not re.fullmatch(r"[A-Za-z0-9_+-]+/[A-Za-z0-9_+./-]+", timezone)
        or ".." in Path(timezone).parts
        or not zoneinfo_path.is_file()
    ):
        raise ConfigError("TIMEZONE must name an installed IANA timezone")

    _validate_disk_policy("SYSTEM_DISK", config["SYSTEM_DISK"])
    _validate_disk_policy("DATA_DISK", config["DATA_DISK"], allow_empty=True)
    if (
        config["SYSTEM_DISK"] != "auto"
        and config["DATA_DISK"] not in {"", "auto"}
        and config["SYSTEM_DISK"] == config["DATA_DISK"]
    ):
        raise ConfigError("DATA_DISK must differ from SYSTEM_DISK")

    data_mount = config["DATA_MOUNT"]
    if (
        not re.fullmatch(r"/[A-Za-z0-9._/+:-]+", data_mount)
        or data_mount == "/"
        or data_mount.endswith("/")
        or ".." in Path(data_mount).parts
    ):
        raise ConfigError(
            "DATA_MOUNT must be a non-root absolute path without a trailing slash"
        )

    preferred_bytes = config["PREFERRED_MIN_TARGET_DISK_BYTES"]
    if (
        not preferred_bytes.isdigit()
        or not 32_000_000_000 <= int(preferred_bytes) <= 16_000_000_000_000
    ):
        raise ConfigError(
            "PREFERRED_MIN_TARGET_DISK_BYTES must be between 32000000000 "
            "and 16000000000000"
        )

    swap_size = config["SWAP_SIZE_GIB"]
    if not swap_size.isdigit() or not 1 <= int(swap_size) <= 1024:
        raise ConfigError("SWAP_SIZE_GIB must be an integer from 1 through 1024")

    swappiness = config["SWAPPINESS"]
    if not swappiness.isdigit() or not 0 <= int(swappiness) <= 100:
        raise ConfigError("SWAPPINESS must be an integer from 0 through 100")

    idle_seconds = config["CONSOLE_IDLE_SECONDS"]
    if not idle_seconds.isdigit() or not 10 <= int(idle_seconds) <= 3600:
        raise ConfigError(
            "CONSOLE_IDLE_SECONDS must be an integer from 10 through 3600"
        )


def load_config(path: Path) -> Dict[str, str]:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise ConfigError(f"cannot read config {path}: {error}") from error

    config: Dict[str, str] = {}
    for line_number, line in enumerate(text.splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        if line != line.strip() or "=" not in line:
            raise ConfigError(
                f"{path}:{line_number}: expected KEY=value without surrounding whitespace"
            )
        key, value = line.split("=", 1)
        if key not in REQUIRED_KEYS:
            raise ConfigError(f"{path}:{line_number}: unknown setting {key!r}")
        if key in config:
            raise ConfigError(f"{path}:{line_number}: duplicate setting {key!r}")
        if not value and key not in ALLOW_EMPTY:
            raise ConfigError(f"{path}:{line_number}: {key} must not be empty")
        config[key] = value

    missing = REQUIRED_KEYS - config.keys()
    if missing:
        raise ConfigError(f"{path}: missing settings: {', '.join(sorted(missing))}")
    _validate(config)
    return config


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("--config", required=True, type=Path)

    get_parser = subparsers.add_parser("get")
    get_parser.add_argument("--config", required=True, type=Path)
    get_parser.add_argument("--key", required=True, choices=sorted(REQUIRED_KEYS))

    args = parser.parse_args()
    try:
        config = load_config(args.config)
        if args.command == "get":
            print(config[args.key])
    except ConfigError as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
