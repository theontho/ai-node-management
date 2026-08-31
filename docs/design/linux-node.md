# Linux Node Architecture

## Objective

Maintain a stable Linux host that remains remotely recoverable while
replaceable workloads evolve independently.

```text
External services
       |
Linux host -- resident workload containers
       ^
       |
SSH maintenance
```

The host owns Wi-Fi and Ethernet, SSH identity, firewall policy, updates,
storage, clock synchronization, service supervision, logs, and local recovery.
The workload owns application runtimes, dependencies, ordinary project
execution, and service-specific configuration.

## Docker Compose

Docker Compose is a practical one-node workload layer. It provides reproducible
deployment and rollback without pretending to provision host networking,
kernel, boot, disks, or recovery.

Persist state in explicit host directories or named volumes. Bound memory,
CPU, health-check frequency, and log retention according to host capacity.
Long-running work must use a persistent supervisor rather than an interactive
SSH session.

The resident workload should run without host sudo and without the Docker
socket. Docker socket access is effectively root access to the host.

## Identities

| Identity | Authority |
| --- | --- |
| Host maintainer | Intentional operating-system maintenance through audited sudo |
| Resident workload | Normal service operation without host sudo |
| Project worker | Downloaded code, builds, hooks, and tests without sudo or standing credentials |

For trusted repeated maintenance, a logged, time-bounded sudo grant is safer
than elevating every workload. Run untrusted code in a no-sudo identity or a
restricted container.

The [`orca-node`](../../orca-node/) appliance applies these boundaries with a
Tailscale sidecar, non-root Orca container, dropped capabilities, persistent
state, and boot-time service supervision.
