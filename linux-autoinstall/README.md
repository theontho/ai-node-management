# Ubuntu Server USB Autoinstall

This directory builds credential-bearing, unattended Ubuntu Server 24.04 AMD64
installation media for a replaceable remote-management node. It installs a
minimal SSH- and Tailscale-accessible host; application workloads remain a
separate stage.

The installer:

- safely selects an internal system disk or validates an explicit whole-disk
  path, excluding the installer and removable media;
- erases, formats, and persistently mounts every remaining eligible
  internal disk as empty data storage;
- installs Ubuntu Server with US English locale and keyboard settings;
- generates a memorable `prefix-adjective-noun` hostname for each installation;
- configures the selected IANA timezone and administrator account;
- optionally joins an embedded WPA2 Wi-Fi network while retaining DHCP
  Ethernet support;
- enables key-only SSH plus a retained local-console recovery password;
- installs a checksum-pinned Tailscale package and enrolls the host without a
  desktop login;
- grants the dedicated administrator audited passwordless sudo;
- creates configurable swap with configurable swappiness;
- advertises `<node-name>.local` through Avahi;
- powers down the physical LCD backlight after a configurable idle period and
  restores it on keyboard, touchpad, mouse, or hardware-hotkey activity;
- displays a physical-console-only health banner refreshed every minute; and
- writes an EFI completion marker and suppresses the live-media removal prompt
  so a still-attached USB reboots into the installed system instead of pausing
  or reinstalling.

## Destructive scope

With `SYSTEM_DISK=auto`, the installer inventories whole disks at boot,
identifies and excludes every disk backing `/cdrom`, and rejects removable,
read-only, USB, and FireWire targets. It first prefers the highest-performance
internal disk meeting `PREFERRED_MIN_TARGET_DISK_BYTES`; if none meets that
preference, it selects the largest eligible disk. NVMe and UFS rank above
SATA/SAS, generic SCSI or virtual disks, and eMMC/SD storage.
The system target must also provide at least 16 GB for the operating system
plus the configured swap allocation; undersized targets trigger the
interactive fallback before erasure.

Set `SYSTEM_DISK` to an explicit whole-disk `/dev` path to override performance
ranking. Explicit targets must still be non-removable, writable, and distinct
from the installer media. An explicitly named non-removable USB disk is
allowed, while automatic selection never chooses USB.

Every eligible disk remaining after system-disk selection is always erased,
given one ext4 filesystem, and mounted persistently through Curtin-generated
`fstab` entries. Mount paths are `DATA_MOUNT`, `DATA_MOUNT2`, `DATA_MOUNT3`,
and so on; with the default they are `/data`, `/data2`, `/data3`, and so on.
Ordering is deterministic by Linux device path. There is no preservation or
single-secondary-disk mode. Existing partitions, filesystems, encryption,
labels, and installed operating systems do not affect eligibility.

Secondary-disk selection uses the same strict safety filter as automatic
system-disk selection. Unsafe disks are skipped rather than erased. If safe
system-disk selection cannot be completed, the generated storage plan is
discarded and Subiquity opens its interactive storage screen instead of
guessing.

Disconnect storage that must survive. Automatic ranking reduces
hardware-specific configuration, but any eligible internal disk selected by
the configured policy can be erased.

## Configuration

Create ignored local configuration:

```bash
mkdir -p local/private output
cp config.example.env local/config.env
```

Edit `local/config.env`:

```bash
NODE_NAME_PREFIX=lin
ADMIN_USER=node-admin
TIMEZONE=Etc/UTC
SYSTEM_DISK=auto
DATA_MOUNT=/data
PREFERRED_MIN_TARGET_DISK_BYTES=60000000000
SWAP_SIZE_GIB=16
SWAPPINESS=10
CONSOLE_IDLE_SECONDS=60
```

Configuration uses strict `KEY=value` syntax. The parser rejects unknown,
duplicate, missing, malformed, or whitespace-padded settings and never
executes the file as shell code.

No service stores data on the secondary mounts by default. Use them for bulk
downloads, ISO images, archives, or other capacity-oriented files. Keep active
agent workspaces and application state on the faster system disk unless local
requirements say otherwise.

