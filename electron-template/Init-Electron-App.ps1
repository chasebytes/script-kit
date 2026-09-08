<#
.SYNOPSIS
Creates a JavaScript or TypeScript Electron application from config and overrides.
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [ValidatePattern('^[a-z0-9][a-z0-9._-]*$')] [string] $ProjectName,
    [ValidateSet('JavaScript', 'TypeScript')] [string] $Language,
    [Alias('UseTypescript')] [switch] $TypeScript,
    [string] $DisplayName,
    [string] $Author,
    [string] $Version,
    [string] $Description,
    [string] $License,
    [string] $OutputDirectory,
    [ValidateRange(320, 7680)] [int] $WindowWidth,
    [ValidateRange(240, 4320)] [int] $WindowHeight,
    [string] $ElectronVersion,
    [Alias('ExtraDependencies')] [string[]] $Dependency,
    [string[]] $DevDependency,
    [switch] $OpenDevTools,
    [switch] $SkipInstall,
    [switch] $Force
)

if ($TypeScript -and $PSBoundParameters.ContainsKey('Language') -and $Language -ne 'TypeScript') {
    throw '-TypeScript cannot be combined with a different -Language value.'
}

$parameters = @{}
foreach ($entry in $PSBoundParameters.GetEnumerator()) {
    if ($entry.Key -notin @('TypeScript', 'Dependency', 'DevDependency')) { $parameters[$entry.Key] = $entry.Value }
}
if ($TypeScript) { $parameters.Language = 'TypeScript' }
if ($PSBoundParameters.ContainsKey('Dependency')) { $parameters.ExtraDependencies = $Dependency }
if ($PSBoundParameters.ContainsKey('DevDependency')) { $parameters.ExtraDevDependencies = $DevDependency }

Import-Module (Join-Path $PSScriptRoot 'ElectronTemplate.psd1') -Force
New-ElectronApp @parameters
