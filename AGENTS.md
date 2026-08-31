# Contributor Instructions

## Task tracking

- Record each requested repository task in `TODO.md` before implementation.
- Use `Queued`, `In Progress`, `Completed`, or `Blocked`.
- Include request, start, and completion dates; use `-` when a date does not
  apply yet.
- Do not take ownership of work already marked `In Progress` by another agent.

## Sensitive and generated data

- Commit examples only. Keep real settings and credentials under `local/`.
- Keep downloaded ISOs and generated images and reports under `local/` or
  `output/`.
- Never add private keys, authentication tokens, passwords, recovery reports,
  generated media, or test evidence containing credentials.
- Treat every generated unattended installer as credential-bearing.

## Safety

- Preserve explicit confirmation and removable-media checks in flash tools.
- Preserve installer-media exclusion and non-removable target checks.
- Do not weaken interactive fallback when safe automatic disk selection fails.
- Keep host provisioning separate from application credentials and workloads.
- Run the narrow component validation after changes, then `./validate.sh`
  before completion.
