# Windows Node Architecture

## Objective

Create a clean Windows 11 machine with unattended setup, redundant networking,
durable OpenSSH administration, and no requirement for a person to finish OOBE
at the screen.

## Stable baseline

The installer should:

- install the edition matching the machine's license;
- configure hostname, US locale and keyboard, timezone, privacy, and OOBE;
- use DHCP Ethernet and join the supplied Wi-Fi network;
- create a dedicated local administrator and private recovery report;
- authorize a controller SSH public key;
- install and automatically start Microsoft OpenSSH Server;
- use PowerShell as the SSH shell;
- support a real noninteractive administrator-only operation;
- retain Windows Update, Defender, and UAC;
- disable AC sleep and hibernation; and
- restore networking and SSH automatically after reboot.

It should not embed product keys, application credentials, agent frameworks,
development stacks, WSL2, Docker, or Hyper-V. Add those remotely after the
baseline is proven.

## Optional workload layers

| Layer | Use when |
| --- | --- |
| WSL2 | A workload requires Linux userland |
| Docker | Replaceable Linux services benefit from image-based deployment |
| Hyper-V | Testing needs resettable full Windows machines |
| Native Windows runner | Tests need Windows services, registry, desktop, or hardware integration |
| RDP | Exceptional GUI inspection is required |

Docker through WSL2 does not replace native Windows testing. Containers do not
faithfully model OOBE, drivers, desktop UAC, reboot behavior, or complete
installer integration.

## Acceptance criteria

The baseline is complete when unattended setup finishes, the declared hostname
and network configuration are active, key-based SSH works, an SSH PowerShell
session can perform a privileged operation without a console prompt, networking
and SSH recover after reboot, and the retained recovery report matches the
installed account.
