#!/usr/bin/env python3
"""Validate local settings and render unattended-install templates."""

from __future__ import annotations

import argparse
import re
from pathlib import Path
from typing import Dict, Optional
from xml.sax.saxutils import escape


REQUIRED_KEYS = {
    "COMPUTER_NAME",
    "ADMIN_USERNAME",
    "TIME_ZONE",
    "PREFERRED_MIN_TARGET_DISK_BYTES",
    "APP_PREFIX",
}
WINDOWS_RESERVED_NAMES = {
    "AUX",
    "CLOCK$",
    "COM1",
    "COM2",
    "COM3",
    "COM4",
    "COM5",
    "COM6",
    "COM7",
    "COM8",
    "COM9",
    "CON",
    "LPT1",
    "LPT2",
    "LPT3",
    "LPT4",
    "LPT5",
    "LPT6",
    "LPT7",
    "LPT8",
    "LPT9",
    "NUL",
    "PRN",
}
ALLOWED_UNRESOLVED = {"__PROGRAMDATA__", "__TARGET_DISK_ID__"}
PLACEHOLDER_RE = re.compile(r"__[A-Z][A-Z0-9_]*__")


class ConfigError(ValueError):
    """Raised when local configuration is unsafe or incomplete."""


def _validate(config: Dict[str, str]) -> None:
    computer_name = config["COMPUTER_NAME"]
    if (
        not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,13}[A-Za-z0-9])?", computer_name)
        or computer_name.isdigit()
        or computer_name.upper() in WINDOWS_RESERVED_NAMES
    ):
        raise ConfigError(
            "COMPUTER_NAME must be a non-numeric Windows name of 1..15 "
            "letters, digits, or interior hyphens"
        )

    admin_username = config["ADMIN_USERNAME"]
    if (
        not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,19}", admin_username)
        or admin_username.upper() in WINDOWS_RESERVED_NAMES
    ):
        raise ConfigError(
            "ADMIN_USERNAME must start with a letter and contain at most 20 "
            "letters, digits, underscores, or hyphens"
        )

    time_zone = config["TIME_ZONE"]
    if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9 +().-]{0,62}[A-Za-z0-9)])?", time_zone):
        raise ConfigError(
            "TIME_ZONE must contain 1..64 letters, digits, spaces, plus signs, "
            "hyphens, periods, or parentheses"
        )

    preferred_bytes = config["PREFERRED_MIN_TARGET_DISK_BYTES"]
    if not re.fullmatch(r"[0-9]+", preferred_bytes):
        raise ConfigError("PREFERRED_MIN_TARGET_DISK_BYTES must be an integer")
    if not 32_000_000_000 <= int(preferred_bytes) <= 16_000_000_000_000:
        raise ConfigError(
            "PREFERRED_MIN_TARGET_DISK_BYTES must be between 32000000000 "
            "and 16000000000000"
        )

    app_prefix = config["APP_PREFIX"]
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]{1,31}", app_prefix):
        raise ConfigError(
            "APP_PREFIX must contain 2..32 letters or digits and start with a letter"
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
        if not value:
            raise ConfigError(f"{path}:{line_number}: {key} must not be empty")
        config[key] = value

    missing = REQUIRED_KEYS - config.keys()
    if missing:
        raise ConfigError(f"{path}: missing settings: {', '.join(sorted(missing))}")
    _validate(config)
    return config


def render_template(
    template_path: Path,
    output_path: Path,
    config: Dict[str, str],
    admin_password: Optional[str],
) -> None:
    try:
        text = template_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise ConfigError(f"cannot read template {template_path}: {error}") from error

    replacements = {
        "__COMPUTER_NAME_XML__": escape(config["COMPUTER_NAME"]),
        "__ADMIN_USERNAME_XML__": escape(config["ADMIN_USERNAME"]),
        "__TIME_ZONE_XML__": escape(config["TIME_ZONE"]),
        "__PREFERRED_MIN_TARGET_DISK_BYTES_CMD__": config[
            "PREFERRED_MIN_TARGET_DISK_BYTES"
        ],
        "__APP_PREFIX_CMD__": config["APP_PREFIX"],
        "__APP_PREFIX_PS__": config["APP_PREFIX"].replace("'", "''"),
        "__COMPUTER_NAME_PS__": config["COMPUTER_NAME"].replace("'", "''"),
        "__ADMIN_USERNAME_PS__": config["ADMIN_USERNAME"].replace("'", "''"),
    }
    if "__ADMIN_PASSWORD_XML__" in text:
        if admin_password is None or not re.fullmatch(r"[0-9a-f]{48}", admin_password):
            raise ConfigError("administrator password must be 48 lowercase hex characters")
        replacements["__ADMIN_PASSWORD_XML__"] = escape(admin_password)

    for placeholder, value in replacements.items():
        text = text.replace(placeholder, value)

    unresolved = set(PLACEHOLDER_RE.findall(text)) - ALLOWED_UNRESOLVED
    if unresolved:
        raise ConfigError(
            f"{template_path}: unresolved placeholders: {', '.join(sorted(unresolved))}"
        )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(text, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("--config", required=True, type=Path)

    get_parser = subparsers.add_parser("get")
    get_parser.add_argument("--config", required=True, type=Path)
    get_parser.add_argument("--key", required=True, choices=sorted(REQUIRED_KEYS))

    render_parser = subparsers.add_parser("render")
    render_parser.add_argument("--config", required=True, type=Path)
    render_parser.add_argument("--template", required=True, type=Path)
    render_parser.add_argument("--output", required=True, type=Path)
    render_parser.add_argument("--admin-password")

    arguments = parser.parse_args()
    try:
        config = load_config(arguments.config)
        if arguments.command == "get":
            print(config[arguments.key])
        elif arguments.command == "render":
            render_template(
                arguments.template,
                arguments.output,
                config,
                arguments.admin_password,
            )
    except ConfigError as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
