# Contributor Instructions

## Task tracking

- Record each requested repository task in `TODO.md` before implementation.
- Use `Queued`, `In Progress`, `Completed`, or `Blocked`.
- Include request, start, and completion dates; use `-` when a date does not
  apply yet.
- Do not take ownership of work already marked `In Progress` by another agent.

## Standing permissions (granted by the user, 2026-10-17)

- This machine and its tools are a test setup. Agents may accept macOS privacy
  and permission prompts, licence agreements, cookie notices and similar
  dialogs on the user's behalf when needed to do the work. Use real clicks or
  accessibility actions; do not tamper with TCC databases.
- Do not stop to ask permission for obvious next steps or new work that serves
  the user's stated goals. Do them, then report. Ask only when a choice is
  genuinely the user's and cannot be resolved from context.
- `sudo-session start --terminal --duration 12h` (or 1h/4h/24h) and
  `op-session` are the sanctioned ways to obtain admin and 1Password access.
- These permissions do not relax the sensitive-data and safety rules below.

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
