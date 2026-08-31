# Remotely Managed Node Design

These documents capture reusable architecture and security rationale for
turning replaceable computers into unattended, privately managed nodes.

## Layers

1. **Stable host:** Networking, SSH, updates, firewall, storage, recovery, and
   service supervision.
2. **Replaceable workload:** Containers, agent runtimes, language tools, and
   project execution.
3. **External maintenance:** Separately authenticated administration over SSH
   for host changes and repair.

Normal project code and downloaded scripts should not inherit host
administrator authority. Credentials, workspaces, and recovery paths should
survive workload replacement without being baked into workload images.

## Documents

- [Linux node architecture](linux-node.md)
- [Windows node architecture](windows-node.md)
- [Security and remote administration](security-and-remote-administration.md)
- [Secrets and account authentication](secrets-and-account-authentication.md)
- [Windows installer testing](windows-installer-testing.md)
- [Cross-platform installer reference](../installer-reference.md)

Component READMEs are authoritative for build and flashing commands.
Credential-bearing images and recovery reports must stay outside version
control.