`CONSOLE_IDLE_SECONDS` accepts 10 through 3600. The backlight daemon directly
controls the first Linux backlight device and listens to input events without
consuming them. It affects only the LCD; the CPU, networking, SSH, containers,
and server workloads remain awake. On hardware without a kernel backlight
device, systemd skips the service without treating that as a failure.

`SWAP_SIZE_GIB` accepts 1 through 1024. Its value contributes to the hard
minimum system-disk capacity check.

`NODE_NAME_PREFIX` accepts a lowercase DNS label of at most 21 characters.
Each installation independently selects an adjective and noun, so one image
can provision multiple nodes with names such as `lin-lunar-maple`.

Create these required ignored files under `local/private/`, each containing one
value:

```text
ssh-public-key
tailscale-auth-key
```

For automatic Wi-Fi, also create both `wifi-ssid` and `wifi-password`; omit
both for Ethernet-only setup. A lone Wi-Fi file is rejected. The Wi-Fi profile
remains on the installed host for future boots.

Use a pre-approved, preferably tagged Tailscale auth key. One-off keys are best
for a single installation; reusable keys permit one image to provision
multiple machines but make control of the installer media especially
important. The key is read through Tailscale's `file:` support and deleted from
the installed host only after `BackendState` reports `Running`. It necessarily
remains embedded in the installer image.
The enrollment service retries after network or daemon failures and leaves the
key on the host until enrollment is confirmed.

The builder generates the recovery password from three independently selected
words in EFF's Long Wordlist plus four digits, for example
`Velvet-River-Compass-4821`. This provides about 52 bits of randomness while
remaining practical to type at the physical console. SSH password
authentication remains disabled. The unmodified EFF wordlist is redistributed
under EFF's [CC BY 4.0 policy](https://www.eff.org/copyright). Protect the
private directory with mode `0700` and files with mode `0600`.

## Build

Install Bash, Python 3, OpenSSL, OpenSSH tools, `ar`, `tar`, and `xorriso` on
the macOS build host. Download an official Ubuntu Server 24.04 AMD64 ISO and
the official Tailscale AMD64 DEB, then independently obtain both SHA-256
checksums. The builder also verifies the package name and architecture from the
DEB control metadata.

```bash
generation=$(date -u +%Y%m%dT%H%M%SZ)
./build-image.sh \
  --base-iso ./local/ubuntu-server-amd64.iso \
  --base-sha256 OFFICIAL_64_CHARACTER_SHA256 \
  --config ./local/config.env \
  --private-dir ./local/private \
  --tailscale-deb ./local/tailscale_VERSION_amd64.deb \
  --tailscale-sha256 OFFICIAL_TAILSCALE_64_CHARACTER_SHA256 \
  --output "./output/ai-node-linux-$generation.iso" \
  --recovery-report "./output/ai-node-linux-$generation-recovery.txt"
```

The builder verifies the source ISO and Tailscale package checksums, validates
all configuration and private inputs, writes outputs atomically with mode
`0600`, and extracts the embedded autoinstall documents and Tailscale inputs
for byte-for-byte verification. The recovery report records the generated
password, hostname pattern, SSH key fingerprint, storage policies, network
mode, package checksum, and media checksum.
The builder atomically refuses to overwrite an existing recovery report.
Use a distinct generation value for every rebuilt stick so older recovery
credentials and their corresponding image checksums remain available.

The ISO and recovery report contain credentials. Never publish either.

## Flash on macOS

Identify the current whole-disk identifier for the intended removable USB:

```bash
diskutil list external physical
sudo ./grant-sudo-one-hour.sh "$(id -un)"
./flash-image.sh \
  --image ./output/ai-node-linux.iso \
  --device /dev/disk14 \
  --confirm ERASE:/dev/disk14
```

The disk number is only an example. The flasher rejects internal and
non-removable devices and verifies every written byte. It deliberately leaves
the USB attached; eject it separately only when development and verification
are complete.

After installation:

```bash
ssh node-admin@lin-ADJECTIVE-NOUN.local
```

Use the hostname shown on the physical console or discover the node through
mDNS or the Tailscale admin console before replacing the pattern above.

The optional Orca stage remains under [`../orca-node`](../orca-node). Its
container uses the host's Tailscale identity and binds Orca only to that
tailnet address; it does not contain a Tailscale sidecar, key, state, or TUN
device.
