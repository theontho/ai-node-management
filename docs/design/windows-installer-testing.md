# Windows Installer Testing

## Testing model

Use the physical Windows 11 machine as a stable control host. Run destructive
or stateful installer tests inside disposable Hyper-V Windows guests whenever
the behavior does not specifically depend on physical hardware.

```text
Resident AI agent or external controller
                   |
          native Windows test controller
                   |
                 Hyper-V
                   |
       checkpointed Windows test VM
```

Docker is useful for agent runtimes and supporting services, but it is not the
correct isolation boundary for full Windows installer tests.

## Why Hyper-V

A Hyper-V VM has its own:

- complete Windows kernel and operating system;
- registry and services;
- virtual disk and firmware;
- login sessions and desktop;
- reboot lifecycle; and
- virtual networking.

That makes it suitable for testing installation, upgrade, uninstall, service
registration, file associations, shell integration, startup behavior, and
post-reboot validation.

Linux containers cannot model Windows. Windows containers do not provide the
ordinary interactive desktop and full machine lifecycle expected by many
installers.

## CPU and memory behavior

Hyper-V dynamically schedules virtual CPUs across the host's logical
processors. Assigning four virtual CPUs does not normally reserve four
physical cores exclusively.

- An idle VM consumes little CPU.
- An idle host leaves its available CPU time for active VMs.
- A two-vCPU guest can run on at most two logical processors simultaneously.
- A four-vCPU guest can use all four logical processors when the host is idle.
- The host and guest share processor time when both are busy.

For a modest dedicated test host, start conservatively:

- no more than half to three-quarters of host logical CPUs;
- enough guest RAM for the test while retaining host headroom;
- enough host RAM for Windows and caching; and
- explicit WSL2/Docker limits if those layers run at the same time.

One substantial installer VM at a time is a safer default until measurements
show that the host can sustain parallel tests.

## Clean-checkpoint workflow

1. Install a clean, appropriately licensed Windows guest.
2. Apply the desired update baseline and install the guest test runner.
3. Shut the VM down cleanly.
4. Create and retain a named clean-baseline checkpoint.
5. Restore that checkpoint before every test.
6. Start the VM and stage the installer.
7. Run installation and any required reboots.
8. Validate operating-system state and export artifacts.
9. Stop the VM and restore the clean checkpoint.

The host can automate VM lifecycle with Hyper-V PowerShell commands, including
`Checkpoint-VM`, `Restore-VMSnapshot`, and `Start-VM`.

PowerShell Direct can manage a supported Windows guest through the Hyper-V
virtualization channel without depending on guest networking. This is valuable
when a test changes the firewall, network stack, or SSH configuration.

Checkpoints are not backups. Preserve the clean base VM, installation media,
test definitions, and exported results independently.

## Automation hierarchy

Use the least fragile interface available:

1. Documented silent or unattended installer arguments.
2. MSI properties, response files, or deployment APIs.
3. Windows UI Automation control selection.
4. Keyboard navigation and stable accelerators.
5. Screenshot OCR or AI vision.
6. Coordinate-based clicks as a final fallback.

Examples of client technologies include:

- native Microsoft Windows UI Automation APIs;
- `pywinauto` from Python;
- FlaUI from .NET;
- Power Automate Desktop;
- AutoHotkey; and
- screenshot-based computer-use agents.

The installer and the automation client do not need to use the same language.
A Python or .NET test can control a C++, Rust, Delphi, Java, Electron, Inno
Setup, NSIS, MSI, or WiX installer.

Standard Windows controls are generally straightforward to automate. Fully
custom-drawn controls may expose little accessibility metadata and require
vision-based fallback. Open-source installers can be improved by adding stable
automation IDs, accessibility names, machine-readable logs, and deterministic
exit codes.

## Interactive desktop requirements

GUI automation must run in an actual unlocked interactive guest session.
Windows services run in Session 0 and cannot reliably operate desktop windows.
A guest-side scheduled task can start the test runner at login and resume a
persisted test state after reboot.

The test runner must have an integrity level at least as high as the installer.
A lower-integrity process may be blocked from controlling an elevated window.
Ordinary automation cannot click the UAC secure desktop.

Use one of these approaches:

- start the installer from an already-elevated test runner;
- use silent installation when testing deployment rather than consent UX; or
- adjust UAC only in a disposable guest profile when the changed security
  environment is acceptable for that test.

Keep UAC enabled on the persistent host. If the UAC experience itself is under
test, maintain a separate realistic guest profile and treat secure-desktop
interaction as a distinct test problem.

Do not make a test depend on a human keeping an RDP window connected. RDP
disconnect and lock behavior can alter the desktop session. The guest runner
should own its session lifecycle and publish screenshots, logs, and state to
the host.

## Reboot-resumable test state

Installer workflows commonly cross process boundaries and reboots. Store a
small state machine outside the transient GUI process:

```text
prepared
installer-started
reboot-requested
post-reboot-validation
artifacts-exported
completed or failed
```

After guest login, the scheduled runner reads the state and resumes the next
bounded step. Every step should have:

- an explicit timeout;
- expected windows or operating-system conditions;
- a screenshot and UI-tree snapshot on failure;
- process and installer logs;
- a durable result; and
- a clear distinction between failure and successful completion.

## Validate state, not just clicks

A visible "Finished" page is not sufficient. Depending on the product, verify:

- installed files and versions;
- registry keys and uninstall records;
- Windows services and scheduled tasks;
- shortcuts, file associations, and protocol handlers;
- environment variables and PATH changes;
- application launch and basic behavior;
- expected event-log entries;
- reboot persistence;
- repair, upgrade, and uninstall behavior; and
- absence of unexpected residual files or services after uninstall.

## Physical-hardware limitations

Hyper-V is not a complete substitute for physical testing. Use the real host or
a separate sacrificial physical machine for:

- firmware or BIOS changes;
- physical-device and vendor-specific drivers;
- exact GPU behavior;
- hardware dongles or unusual USB devices;
- host bootloader and disk-partition changes;
- installers that intentionally reject virtual machines; and
- performance conclusions that depend on real hardware.

The persistent control host should not be the first target for an unknown
destructive installer. When physical testing is required, preserve an
independent recovery path and collect artifacts before resetting the machine.

## References

- [Microsoft Hyper-V on Windows overview](https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/about/)
- [Microsoft Hyper-V checkpoints](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/checkpoints)
- [Microsoft PowerShell Direct](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/manage/manage-windows-virtual-machines-with-powershell-direct)
- [Microsoft UI Automation overview](https://learn.microsoft.com/en-us/dotnet/framework/ui-automation/ui-automation-overview)
