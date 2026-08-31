# Ubuntu Server USB Autoinstall

This directory builds credential-bearing, unattended Ubuntu Server 24.04 AMD64
installation media for a replaceable remote-management node. It installs a
minimal SSH-accessible host; application workloads remain a separate stage.

The installer:

- erases the explicitly configured non-removable system disk;
- optionally erases and mounts a distinct non-removable data disk;
- installs Ubuntu Server with US English locale and keyboard settings;
- configures the selected IANA timezone, hostname, and administrator account;
- joins the supplied WPA2 Wi-Fi network during installation and future boots;
- enables public-key SSH plus a retained local/SSH recovery password;
- grants the dedicated administrator audited passwordless sudo;
- creates configurable swap with configurable swappiness;
- advertises `<node-name>.local` through Avahi;
- powers down the physical LCD backlight after a configurable idle period and
  restores it on keyboard, touchpad, mouse, or hardware-hotkey activity;
- displays a physical-console-only health banner refreshed every minute; and
- writes an EFI completion marker so a still-attached USB defaults to booting
  the installed system instead of reinstalling it.

## Destructive scope

The builder does not guess Linux installation disks. You must name the exact
kernel device paths in `local/config.env`. At boot, installation aborts unless
each configured disk exists and reports itself as non-removable. This protects
against an absent target being silently replaced by a removable USB, but an
incorrect non-removable path will still destroy the wrong disk.

Disconnect storage that must survive and verify the target's disk names from a
live environment before building media. Device names are not portable between
all machines.

## Configuration

Create ignored local configuration:

```bash
mkdir -p local/private output
cp config.example.env local/config.env
```

Edit `local/config.env`:

```bash
NODE_NAME=ai-node-linux
ADMIN_USER=node-admin
TIMEZONE=Etc/UTC
SYSTEM_DISK=/dev/disk/by-id/system-disk-id
DATA_DISK=/dev/disk/by-id/data-disk-id
DATA_MOUNT=/data
SWAP_SIZE_GIB=16
SWAPPINESS=10
CONSOLE_IDLE_SECONDS=60
```

Set `DATA_DISK=` for a single-disk installation. The config file is trusted
shell syntax, is sourced by the builder, and must not come from an untrusted
download.

The optional data disk is mounted but no service stores data there by default.
Use it for bulk downloads, ISO images, archives, or other capacity-oriented
files. Keep active agent workspaces and application state on the faster system
disk unless local requirements say otherwise.

`CONSOLE_IDLE_SECONDS` accepts 10 through 3600. The backlight daemon directly
controls the first Linux backlight device and listens to input events without
consuming them. It affects only the LCD; the CPU, networking, SSH, containers,
and server workloads remain awake.

Create these ignored files under `local/private/`, each containing one value:

```text
wifi-ssid
wifi-password
ssh-public-key
controller-password
```

The recovery password must contain at least 16 characters. Protect the private
directory with mode `0700` and files with mode `0600`.

## Build

Install Bash, Python 3, OpenSSL, OpenSSH tools, and `xorriso` on the macOS build
host. Download an official Ubuntu Server 24.04 AMD64 ISO and independently
obtain its SHA-256 checksum.

```bash
./build-image.sh \
  --base-iso ./local/ubuntu-server-amd64.iso \
  --base-sha256 OFFICIAL_64_CHARACTER_SHA256 \
  --config ./local/config.env \
  --private-dir ./local/private \
  --output ./output/ai-node-linux.iso \
  --recovery-report ./output/ai-node-linux-recovery.txt
```

The builder verifies the source ISO, validates all configuration and private
inputs, writes outputs atomically with mode `0600`, and extracts the embedded
autoinstall document for byte-for-byte verification.

The ISO and recovery report contain credentials. Never publish either.

## Flash on macOS

Identify the current whole-disk identifier for the intended removable USB:

```bash
diskutil list external physical
sudo ./grant-sudo-one-hour.sh "$(id -un)"
./flash-image.sh \
  --image ./output/ai-node-linux.iso \
  --device /dev/disk14 \
  --confirm ERASE:/dev/disk14
```

The disk number is only an example. The flasher rejects internal and
non-removable devices, verifies every written byte, and ejects the USB.

After installation:

```bash
ssh node-admin@ai-node-linux.local
```

The optional Orca/Tailscale second stage is under [`../orca-node`](../orca-node).
