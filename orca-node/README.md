# Reproducible Orca and Tailscale Node

This directory defines a one-command Docker Compose appliance for an AMD64
Ubuntu 24.04 node. It keeps the base operating system small and packages the
headless Orca runtime separately from the privileged Tailscale networking
sidecar.

The pinned components are:

- Ubuntu 24.04 OCI base image by digest, with packages frozen to the
  `20260829T000000Z` Ubuntu archive snapshot;
- Orca 1.4.192 from its official `stablyai/orca` AppImage release, verified by
  SHA-256 and extracted at build time for a FUSE-free container; and
- Tailscale 1.102.3 for linux/amd64 by OCI manifest digest.
- Python 3 with `venv` and `pip`, Node.js 22.23.2 with npm, GitHub Copilot CLI
  1.0.82, and GitHub CLI 2.98.0 for agent workspace use.

The Orca and Tailscale containers share one network namespace. Orca is
therefore reachable through the Tailscale node without publishing its port on
the host or LAN. Tailscale is the only container with network capabilities.
Orca drops all Linux capabilities and runs as UID/GID 1000.
The extracted AppImage follows Orca's documented headless-container path,
uses an explicitly managed Xvfb display, and retains Chromium's non-root
sandbox.

## Why the Orca image is built locally

Tailscale publishes and maintains the `tailscale/tailscale` image used by this
appliance. Orca does not currently publish an official OCI image on Docker Hub,
GitHub Container Registry, or its GitHub releases. The official repository
provides a headless Linux guide and Dockerfiles for its own container tests,
but its supported release artifacts are AppImage, Debian, and RPM packages.
Similarly named public Docker Hub images belong to unrelated projects.

This Dockerfile is therefore a small packaging and hardening layer around the
official checksum-pinned Orca AppImage rather than an independent Orca build.
It adds the documented runtime libraries, non-root execution, persistent
encrypted Secret Service storage, and a deterministic health check.

## Persistent state

The default layout separates durable identity from replaceable work:

```text
/srv/orca-node/state/
  orca-home/                 Orca configuration and managed account state
  secrets/orca-keyring-password
  secrets/tailscale-auth-key One-time or scoped Tailscale enrollment key
  tailscale/                 Persistent Tailscale node identity

/srv/orca-node/workspaces/   Replaceable active repositories and worktrees
  scratch/                   Default NVMe-backed Orca scratch project
```

The default layout keeps both durable state and active work under `/srv` on
the system disk. A separately mounted `/data` volume is intentionally unused
by the appliance so operators can use it for bulk downloads, ISO images,
archives, or other capacity-oriented storage. Override either path for hosts
with a different storage layout.

## Tailscale enrollment

Create a preauthorized, preferably single-use Tailscale auth key. If ACL tags
are in use, create it for the intended node tag. Save it locally:

```bash
install -d -m 0700 ./local/private
install -m 0600 /path/to/downloaded-key ./local/private/tailscale-auth-key
```

The key is mounted as a Docker secret and read through
`TS_AUTHKEY=file:/run/secrets/tailscale-auth-key`. `TS_AUTH_ONCE=true` and the
persistent state directory prevent re-enrollment on container restarts.

The deployer generates a separate mode-`0600` Orca keyring password under
`local/private/` when one is not supplied. The container uses it to unlock a
persistent GNOME Secret Service, preventing Orca managed-account credentials
from falling back to plaintext storage.

## Deploy

The target must already provide key-based SSH and passwordless sudo for its
controller account. Either invoke the generic deployer directly:

```bash
./deploy.sh \
  --host node-admin@ai-node-linux.local \
  --node-name ai-node-linux \
  --tailscale-auth-key-file ./local/private/tailscale-auth-key
```

Or keep all node-specific values in ignored local configuration:

```bash
mkdir -p local/private
cp deploy.example.env local/deploy.env
$EDITOR local/deploy.env
./deploy-from-config.sh
```

The deployer verifies its inputs, installs only the pinned Ubuntu Docker Engine
and Compose packages when absent, builds the checksum-verified Orca image,
starts the appliance, waits for both services to become healthy, discovers the
container's tailnet IPv4 address unless `--pairing-address` was supplied,
extracts Orca's pairing code, saves the remote environment in the local Orca
app, checks remote runtime status, and registers an NVMe-backed `scratch`
project for immediate use from desktop or mobile.

After pairing succeeds, the deployer disables new pairing offers and force
recreates only the Orca container. This removes the container log containing
the one-time pairing credential while preserving paired-device state.

## Mobile and Orca Relay

