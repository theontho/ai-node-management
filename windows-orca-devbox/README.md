# Windows Orca devbox

This component turns an existing Windows 11 Pro host into an always-on native
Windows Orca environment and associates it with an Orca desktop.

The deployment downloads checksum-pinned standalone installers for Orca, Git,
Node.js, Python, and GitHub CLI, then installs a pinned Copilot CLI release.
It does not depend on WinGet or an interactive desktop login. Orca and all
agent-spawned code run as the dedicated `orca-worker` local account. That
account belongs to the local Administrators group, and its boot task runs at
the highest level so Orca terminals can perform administrative work without
an interactive UAC prompt.

The runtime starts at boot through Task Scheduler, stores durable state under
`C:\ProgramData\OrcaDevbox`, uses `C:\Orca\workspaces`, and accepts paired
Orca connections on TCP 6768 only from the local subnet. A separate inbound
rule allows `TCP 8765` from the local subnet and Tailscale
`100.64.0.0/10` range for the Reddit archive progress dashboard.

Because agent-spawned processes inherit administrator access, treat every
command, dependency installer, repository hook, and downloaded script run in
this environment as trusted code. The account is no longer an isolation
boundary from the Windows host.

## Deploy

The Windows baseline must already provide key-only administrator SSH. From the
Mac running Orca:

```sh
./deploy.sh \
  --host mac@winbox.local \
  --pairing-address winbox.local \
  --environment-name winbox \
  --recovery-report local/winbox-recovery.txt
```

The script creates a random password for the administrative runtime account,
stores it only in the ignored recovery report and Windows Task Scheduler,
installs and starts the runtime, retrieves its private pairing code, and adds
the `winbox` environment to the local Orca desktop. It does not transfer
GitHub or coding-agent credentials; authenticate those explicitly inside the
remote environment when needed.

## Upgrade an existing deployment

`elevate-worker.ps1` upgrades an existing `orca-worker` deployment without
reinstalling the toolchain or replacing Orca state. Run it from an elevated
PowerShell session with the current worker password in a temporary file:

```powershell
.\elevate-worker.ps1 -WorkerPasswordFile .\worker-password
```

The script adds the account to the local Administrators group, re-registers
the existing boot task at the highest run level, installs the dashboard
firewall rule, restarts Orca, verifies its listener, and deletes the supplied
password file. The migration terminates existing `orca-worker` processes so
Windows creates a fresh elevated logon token; pause active terminals and jobs
before running it.

## Interactive RDP session

When a Windows operation requires an interactive user session, install FreeRDP
on the Mac with `brew install freerdp`, then connect through Tailscale:

```sh
./connect-rdp.sh \
  --host 100.64.0.10 \
  --domain WIN-EXAMPLE \
  --user mac \
  --credentials-report ../windows-autoinstall/local/win-example.credentials.txt \
  --confirm-tailscale 100.64.0.10
```

The explicit confirmation acknowledges that the helper relies on Tailscale to
authenticate and encrypt the endpoint because Windows uses a self-signed RDP
certificate. The password is read from the mode-`0600` recovery report and
passed through FreeRDP's environment-backed argument channel, not process
arguments. Clipboard redirection is disabled. Keep the RDP session open while
running AppX-dependent commands through SSH.

## Validate

```sh
./validate.sh
```
