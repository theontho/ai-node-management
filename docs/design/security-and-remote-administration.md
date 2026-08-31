# Security and Remote Administration

## Security objective

The nodes are dedicated remote-control machines, so the trusted controller
must be able to administer them. That does not mean every agent subprocess,
downloaded installer, repository hook, or project test should inherit
administrator rights.

The security model separates:

- authenticated maintenance intent;
- normal resident-agent work; and
- untrusted or externally downloaded execution.

## Installer-media sensitivity

An unattended image may contain:

- the configured Wi-Fi password;
- an account recovery password;
- an SSH public key; and
- configuration that grants remote administrative access.

The public key is not secret, but the image as a whole is sensitive. Keep
credential-bearing images and reports:

- outside Git;
- in ignored project-local `local/` or `output/` directories;
- mode `0600` where Unix permissions are available;
- off public artifact stores; and
- under physical control when written to USB media.

Never embed SSH private keys, reusable application tokens, password-manager
sessions, or third-party account credentials. If private media is lost, rotate
the embedded Wi-Fi and account passwords before trusting another installation.

## Connectivity and recovery

Remote administration should have multiple recovery layers:

1. Ethernet through DHCP.
2. Preconfigured Wi-Fi through DHCP.
3. Public-key SSH.
4. A strong retained local-console password.
5. A physical console or recovery boot path for network failures.

The fallback password must not require SSH password authentication. SSH can be
key-only while the password remains available at the physical console.

Host-key checking should remain enabled on the Mac. Record or verify a new
machine's SSH host-key fingerprint during enrollment rather than teaching
automation to ignore host-key mismatches.

## Linux privilege separation

The host maintenance identity may have audited passwordless sudo on a dedicated
AI appliance. Untrusted code should execute as a separate no-sudo worker or
inside a restricted container.

For repeated trusted maintenance, use an audited, automatically expiring sudo
grant rather than repeatedly asking for a password or leaving unrelated
processes permanently privileged.

Do not:

- run downloaded scripts directly under sudo;
- mount the host Docker socket into an untrusted agent;
- share the maintainer's SSH private key with the resident agent; or
- silently treat failed maintenance as success.

Download and inspect or verify artifacts as an unprivileged identity before an
intentional privileged installation step.

## Windows SSH administration

Windows OpenSSH Server reads `%ProgramData%\ssh\sshd_config`. For users in the
local Administrators group, the default administrative key file is:

```text
C:\ProgramData\ssh\administrators_authorized_keys
```

Its permissions must be restricted to `SYSTEM` and `Administrators`. Limit
which account may connect, use public-key authentication, and restrict the
firewall rule to trusted networks where practical.

PowerShell can be configured as the default OpenSSH shell. The completed image
must test a real privileged operation over SSH rather than assuming membership
in `Administrators` guarantees an elevated token.

Microsoft documents that remote connections using a local Security Accounts
Manager administrator can receive a filtered token. The
`LocalAccountTokenFilterPolicy` value can request a full elevated token:

```text
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System
LocalAccountTokenFilterPolicy = 1
```

This setting increases the consequence of stolen local-administrator
credentials. Use it only with a dedicated account, key authentication, strict
firewall exposure, host-key verification, and retained audit logs.

## UAC and headless administration

Keep UAC enabled on the persistent Windows host. Avoiding physical prompts does
not require globally removing UAC; it requires starting remote maintenance in
an already-authorized elevated context.

The remote path should support:

- elevated PowerShell commands;
- services, registry, firewall, and update administration;
- silent MSI or vendor installer modes;
- scheduled tasks configured with the highest run level; and
- a controlled `SYSTEM` service or task for operations that specifically need
  the system identity.

An SSH process cannot click a secure-desktop UAC prompt. If a command starts
unelevated and asks Windows to display consent, the remote design has already
failed. Validate elevation before relying on the machine unattended.

Do not expose a general unauthenticated `SYSTEM` command runner. A maintenance
broker should authenticate requests, restrict or validate its operation set,
protect all executable and input paths from unprivileged writes, log activity,
and return explicit failures.

## Routine and consequential maintenance

Routine host work can remain autonomous:

- security updates under a conservative reboot policy;
- log rotation;
- disk-space monitoring;
- time synchronization;
- service health checks; and
- automatic restart of the active resident workload.

Consequential work should use the external maintenance path:

- changing network or SSH configuration;
- major operating-system upgrades;
- enabling WSL2, Docker, or Hyper-V;
- changing privilege policy;
- replacing the resident agent stack; and
- repairing failed updates or boot behavior.

Before risky remote changes:

1. Preserve the current configuration.
2. Ensure there is a rollback or recovery path.
3. Avoid changing all network access paths at once.
4. Schedule automatic rollback when loss of connectivity is possible.
5. Verify SSH, network, and service health before declaring success.

## References

- [Microsoft OpenSSH Server configuration for Windows](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-server-configuration)
- [Microsoft UAC and remote restrictions](https://learn.microsoft.com/en-us/troubleshoot/windows-server/windows-security/user-account-control-and-remote-restriction)
- [Microsoft Register-ScheduledTask reference](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/register-scheduledtask)