The deployment pairs this Mac's Orca desktop directly to the remote runtime
over Tailscale. It does not sign the server into an Orca cloud account or
enable Orca Relay.

Orca 1.4.192 documents direct mobile pairing for headless servers through
`orca serve --mobile-pairing`. The phone must be on the same tailnet, and the
operator scans or pastes the resulting mobile-scoped pairing offer. Pairing
should then be disabled again so the offer is not retained in container logs.
This appliance does not yet automate that temporary mobile-pairing cycle.

To create a temporary mobile offer on an existing node, set
`ORCA_PAIRING_ENABLED=true` and `ORCA_MOBILE_PAIRING=true` in
`/opt/orca-node/node.env`, recreate only the Orca container, and read the
mobile-scoped offer from its logs. After the phone accepts it, set both values
back to `false` and recreate the Orca container again so the offer disappears
from current container logs.

Relay sign-in is a separate human account flow. The current headless CLI has
commands for managed Claude and Codex accounts, but no command for signing the
host into the Orca cloud account or enabling Relay. Orca's documented Relay
flow uses the desktop app's account/status UI. Therefore this headless
appliance currently supports persistent direct Tailscale access, not
unattended Relay enrollment.

## Lifecycle

The appliance starts at boot through `orca-node.service`. Container logs are
size-limited. To inspect it:

```bash
ssh node-admin@ai-node-linux.local \
  'sudo docker compose --env-file /opt/orca-node/node.env \
    -f /opt/orca-node/compose.yaml ps'
orca status --environment ai-node-linux --json
```

Versions and digests are intentionally committed. Updating means changing the
pins, building and testing the replacement, then rerunning `deploy.sh`.
Rollback means restoring the previous pins and redeploying; persistent state
is outside the images.

The `gh` and `copilot` binaries are installed but do not embed an account or
token. Authenticate them separately with a scoped node identity; never bake
GitHub credentials into the image.

## Comparing agent CLI overhead

`benchmark-agent-clis.py` measures OpenCode, Pi, Copilot CLI, and Moltis under
the same Linux host, model, prompt, fixture repository, and three-run protocol.
It records installed bytes, `--help` startup time and peak process-tree RSS,
plus task wall time, CPU time, peak process-tree RSS, exit status, and an
independent test result. Model and network time remain part of the task wall
time, so use the startup measurements when comparing local CLI overhead.
`install_bytes` covers each isolated install prefix, including Moltis's local
runtime libraries, but not shared runtime caches. In particular, Copilot's
self-update cache under
`~/.cache/copilot` can retain more than one platform payload.

Install each CLI under its own npm prefix and authenticate it before running
the benchmark. Moltis is not an npm CLI: install its pinned portable GNU/Linux
binary as `moltis/moltis` under the benchmark install root and include any
non-system shared libraries under
`moltis/deps/usr/lib/x86_64-linux-gnu`. OpenCode and Pi require their
benchmark-specific auth locations, Moltis requires an OAuth data directory,
and Copilot uses its normal authenticated home:

```bash
python3 benchmark-agent-clis.py \
  --output ./benchmark-results \
  --install-root ~/.local/share/cli-benchmark \
  --opencode-auth-root ./.cli-benchmark-auth \
  --pi-auth-dir ./.pi-benchmark \
  --moltis-data-dir ./.moltis-benchmark/data
```

Set model and reasoning controls explicitly when comparing a non-default model.
For example, to use GitHub Copilot GPT-5.6 Luna at medium reasoning:

```bash
python3 benchmark-agent-clis.py \
  --output ./benchmark-results-luna-medium \
  --opencode-model gpt-5.6-luna \
  --opencode-variant medium \
  --opencode-model-override \
  --pi-model gpt-5.6-luna \
  --pi-thinking medium \
  --copilot-model gpt-5.6-luna \
  --copilot-reasoning-effort medium \
  --moltis-model gpt-5.6-luna \
  --moltis-thinking medium
```

`--opencode-model-override` injects minimal model metadata for a model exposed
by the live provider but not yet present in OpenCode's models.dev catalog. Do
not use it to bypass provider-side model availability checks.

Moltis is measured through its direct `moltis agent --message` one-shot
interface, not as an always-running gateway. For each run, the script creates
an isolated config that restricts native filesystem tools to that disposable
repository, disables interactive approvals and command sandboxing, pins one
provider/model, and disables failover. Any persistent gateway idle RSS must be
measured and reported separately from these terminal-style one-shot runs.

The script never writes credential values to its JSON result or captured
stdout/stderr files. Keep auth directories and benchmark results outside the
repository or in an ignored local directory.
