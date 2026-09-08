# Electron App Template

[← script-kit home](../README.md) · [All projects](../README.md#projects)

A configurable PowerShell module for scaffolding secure Electron applications through either a JavaScript or TypeScript pathway. Both pathways share one configuration model and generation pipeline, so fixes and new options do not drift between implementations.

## Requirements

- PowerShell 5.1 or newer
- A current Node.js LTS release with npm
- Network access when dependency installation is enabled

Electron recommends a current Electron release, the latest Node.js LTS for development, context isolation, renderer sandboxing, and disabled Node integration. Generated apps make those security settings explicit and include a restrictive Content Security Policy.

## Quick start

From the `script-kit` repository root, generate the configured default—JavaScript initially:

```powershell
.\electron-template\Init-Electron-App.ps1 -ProjectName my-app
```

Choose TypeScript for one run:

```powershell
.\electron-template\Init-Electron-App.ps1 `
  -ProjectName my-typed-app `
  -Language TypeScript
```

The earlier `-UseTypescript` spelling remains available as an alias.

By default, the generated project directory is created beneath the current PowerShell working directory. Set `template.outputDirectory` or pass `-OutputDirectory` to place it elsewhere; relative output paths are resolved from the caller's current directory.

## Change defaults from the terminal

`config.json` stores project metadata, the default language, output location, window dimensions, dependencies, Electron version, and install behavior. Use the configuration script instead of editing JSON directly:

```powershell
.\electron-template\Set-ElectronTemplateConfig.ps1 `
  -Language TypeScript `
  -Author 'Your Name' `
  -WindowWidth 1280 `
  -WindowHeight 800
```

Package specifications accept names or versions:

```powershell
.\electron-template\Set-ElectronTemplateConfig.ps1 `
  -ElectronVersion latest `
  -Dependency 'zod@^4.0.0','axios' `
  -DevDependency 'eslint@latest'
```

Other useful switches include `-SkipInstall`, `-InstallDependencies`, `-OpenDevTools`, `-CloseDevTools`, `-ClearDependencies`, and `-ClearDevDependencies`. Add `-PassThru` to display the resulting configuration.

Explicit generation parameters override config values for one run. The configuration editor persists only the values explicitly supplied to it.

Use a separate profile without changing the repository default:

```powershell
Copy-Item .\electron-template\config.json .\desktop-tool.json
.\electron-template\Set-ElectronTemplateConfig.ps1 `
  -ConfigPath .\desktop-tool.json `
  -Language TypeScript `
  -OutputDirectory .\generated

.\electron-template\Init-Electron-App.ps1 `
  -ConfigPath .\desktop-tool.json `
  -ProjectName desktop-tool
```

## One-off generation options

Command-line values override configuration for one app without modifying the profile:

```powershell
.\electron-template\Init-Electron-App.ps1 `
  -ProjectName status-dashboard `
  -Language JavaScript `
  -DisplayName 'Status Dashboard' `
  -Version '1.2.0' `
  -OutputDirectory .\generated `
  -WindowWidth 1200 `
  -WindowHeight 760 `
  -Dependency axios,zod `
  -OpenDevTools
```

Use `-SkipInstall` to generate files without running npm. Existing non-empty project directories are rejected unless `-Force` is explicitly supplied; force mode overwrites generated files but does not delete unrelated files.

## Use as a module

The scripts are thin terminal entry points over `ElectronTemplate.psd1`:

```powershell
Import-Module .\electron-template\ElectronTemplate.psd1

Get-ElectronTemplateConfig
Set-ElectronTemplateConfig -Language TypeScript -SkipInstall
New-ElectronApp -ProjectName my-app -Language TypeScript
```

The module exports `Get-ElectronTemplateConfig`, `Set-ElectronTemplateConfig`, and `New-ElectronApp`.

## Generated projects

Both pathways produce:

- Deterministic `package.json` metadata and scripts
- An isolated preload bridge exposing only runtime version strings
- Explicit `contextIsolation: true`, `nodeIntegration: false`, and `sandbox: true`
- Blocked renderer navigation and new-window creation
- A local-only Content Security Policy
- A responsive starter interface and generated `.gitignore`

The TypeScript pathway additionally creates `src/`, `tsconfig.json`, build/watch scripts, source maps, and `dist/` output.

## npm troubleshooting

The installer locates npm through the active Node.js installation and falls back to Node's bundled npm CLI when a global npm shim is broken. If generation with `-SkipInstall` succeeds but `npm start` does not, repair the machine's Node/npm installation or invoke the bundled npm CLI directly.

For production packaging and distribution, consider adding [Electron Forge](https://www.electronforge.io/) after scaffolding; this kit intentionally stops at a clean development shell.
