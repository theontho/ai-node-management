# AI Node Management

Build reproducible, credential-bearing USB installers for remotely managed
Linux and Windows nodes, then optionally deploy Orca through the Linux host's
Tailscale identity.

## Components

| Directory | Purpose |
| --- | --- |
| [`linux-autoinstall/`](linux-autoinstall/) | Unattended Ubuntu Server 24.04 AMD64 installer with optional Wi-Fi, host Tailscale, SSH, recovery access, safe automatic disk selection, persistent secondary data volumes, and a console health display |
| [`windows-autoinstall/`](windows-autoinstall/) | Unattended Windows 11 Pro x64 installer with safe disk selection, persistent secondary data volumes, Wi-Fi, OpenSSH, and remote administrator provisioning |
| [`windows-orca-devbox/`](windows-orca-devbox/) | Existing Windows host deployment for an associated, administrative Orca runtime and native development toolchain |
| [`orca-node/`](orca-node/) | Docker Compose appliance publishing Orca only on the Linux host's Tailscale IPv4, plus a discovery-only coding-agent benchmark suite |
| [`system-inventory/`](system-inventory/) | Cross-platform, credential-safe hardware, storage, network, service, and agent-tool inventory dashboard generator |
| [`docs/`](docs/) | Architecture, security boundaries, and cross-platform installer guidance |

Each component keeps machine-specific configuration under an ignored
`local/` directory and generated artifacts under ignored `output/`. Start
with its committed example configuration and README.

## Security

Generated installers contain credentials and may erase disks without
interactive confirmation. Keep images and recovery reports private, review
their target-selection policies before booting, and never place private keys
or long-lived application credentials in installer media.

The Linux and Windows base installers establish networking, recovery, and SSH
only. Application credentials and replaceable workloads belong in a later
deployment stage.

## Validation

Run all static and rendering checks from the repository root:

```bash
./validate.sh
```

Some platform-specific image builds require macOS and separately downloaded
official operating-system ISOs. Validation does not require those private or
large inputs.

## License

[MIT](LICENSE)
