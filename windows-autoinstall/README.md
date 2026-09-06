# Windows 11 unattended USB builder

This MIT-licensed project builds a bootable Windows 11 Pro installer image on
macOS. It configures a unique hostname, local administrator, Wi-Fi, key-only
OpenSSH, and NLA-protected Remote Desktop without committing machine settings
or secrets.

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
| `COMPUTER_NAME_PREFIX` | Prefix used for `prefix-adjective-noun` hostnames (1–3 characters) |
| `ADMIN_USERNAME` | Local administrator and allowed SSH username |
| `TIME_ZONE` | Windows time-zone identifier, such as `UTC` |
| `PREFERRED_MIN_TARGET_DISK_BYTES` | Preferred minimum internal target size |
| `APP_PREFIX` | Safe internal ProgramData, task, mutex, and firewall prefix |

The committed example uses generic `win`, `ai-admin`, `UTC`,
`60000000000`, and `AiNode` defaults. The entire `local/` directory is ignored.

Download the x64 MSI from a trusted
[Win32-OpenSSH release](https://github.com/PowerShell/Win32-OpenSSH/releases)
into `local/`, and independently verify its published SHA-256 digest. The MSI
is embedded in the private output so SSH installation never waits for WinGet
or Windows Update.

The currently tested package is `OpenSSH-Win64-v10.0.0.0.msi` from release
`10.0.0.0p2-Preview`, with SHA-256
`ddec9c53864280759cf9f74791cefd387100e3946aa849a1c138a4ed1b96b7d9`.

Also download the official x64
[Tailscale MSI](https://pkgs.tailscale.com/stable/#windows) and verify its
published SHA-256 digest. The currently tested package is
`tailscale-setup-1.102.3-amd64.msi`, with SHA-256
`03ac8183c6e3ce276e9b44281ebe7e4c02aef28a971034ca170c4b665df42dce`.

Create the required SSH public-key file under `local/private/`:

- `ssh-public-key` — one valid OpenSSH public key
- `tailscale-auth-key` — one reusable, pre-approved, preferably tagged auth key

For automatic Wi-Fi, also create both `wifi-ssid` and `wifi-password`; omit
both for Ethernet-only setup. A lone Wi-Fi file is rejected. Do not place
private keys there. Any Wi-Fi profile and the public key are embedded in
generated media, then removed from the installed host after provisioning. The
Tailscale key is passed through its private file rather than exposed in process
logging, then deleted after enrollment. The generated recovery report contains
the random local administrator password. Both the image and report are
credential-bearing private artifacts.

Administrator passwords use three independently selected words from EFF's
[Long Wordlist](https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt)
plus four digits, for example `Velvet-River-Compass-4821`. This remains easy to
type while providing about 52 bits of randomness. The unmodified EFF wordlist
is redistributed under EFF's
[CC BY 4.0 policy](https://www.eff.org/copyright).

## Build

First calculate and independently verify the official ISO's SHA-256 digest,
then run:

```sh
./build-image.sh \
  --base-iso local/Windows11.iso \
  --base-sha256 YOUR_VERIFIED_64_HEX_DIGEST \
  --config local/config.env \
  --private-dir local/private \
  --openssh-msi local/OpenSSH-Win64-v10.0.0.0.msi \
  --openssh-sha256 YOUR_VERIFIED_OPENSSH_64_HEX_DIGEST \
  --tailscale-msi local/tailscale-setup-1.102.3-amd64.msi \
  --tailscale-sha256 YOUR_VERIFIED_TAILSCALE_64_HEX_DIGEST \
  --output output/ai-node-installer.dmg
```

Alternatively, use a mounted, trusted official Windows installer as the source
without modifying it:

```sh
./build-image.sh \
  --base-dir /Volumes/WINDOWS_INSTALLER \
  --config local/config.env \
  --private-dir local/private \
  --openssh-msi local/OpenSSH-Win64-v10.0.0.0.msi \
  --openssh-sha256 YOUR_VERIFIED_OPENSSH_64_HEX_DIGEST \
  --tailscale-msi local/tailscale-setup-1.102.3-amd64.msi \
  --tailscale-sha256 YOUR_VERIFIED_TAILSCALE_64_HEX_DIGEST \
  --output output/ai-node-installer.dmg
```

Optional flags are `--recovery-report FILE` and `--image-size-gb INTEGER`
(minimum 10 GiB; default 12). The builder verifies the source ISO checksum,
uses an MBR/FAT32 layout for broad UEFI compatibility, splits oversized WIM
files, updates WinPE, mounts the result read-only, and verifies its layout and
payload before publishing the output atomically. Each installation randomly
selects a short adjective and noun during WinPE, producing memorable names such
as `win-brisk-otter` while staying within Windows' 15-character limit. One USB
can therefore provision multiple nodes without a baked-in computer name.
OpenSSH and Tailscale install from the media; Tailscale enrolls in unattended
mode under that same generated hostname. Provisioning does not require a
desktop login. It also leaves the standard Windows Update policy enabled, so
Windows resumes its normal automatic security, quality, Defender, and driver
updates after networking becomes available. SSH and RDP firewall rules accept
only the local subnet and Tailscale address ranges; RDP requires normal Windows
credentials and Network Level Authentication.

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

## Configure an existing Windows installation

If Windows is already installed, create a non-destructive post-install payload
instead of building or booting installer media:

```sh
./build-existing-setup.sh \
  --config local/config.env \
  --ssh-public-key-file local/private/ssh-public-key \
  --openssh-msi local/OpenSSH-Win64-v10.0.0.0.msi \
  --openssh-sha256 YOUR_VERIFIED_OPENSSH_64_HEX_DIGEST \
  --tailscale-msi local/tailscale-setup-1.102.3-amd64.msi \
  --tailscale-sha256 YOUR_VERIFIED_TAILSCALE_64_HEX_DIGEST \
  --tailscale-auth-key-file local/private/tailscale-auth-key \
  --output-dir /Volumes/YOUR_USB/ai-node-setup
```

The output directory must not already exist. The builder does not format,
erase, or otherwise modify the destination volume outside that new directory.
On the configured Windows host, right-click `install-existing.ps1`, select
**Run with PowerShell**, and approve one UAC prompt. The script verifies the
payload, confirms the computer-name prefix and administrator account, installs
Microsoft OpenSSH from the bundled MSI when needed, copies the provisioning
files under `C:\ProgramData`, installs and enrolls Tailscale, and starts the
same retrying system task used by the unattended installer. It does not install
Windows, contact Windows Update, or alter disk partitions.

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
