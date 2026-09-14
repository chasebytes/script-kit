# GTA V / BattlEye investigation

[Script-kit home](../README.md) · [Shared event analyzer](../event-log-analyzer/)

Two entry points own this workflow:

- `Diagnose-Gta.ps1`: read-only baseline or live-kick capture, including optional shared event-log analysis.
- `Repair-Gta.ps1`: one repair planner/executor and restore entry point. Without `-Apply`, it only writes a plan.

`Investigation.Common.ps1` is an internal helper, not a third workflow. Requires Windows and PowerShell 5.1 or later. Open PowerShell **as Administrator** for full collection and repair. Scripts deliberately do not relaunch under another account: per-user cache paths must refer to the account that plays GTA.

## Output and audit contract

Every run writes to `gtaV/output/<timestamp>-<kind>-<unique-id>/`. No output-path override is offered. This directory is Git-ignored; keep backups until testing and restoration are complete.

- `run.json`: exact supplied switches, identity, elevation, script SHA-256 hashes, start time.
- `transcript.txt`: console messages and errors.
- `journal.jsonl`: timestamped collection results, native arguments/output/exit codes, and a **Started** record before every attempted system change followed by **Completed** or **Failed**. An unmatched Started record means interrupted/unknown, not success.
- `plan.json` (repair): exact targets, saved prior settings, backup destinations, original file hashes, and proposed changes, written before execution.
- `backups/` (repair): quarantined originals. Moves never overwrite destinations. Source links and directories containing Profiles or links are refused.
- `summary.txt`: failure count. Partial evidence must not be treated as a clean bill of health.

Windows components may still maintain their own normal OS logs (for example SFC writes CBS.log). Script-owned reports, DISM's requested log, network reset log, and backups remain here. Reports include sensitive local paths, command lines and network details; inspect them before sharing.

Original scripts were retained locally in `output/consolidation-originals/` with hashes. The repository entry points are replaced, not compatibility wrappers that silently change behavior.

## Capture

```powershell
.\Diagnose-Gta.ps1 -Phase Baseline -IncludeEventScan
# Leave the kick dialog and game open, then capture immediately:
.\Diagnose-Gta.ps1 -Phase PostKick -SkipNetwork -IncludeEventScan
```

The capture records processes and command lines, services including exit codes, drivers, loaded GTA modules, TCP/UDP endpoints, Razer/ASUS scheduled tasks, startup commands, network bindings, filter drivers, boot configuration, Defender detections, effective firewall rules/application/port filters, WFP block events, permissions, hashes/signatures/versions, launch configuration matches and recent game/security events. Transient process/module/endpoint captures precede slow hashing/network probes. Default network tests retain ping, TCP, STUN, UPnP discovery and route observations; these cannot establish reliable GTA session traffic on their own.

`-IncludeEventScan` runs the existing shared analyzer using `event-log-config.json` under the same run directory. Its run-info file documents log coverage. The quick capture covers the previous two hours; the optional full analyzer profile covers 14 days. WFP events require Windows auditing already enabled; this script does not enable it or change firewall logging. Access-denied, unavailable and absent evidence are recorded separately from positive findings. Empty Steam LaunchOptions are normal; matches from other games can appear. Confirm GTA's options in Steam and Rockstar manually.

## Repair

```powershell
.\Repair-Gta.ps1                         # inspect plan.json
.\Repair-Gta.ps1 -Apply                  # rebuild plan from current state, then execute
```

Default scope: quarantine recognized game-root launch/mod artifacts and ASI files, back up named Rockstar Launcher cache directories, add program-scoped inbound/outbound firewall allowances for existing GTA/BattlEye/launcher executables. It preserves Profiles and does not stop processes automatically. Close GTA, Steam, Rockstar Launcher and Social Club before applying or restoring. If RockstarService remains active, stop it through Services and restart it afterward. No broad UDP-only exception is needed: program rules already include UDP 6672 and 61455–61458 and restrict access to those executables.

Optional operations are all in this same repair script:

