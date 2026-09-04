AI Node setup for an existing Windows installation

This payload does not install Windows, partition disks, or erase data.

1. Open this folder on the target Windows computer.
2. Right-click install-existing.ps1 and select "Run with PowerShell".
3. Approve the single Windows UAC prompt.
4. Check C:\ProgramData\__APP_PREFIX_CMD__\state\remote-ready.txt for completion.

Provisioning installs Microsoft OpenSSH with WinGet, enables key-only SSH for
the configured local administrator, limits the firewall rule to the local
subnet, uses PowerShell as the SSH shell, and disables AC sleep and hibernation
timeouts. The scheduled task retries configuration every five minutes until
SSH is ready.
