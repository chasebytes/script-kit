# script-kit

A collection of focused utilities, diagnostic tools, and project scaffolds. Each project has its own entry point and usage guide; shared foundations are linked explicitly where one tool builds on another.

## Projects

| Project | What it does | Entry point |
| --- | --- | --- |
| [Windows Event Log Analyzer](./event-log-analyzer/) | Configurable Windows event-log search, contextual correlation, and CSV/JSON reporting. | [`Analyze-EventLogs.ps1`](./event-log-analyzer/Analyze-EventLogs.ps1) |
| [GTA V Event Investigation](./gtaV/) | A GTA V, Rockstar, Social Club, and BattlEye investigation profile built on the shared event-log analyzer. | [`CheckEvents.ps1`](./gtaV/CheckEvents.ps1) |
| [Electron App Template](./electron-template/) | Configurable PowerShell module for secure JavaScript or TypeScript Electron apps, with terminal-managed profiles. | [`Init-Electron-App.ps1`](./electron-template/Init-Electron-App.ps1) |
| [MSI Laptop Utilities](./msi-laptop-utils/) | Validates MSI recovery-media split image files with DISM before attempting recovery. | [`Check-MSIRecovery.ps1`](./msi-laptop-utils/Check-MSIRecovery.ps1) |

## Getting started

Clone or download the repository, open PowerShell at its root, and choose a project above. Each project page documents its requirements, configuration, examples, and generated output.

```powershell
cd .\event-log-analyzer
.\Analyze-EventLogs.ps1
```

Generated diagnostic reports and scaffolded applications may contain machine-specific data. Review each project's README before committing generated files.

## Repository conventions

- Configuration intended to be shared is kept beside its project and committed.
- Generated reports, dependencies, build products, crash dumps, and local environment files are excluded by the root [`.gitignore`](./.gitignore).
- Event-log reports remain local because they can contain usernames, paths, process details, and other machine-specific information.
- Scripts validate their immediate inputs, but destructive recovery operations and production packaging remain outside this kit's scope.

## Requirements

The repository is Windows-oriented and primarily uses PowerShell. Individual projects may additionally require administrator access, DISM, Node.js, npm, or network access; check the relevant project page before running it.

## License

See [LICENSE](./LICENSE).