| Switch | Effect |
| --- | --- |
| `-SkipFirewallRules` | Omit firewall changes. |
| `-IncludeSharedCaches` | Also move shared per-user BattlEye, entitlement/Social Club, Steam web and DirectX/NVIDIA/AMD caches. May sign you out and rebuild shaders; affects other games using those caches. |
| `-AddDefenderExclusions` | Add only missing BattlEye folder exclusions, explicit executable process exclusions and CFA allowances when CFA is enabled. Use when blocking evidence justifies it. |
| `-RepairPermissions` | Save each target directory's SDDL and grant SYSTEM access on that directory only; does not recursively rewrite child ACLs. |
| `-ReinstallBattlEye` | Run the signed game-supplied BEService_x64.exe with `-install`. Does not delete BEService/BEDaisy or their shared installation. No automatic installer rollback. |
| `-ResetNetworkStack` | Run Winsock and IP resets; restart required. No automatic rollback; review saved network configuration first. |
| `-RepairWindows` | DISM RestoreHealth and SFC; native output and exit codes retained. No automatic rollback. |

A combined run can select these switches together. A nonzero native exit stops further changes and is retained for interpretation (including restart-required results). The script does not claim Steam validation completed; use Steam Properties > Installed Files > Verify integrity afterward when appropriate. It does not automatically reset unrelated temporary files, delete services/drivers, reset router settings, or weaken Windows boot protections.

## Razer / Armoury Crate isolation

Presence alone does not establish a conflict. Use a separate isolation run so its result is attributable to a single change. `services.json` identifies exact names, startup modes, executable paths and running state. This machine has Razer Chroma and Game Manager services as well as Armoury Crate services.

```powershell
# Example: test Armoury Crate services as one controlled group.
.\Repair-Gta.ps1 -IsolationOnly -DisableServiceName 'ArmouryCrateService','ArmouryCrateControlInterface'
# Review the plan, then execute the same selection:
.\Repair-Gta.ps1 -IsolationOnly -DisableServiceName 'ArmouryCrateService','ArmouryCrateControlInterface' -Apply
```

For a separate Razer test, select the exact Razer names found in your capture (names containing spaces must be quoted). No vendor is disabled by default. Only explicitly named Razer/Armoury/Aura/Lighting/ROG utility services qualify; wildcards and generic ASUS system services are refused. Original Start, delayed-auto-start value and running state are saved. Services stop without Force, so dependencies cannot be silently stopped. Restart if necessary; quit remaining vendor tray apps, then capture again to verify what remains. This does **not** disable kernel/input drivers, scheduled tasks or startup applications. RGB, macros or hardware-control features can be unavailable during the test. Restore before testing another group.

## Restore

```powershell
.\Repair-Gta.ps1 -RestoreRun '.\output\<repair-run-directory>'
.\Repair-Gta.ps1 -RestoreRun '.\output\<repair-run-directory>' -Apply
```

Restore reads attempted changes (including partially failed ones) in reverse order. It restores service settings/state and ACLs, removes only this run's added rules/exclusions, and moves backups back after hash checks. A regenerated cache or artifact at an original path causes a refusal to overwrite; inspect and preserve it before retrying. Do not edit audit files. Restore native operations are recorded as requiring manual recovery and skipped, allowing reversible actions to continue. Restore does not roll back unrelated subsequent changes; inspect plans first, especially for older runs. Keep the original run directory intact.

## Investigation sequence

1. Capture closed-game baseline, then live kick state. Compare timing and errors, not merely whether BEService is running.
2. Test one vendor service group, restore, then the other. Recapture to confirm residual apps/drivers.
3. If the failure persists, try an independent phone-hotspot connection to separate the PC/session from the home router/ISP path.
4. Use evidence to choose additional repair switches; a broad repair cannot identify which individual change mattered.

See `CHANGELOG.md` for tooling changes. The local investigation findings and validation artifacts are under `output/`.

Reference: [BattlEye FAQ](https://www.battleye.com/support/faq/) documents service installation, permissions, security-software interference and hardware-driver concerns. None establishes Razer or Armoury Crate as the cause on this PC.
