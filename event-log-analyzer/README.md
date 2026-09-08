# Windows Event Log Analyzer

[← script-kit home](../README.md) · [All projects](../README.md#projects) · [GTA V profile](../gtaV/)

A configurable PowerShell utility for finding and correlating Windows events. It writes machine-readable event data alongside a concise investigation summary.

## Requirements

- Windows with the Windows Event Log service available
- PowerShell 5.1 or newer
- Administrator access for Security and other restricted logs; the script requests elevation by default

## Quick start

From the `event-log-analyzer` directory, run with PowerShell 7 or Windows PowerShell:

```powershell
.\Analyze-EventLogs.ps1
```

The default `config.json` searches the last seven days of the Application and System logs for critical and error events. It also finds warnings and errors within three minutes of each result. Administrator elevation is requested by default.

Reports are written to `output/<timestamp>/`. Relative output paths are resolved from this project directory, not from the caller's current directory.

## How a run works

1. The script loads `config.json` or the profile supplied with `-ConfigPath`.
2. Explicit command-line parameters override the corresponding profile values for that run.
3. Log, provider, event-ID, severity, and time filters are sent to Windows before records are materialized.
4. Optional text matching is applied to the selected event fields.
5. Warnings and errors near the newest direct results are associated with their nearest result.
6. Structured data, effective settings, coverage information, and a readable summary are written together.

## Configure an investigation

Edit `config.json`, copy it to create another investigation profile, or select another file:

```powershell
.\Analyze-EventLogs.ps1 -ConfigPath .\profiles\game-crashes.json
```

Important settings:

- `search.days`, or `search.since` and `search.until`, controls the time range.
- `search.logNames` accepts exact names or wildcards such as `Microsoft-Windows-WER-*`.
- `search.excludeLogNames` removes noisy logs after wildcard expansion.
- `search.providerNames`, `search.eventIds`, and `search.levels` are applied by Windows while reading each log.
- `search.terms` searches the configured `matchFields`. An empty list matches every event that passes the structured filters.
- `termMatch` can be `Any` or `All`; `useRegex` enables regular-expression terms.
- `maxEventsPerLog` limits each log independently. Zero means unlimited.
- `context` controls nearby-event correlation. Set `enabled` to `false` when it is not useful.
- `context.maxAnchors` limits correlation to the newest direct results so broad searches remain bounded.
- `output.directory` can be absolute or project-relative. `timestampedDirectory` prevents runs from overwriting each other.
- `output.formats` supports `Csv` and `Json`. Summary and run-information files are always written.

Valid level names are `Critical`, `Error`, `Warning`, `Information`, and `Verbose`; numeric values 1 through 5 also work.

## One-off overrides

Command-line values override the selected JSON config without modifying it:

```powershell
# Search all enabled logs for display-driver and timeout events from today.
.\Analyze-EventLogs.ps1 `
  -Days 1 `
  -LogName '*' `
  -Level Critical,Error,Warning `
  -Term 'display driver','timeout'

# Search a precise interval and write directly to another location.
.\Analyze-EventLogs.ps1 `
  -Since '2026-09-08T08:00:00' `
  -Until '2026-09-08T12:00:00' `
  -ProviderName 'Application Error','Windows Error Reporting' `
  -OutputPath 'D:\EventReports' `
  -NoTimestampedOutput

# Avoid the UAC prompt and skip contextual correlation.
.\Analyze-EventLogs.ps1 -SkipElevation -SkipContext
```

Available overrides can be listed with:

```powershell
Get-Help .\Analyze-EventLogs.ps1 -Detailed
```

## Report contents

- `summary.txt`: coverage, counts, grouped findings, and the newest events.
- `events.csv` / `events.json`: every direct result with source metadata and rendered message.
- `context.csv` / `context.json`: nearby events associated with the nearest direct result.
- `run-info.json`: effective configuration, timing, machine information, and skipped-log details.

Event messages may contain sensitive machine, account, application, or path information. Treat generated reports as local diagnostic data.

## Operational notes

- An empty `terms` list does not mean “no results”; it returns every event passing the structured filters.
- Broad `logNames: ["*"]` searches can be expensive. Prefer known logs, severities, providers, IDs, and shorter time ranges when possible.
- PowerShell operational logs can echo command text and match a searcher's own terms. Exclude them for targeted scans when that noise is not useful.
- Empty logs are counted as scanned. Access failures and provider-specific read errors are recorded in `run-info.json` rather than aborting the full investigation.
- Use `-SkipElevation` for intentionally restricted runs and `-SkipContext` when only direct matches matter.

## Related project

The [GTA V Event Investigation](../gtaV/) demonstrates how to build a targeted profile and thin wrapper on top of this analyzer.
