# Windows 11 unattended USB builder

This MIT-licensed project builds a bootable Windows 11 Pro installer image on
macOS. It configures a local administrator, Wi-Fi, and key-only OpenSSH access
without committing machine settings or secrets.

> **Destructive behavior:** booting the generated media can erase internal
> disks without confirmation. The selector excludes every physical disk that
> backs the installer volume, rejects removable USB media as an installation
> target, and prefers the fastest internal disk meeting the configured size.
> If none meets that preference, it selects the largest eligible internal
> disk. It also attempts to remove partition tables from other eligible
> internal disks. If safe automatic selection cannot run, it falls back to
> ordinary interactive Windows Setup instead of supplying an answer file.

Review `diskpolicy.go`, its tests, and your configuration before using this
tool. Test recovery procedures before relying on the resulting machine.

## Requirements

The image builder is intentionally macOS-specific. It requires:

- macOS `diskutil`, `hdiutil`, `stat`, and `shasum`
- Bash, Python 3, Go, OpenSSL, rsync, OpenSSH `ssh-keygen`, `xmllint`, and
  `wimlib-imagex`
- An official x64 Windows 11 ISO containing Windows 11 Pro

Static validation additionally requires ShellCheck. Homebrew can provide the
non-system dependencies (for example, `go`, `openssl`, `rsync`, `wimlib`,
`libxml2`, and `shellcheck`).

## Local configuration

Configuration is never sourced as shell code. `config.py` parses a strict
`KEY=value` format, rejects unknown or duplicate keys, validates every value,
and performs context-specific template rendering.

```sh
mkdir -p local/private output
cp config.example.env local/config.env
```

Edit `local/config.env`:

| Setting | Purpose |
| --- | --- |
| `COMPUTER_NAME` | Windows computer name (1–15 tightly restricted characters) |
| `ADMIN_USERNAME` | Local administrator and allowed SSH username |
| `TIME_ZONE` | Windows time-zone identifier, such as `UTC` |
| `PREFERRED_MIN_TARGET_DISK_BYTES` | Preferred minimum internal target size |
| `APP_PREFIX` | Safe internal ProgramData, task, mutex, and firewall prefix |

The committed example uses generic `AI-NODE`, `ai-admin`, `UTC`,
`60000000000`, and `AiNode` defaults. The entire `local/` directory is ignored.

Create these three separate private files under `local/private/`:

- `wifi-ssid` — one SSID
- `wifi-password` — one WPA2 passphrase
- `ssh-public-key` — one valid OpenSSH public key

Do not place private keys there. The Wi-Fi profile and public key are embedded
in generated media, then removed from the installed host after provisioning.
The generated recovery report contains the random local administrator password.
Both the image and report are credential-bearing private artifacts.

## Build

First calculate and independently verify the official ISO's SHA-256 digest,
then run:

```sh
./build-image.sh \
  --base-iso local/Windows11.iso \
  --base-sha256 YOUR_VERIFIED_64_HEX_DIGEST \
  --config local/config.env \
  --private-dir local/private \
  --output output/ai-node-installer.dmg
```

Optional flags are `--recovery-report FILE` and `--image-size-gb INTEGER`
(minimum 10 GiB; default 12). The builder verifies the source ISO checksum,
uses an MBR/FAT32 layout for broad UEFI compatibility, splits oversized WIM
files, updates WinPE, mounts the result read-only, and verifies its layout and
payload before publishing the output atomically.

## Flash

Identify the whole removable disk with `diskutil list`. The command requires a
whole-disk `/dev/diskN` path and an exact confirmation tied to that same path:

```sh
./flash-image.sh \
  --image output/ai-node-installer.dmg \
  --device /dev/disk4 \
  --confirm ERASE:/dev/disk4
```

`flash-image.sh` refuses non-removable or internal devices, checks capacity,
unmounts the whole disk, writes through the raw device, verifies a complete
SHA-256 readback, and ejects it. **The selected removable disk is destroyed.**

## Validate

```sh
./validate.sh
```

Validation checks shell syntax and lint, XML, Go formatting/tests/vetting and
Windows cross-compilation, PowerShell parsing when `pwsh` is available,
configuration rejection cases, safe placeholder rendering, generic naming,
and the destructive-media guard assertions.

## License

MIT. See [`../LICENSE`](../LICENSE).
