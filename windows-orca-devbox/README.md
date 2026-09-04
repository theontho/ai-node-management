# Windows Orca devbox

This component turns an existing Windows 11 Pro host into an always-on native
Windows Orca environment and associates it with an Orca desktop.

The deployment installs pinned releases of Orca, Git, Node.js, Python, GitHub
CLI, and Copilot CLI. Orca and all agent-spawned code run as the dedicated
`orca-worker` local account, which does not receive administrator rights.
The existing Windows administrator remains the maintenance boundary.

The runtime starts at boot through Task Scheduler, stores durable state under
`C:\ProgramData\OrcaDevbox`, uses `C:\Orca\workspaces`, and accepts paired
Orca connections on TCP 6768 only from the local subnet.

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

The script creates a random password for the unprivileged runtime account,
stores it only in the ignored recovery report and Windows Task Scheduler,
installs and starts the runtime, retrieves its private pairing code, and adds
the `winbox` environment to the local Orca desktop. It does not transfer
GitHub or coding-agent credentials; authenticate those explicitly inside the
remote environment when needed.

## Validate

```sh
./validate.sh
```
