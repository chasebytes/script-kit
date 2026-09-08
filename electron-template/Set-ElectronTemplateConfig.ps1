[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [ValidatePattern('^[a-z0-9][a-z0-9._-]*$')] [string] $ProjectName,
    [string] $DisplayName,
    [ValidatePattern('^\d+\.\d+\.\d+([+-][0-9A-Za-z.-]+)?$')] [string] $Version,
    [string] $Description,
    [string] $Author,
    [string] $License,
    [ValidateSet('JavaScript', 'TypeScript')] [string] $Language,
    [string] $OutputDirectory,
    [ValidateRange(320, 7680)] [int] $WindowWidth,
    [ValidateRange(240, 4320)] [int] $WindowHeight,
    [string] $ElectronVersion,
    [string[]] $Dependency,
    [string[]] $DevDependency,
    [switch] $ClearDependencies,
    [switch] $ClearDevDependencies,
    [switch] $OpenDevTools,
    [switch] $CloseDevTools,
    [switch] $InstallDependencies,
    [switch] $SkipInstall,
    [switch] $PassThru
)

$modulePath = Join-Path $PSScriptRoot 'ElectronTemplate.psd1'
Import-Module $modulePath -Force
Set-ElectronTemplateConfig @PSBoundParameters
