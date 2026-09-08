# GTA V Event Investigation

[← script-kit home](../README.md) · [All projects](../README.md#projects) · [Event Log Analyzer](../event-log-analyzer/)

`CheckEvents.ps1` is a GTA-specific entry point for the shared [`event-log-analyzer`](../event-log-analyzer/) project.

## Requirements

- Windows and PowerShell 5.1 or newer
- The sibling `event-log-analyzer` project in its repository location
- Administrator access for the broadest log coverage; elevation is requested automatically

## Quick start

From the `gtaV` directory, run it normally:

```powershell
.\CheckEvents.ps1
```

The defaults live in [`event-log-config.json`](./event-log-config.json). They search the previous 14 days across all enabled logs for Rockstar, GTA V, Social Club, and BattlEye terms. PowerShell logs are excluded because they can echo the scanner's own terms. Critical, error, warning, informational, and verbose matches are all eligible; nearby critical, error, and warning events are collected as context.

Reports remain under `gtaV/output/<timestamp>/`. The wrapper passes options to the shared analyzer, so elevation, filtering, context correlation, and output formatting have one implementation.

## Narrow an investigation

Any commonly changed setting can be overridden for one run:

```powershell
.\CheckEvents.ps1 -Days 1 -Level Error,Warning
.\CheckEvents.ps1 -Since '2026-09-08T08:00:00' -Term GTA5_Enhanced,CELib_x64.dll
.\CheckEvents.ps1 -LogName Application,System -ContextMinutes 5
```

## Reports and investigation workflow

The reports now use the shared analyzer names: `events.csv`, `events.json`, `context.csv`, `context.json`, `run-info.json`, and `summary.txt`.

Useful workflow:

1. Reproduce the launcher, game, or BattlEye problem.
2. Run the scanner with a short `-Days` value or precise `-Since` time.
3. Start with `summary.txt`, then inspect direct records in `events.csv` and their anchored neighbors in `context.csv`.
4. Check `run-info.json` before drawing conclusions; it records effective filters, elevation, coverage, and skipped logs.

Use `-SkipElevation` only when reduced coverage is acceptable. Use `-SkipContext` to speed up a direct-match-only run. Generated reports can reveal local paths, account names, process activity, and application details, so they are ignored by Git and should be shared carefully.

For the complete configuration schema and generic command-line options, see the [Windows Event Log Analyzer documentation](../event-log-analyzer/).
