# Tooling change log

## 2026-09-08 — consolidated investigation and repair

- Replaced CheckNetwork, CheckBattleye and CheckEvents with Diagnose-Gta and Repair-Gta; retained original files and hashes in ignored output/consolidation-originals.
- Removed implicit firewall changes from diagnostics and removed Desktop, ProgramData and LocalAppData as script-output destinations.
- Reused network probes and game evidence from CheckNetwork and retained the shared event-log profile through IncludeEventScan.
- Added run identity/script hashes, transcripts, incremental operation journal, preview plans, backup manifests, native exit checks and reverse-order restore.
- Added explicit Razer/Armoury utility-service isolation with saved startup/running state; no driver or generic ASUS system-service disabling.
- Changed broad antivirus, shared-cache, permissions, installer, Windows and network repair to explicit switches. Removed blind service deletion and broad recursive permissions changes.
- Retained the existing output Git-ignore rules. No Windows repair or service-disable operations were executed during tooling development.

## 2026-09-08 — authorized Armoury isolation

- Service-only repair/restore plans now require GTA closed but do not require Steam/Rockstar closed; they do not modify launcher files.
- Applied exact-service isolation in output/20260908-185600-301-repair-38afccf1: ArmouryCrateService and ArmouryCrateControlInterface changed from Running/Automatic to Stopped/Disabled. Original settings are journaled for restore.
- Added asus-utils/Uninstall-ArmouryCrate.ps1 and documentation for ASUS's official removal workflow; no uninstall executed.
