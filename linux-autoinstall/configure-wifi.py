#!/usr/bin/env python3
"""Apply the detected Wi-Fi interface to normalized autoinstall YAML."""

from __future__ import annotations

import argparse
import re
from pathlib import Path
from typing import Any

import yaml


INTERFACE_TOKEN = "AI_NODE_WIFI_INTERFACE"


class WifiConfigurationError(ValueError):
    """Raised when the autoinstall Wi-Fi structure is not as expected."""


def _atomic_write(path: Path, text: str, mode: int) -> None:
    temporary = path.with_name(f"{path.name}.configure-wifi")
    temporary.write_text(text, encoding="utf-8")
    temporary.chmod(mode)
    temporary.replace(path)


def configure_wifi(
    autoinstall_path: Path,
    persistent_path: Path,
    interface: str,
) -> None:
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,15}", interface):
        raise WifiConfigurationError(f"invalid Wi-Fi interface: {interface}")

    text = autoinstall_path.read_text(encoding="utf-8")
    try:
        document = yaml.safe_load(text)
    except yaml.YAMLError as error:
        raise WifiConfigurationError(
            f"autoinstall document is invalid YAML: {error}"
        ) from error
    if not isinstance(document, dict):
        raise WifiConfigurationError("autoinstall document must be a mapping")
    autoinstall = document.get("autoinstall", document)
    if not isinstance(autoinstall, dict):
        raise WifiConfigurationError(
            "autoinstall configuration must be a mapping"
        )
    network = autoinstall.get("network")
    if not isinstance(network, dict):
        raise WifiConfigurationError("autoinstall network configuration is missing")
    wifis = network.get("wifis")
    if not isinstance(wifis, dict) or set(wifis) != {INTERFACE_TOKEN}:
        raise WifiConfigurationError(
            f"autoinstall network must contain exactly one {INTERFACE_TOKEN}"
        )

    wifi_config = wifis.pop(INTERFACE_TOKEN)
    wifis[interface] = wifi_config
    rendered = yaml.safe_dump(document, sort_keys=False)
    if text.startswith("#cloud-config"):
        rendered = "#cloud-config\n" + rendered
    _atomic_write(
        autoinstall_path,
        rendered,
        autoinstall_path.stat().st_mode & 0o777,
    )

    persistent = {
        "network": {
            "version": 2,
            "renderer": "networkd",
            "wifis": {interface: wifi_config},
        }
    }
    _atomic_write(
        persistent_path,
        yaml.safe_dump(persistent, sort_keys=False),
        0o600,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--autoinstall", required=True, type=Path)
    parser.add_argument("--persistent-output", required=True, type=Path)
    parser.add_argument("--interface", required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    configure_wifi(
        args.autoinstall,
        args.persistent_output,
        args.interface,
    )


if __name__ == "__main__":
    main()
