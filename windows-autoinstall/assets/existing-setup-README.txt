AI Node setup for an existing Windows installation

This payload does not install Windows, partition disks, or erase data.

1. Open this folder on the target Windows computer.
2. Right-click install-existing.ps1 and select "Run with PowerShell".
3. Approve the single Windows UAC prompt.
4. Check C:\ProgramData\__APP_PREFIX_CMD__\state\remote-ready.txt for completion.

This payload accepts computers whose names begin with
__COMPUTER_NAME_PREFIX_CMD__.

Provisioning installs Microsoft OpenSSH from the bundled, checksum-verified
MSI without waiting for WinGet or Windows Update. It also installs Tailscale
offline, enrolls the computer in unattended mode, and removes the auth key
after successful provisioning. It enables key-only SSH for the configured
local administrator over the LAN and tailnet, uses PowerShell as the SSH shell,
and disables AC sleep and hibernation timeouts. The scheduled task retries
configuration every five minutes until remote access is ready.
