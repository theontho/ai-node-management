# Installer Reference

This repository provides two destructive, unattended installer builders. Both
produce credential-bearing media intended to establish a remotely manageable
base operating system, not a complete application environment.

## Shared goals

- Complete setup without locale, keyboard, account, or OOBE interaction.
- Use US English locale and keyboard defaults.
- Generate a memorable hostname from a declared prefix and configure a
  dedicated administrator.
- Optionally join a supplied Wi-Fi network and retain DHCP Ethernet support.
- Bring up OpenSSH automatically with a supplied public key.
- Retain a strong local recovery credential in an ignored report.
- Make disk-erasure scope explicit and abort or fall back safely when target
  selection cannot be trusted.
- Keep application accounts, private SSH keys, and workload credentials out of
  installer media.

## Linux

[`linux-autoinstall/`](../linux-autoinstall/) remasters an official Ubuntu
Server 24.04 AMD64 ISO. Its default policy safely ranks eligible internal
system disks at boot, while explicit whole-disk overrides remain available.
By default it formats every remaining eligible internal disk as ext4 and
mounts the filesystems persistently at `/data`, `/data2`, `/data3`, and so on.
It can instead leave secondary disks untouched or validate one explicit
data-disk path.

The installed baseline includes Wi-Fi, DHCP Ethernet, OpenSSH, Avahi, a
dedicated administrator with audited passwordless sudo, configurable swap, and
a physical-console health display. Each installation receives a memorable
`prefix-adjective-noun` hostname, and each image build generates a three-word
local-console recovery password while keeping SSH key-only. An EFI completion
marker prevents a still-attached installer from reinstalling by default.

The default Linux storage policy automatically excludes removable, read-only,
USB, FireWire, and installer-backed disks, then ranks remaining internal disks
by preferred capacity and performance. Explicit whole-disk overrides remain
available. Unsafe selection falls back to Subiquity's interactive storage
screen. Host-level Tailscale is installed from a checksum-pinned embedded DEB
and enrolls from a private file after networking starts.

See the component README for required inputs, build commands, flashing checks,
and exact destructive behavior.

## Windows

[`windows-autoinstall/`](../windows-autoinstall/) builds Windows 11 Pro x64
media from an official Microsoft ISO. Its WinPE disk selector excludes every
physical disk backing the installer, rejects removable targets, ranks eligible
internal disks, and generates a preparation plan for secondary internal disks.
Each secondary disk becomes one empty GPT/NTFS data volume with a
persistent `C:\DataDisks\Disk-N` folder mount and, when available, a drive
letter. If safe automatic selection fails, Windows Setup remains interactive.

The installed baseline creates a dedicated local administrator, imports the
Wi-Fi profile, enables Microsoft OpenSSH Server, installs the authorized key,
uses PowerShell as the SSH shell, retains UAC, and enables full remote
administrator tokens for that dedicated account.

The generated local administrator password appears only in credential-bearing
media and the ignored recovery report.

## Private inputs and outputs

Real configuration belongs under each component's ignored `local/` directory.
Downloaded source ISOs, generated images, recovery reports, and test evidence
must remain outside Git.

Before booting either installer:

1. Verify the source ISO checksum from an independent official source.
2. Review the target configuration and disk policy.
3. Disconnect storage that must survive.
4. Protect generated media and reports as credentials.
5. Confirm a physical recovery route remains available.

After installation, verify networking, host-key identity, public-key SSH,
administrator privilege, and reboot persistence before deploying workloads.
