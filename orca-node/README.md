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

The portable benchmark compares OpenCode, Pi, Copilot CLI, Moltis, Hermes,
Crush, and OpenClaw. Every client receives a fresh Git repository and the same
composite Python and JavaScript task containing six independent repairs. All
subtasks run in one agent invocation, so repeated CLI startup does not dominate
the approximately 30-second target workload.

The harness records installed size, startup wall time and RSS, task wall and
CPU time, peak process-tree RSS, timeout state, and independent pass/fail
grading. Visible tests, hidden checks, protected-file comparisons, and an
allowed-change list prevent agents from passing by editing tests or unrelated
files. Model and network latency remain part of task wall time.

### Available clients

The benchmark does not install, update, or authenticate agent CLIs. It first
looks for the existing isolated layout under
`BENCHMARK_INSTALL_ROOT` (default `~/.local/share/cli-benchmark`), then falls
back to executables already on `PATH`. Missing clients are reported as
`SKIPPED`. Installed clients without authentication or access to the selected
model run normally and are reported as `FAILED`.

The default suite currently requests these GitHub Copilot clients:

| Benchmark name | Executable | Model |
|---|---|---|
| `opencode` | `opencode` | `github-copilot/gpt-5.6-luna` |
| `pi` | `pi` | `github-copilot/gpt-5.6-luna` |
| `copilot` | `copilot` | `github-copilot/gpt-5.6-luna` |
| `moltis` | `moltis` | `github-copilot/gpt-5.6-luna@reasoning-medium` |
| `hermes` | `hermes` | `copilot/gpt-5.6-luna` |
| `crush` | `crush` | `copilot/gpt-5.6-luna` |
| `openclaw` | `openclaw` | `github-copilot/gpt-5.6-luna` |

The harness also supports `codex` with `gpt-5.4` and `claude` with `sonnet`.
They are opt-in because they use their native OpenAI and Anthropic providers
rather than the same GitHub Copilot model.

Install and authenticate only the clients you want to compare, following each
project's own instructions. Then copy the path-only configuration example
into the ignored `local/` directory and adjust it to existing authentication
locations on the current host:

```bash
mkdir -p local
cp benchmark.example.env local/benchmark.env
$EDITOR local/benchmark.env
```

Do not copy credentials between machines. Authenticate independently on each
host so credentials stay in that host's protected client state. Authentication
paths may be left unchanged for missing clients; they are only used if that
client is available.

### Run

```bash
./run-agent-cli-benchmark-serial.sh local/benchmark.env
```

The runner pins GPT-5.6 Luna with medium reasoning, performs one composite
task per available client with no warm-up, and rotates clients deterministically
when more tasks or repetitions are selected directly through the Python
harness. Set `BENCHMARK_AGENTS` in the configuration file to request a subset,
such as:

```bash
BENCHMARK_AGENTS="pi copilot moltis"
```

Results are printed and written to
`output/agent-cli-benchmark/benchmark-report.md`; raw measurements are in
`output/agent-cli-benchmark/results.json`. Both remain ignored by Git.

The runner allows only one suite per user at a time and gives every suite a
unique process marker. On startup it removes escaped children belonging to a
previous crashed run, creates fresh fixture repositories, and cleans temporary
OpenCode and Hermes credential copies on exit. Persistent authentication state
is never included in result JSON or captured task output. Hermes receives a
fresh runtime database for every suite to prevent session reuse across
benchmark workspaces.

Moltis 20260831.01 is invoked through its supported Agent Client Protocol
stdio interface because its direct `moltis agent --message` path does not
execute a functional coding turn. The generated per-run Moltis configuration
restricts filesystem access to the disposable fixture, disables interactive
approvals and failover, and pins the exact provider model.
