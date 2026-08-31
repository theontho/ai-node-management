# Installer Reference

This repository provides two destructive, unattended installer builders. Both
produce credential-bearing media intended to establish a remotely manageable
base operating system, not a complete application environment.

## Shared goals

- Complete setup without locale, keyboard, account, or OOBE interaction.
- Use US English locale and keyboard defaults.
- Configure a declared hostname and dedicated administrator.
- Join a supplied Wi-Fi network and retain DHCP Ethernet support.
- Bring up OpenSSH automatically with a supplied public key.
- Retain a strong local recovery credential in an ignored report.
- Make disk-erasure scope explicit and abort or fall back safely when target
  selection cannot be trusted.
- Keep application accounts, private SSH keys, and workload credentials out of
  installer media.

## Linux

[`linux-autoinstall/`](../linux-autoinstall/) remasters an official Ubuntu
Server 24.04 AMD64 ISO. Configuration names the system disk explicitly and may
name a second data disk. The installer verifies both devices are
non-removable before erasing them.

The installed baseline includes Wi-Fi, DHCP Ethernet, OpenSSH, Avahi, a
dedicated administrator with audited passwordless sudo, configurable swap, and
a physical-console health display. An EFI completion marker prevents a
still-attached installer from reinstalling by default.

See the component README for required inputs, build commands, flashing checks,
and exact destructive behavior.

## Windows

[`windows-autoinstall/`](../windows-autoinstall/) builds Windows 11 Pro x64
media from an official Microsoft ISO. Its WinPE disk selector excludes every
physical disk backing the installer, rejects removable targets, ranks eligible
internal disks, and generates a best-effort wipe plan for secondary internal
disks. If safe automatic selection fails, Windows Setup remains interactive.

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
