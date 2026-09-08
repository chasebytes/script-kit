<#
.SYNOPSIS
Runs the shared Windows Event Log Analyzer with the GTA V investigation profile.

.DESCRIPTION
This compatibility entry point keeps GTA-specific defaults and output under
gtaV/output while delegating log discovery, elevation, filtering, contextual
correlation, and report generation to event-log-analyzer.

.EXAMPLE
.\CheckEvents.ps1

.EXAMPLE
.\CheckEvents.ps1 -Days 1 -Level Error,Warning

.EXAMPLE
.\CheckEvents.ps1 -Term GTA5_Enhanced,CELib_x64.dll -ContextMinutes 5
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 3650)] [Nullable[int]] $Days,
    [Nullable[datetime]] $Since,
    [Nullable[datetime]] $Until,
    [AllowEmptyCollection()] [string[]] $Term,
    [ValidateSet('Any', 'All')] [string] $TermMatch,
    [string[]] $LogName,
    [string[]] $ExcludeLogName,
    [string[]] $ProviderName,
    [int[]] $EventId,
    [string[]] $Level,
    [ValidateRange(0, 1000000)] [Nullable[int]] $MaxEventsPerLog,
    [ValidateRange(0, 1440)] [Nullable[int]] $ContextMinutes,
    [ValidateRange(1, 10000)] [Nullable[int]] $MaxContextAnchors,
    [string] $OutputPath,
    [ValidateSet('Csv', 'Json')] [string[]] $OutputFormat,
    [ValidateSet('NewestFirst', 'OldestFirst')] [string] $SortOrder,
    [switch] $UseRegex,
    [switch] $CaseSensitive,
    [switch] $SkipContext,
    [switch] $NoTimestampedOutput,
    [switch] $SkipElevation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$analyzerPath = Join-Path $PSScriptRoot '..\event-log-analyzer\Analyze-EventLogs.ps1'
$profilePath = Join-Path $PSScriptRoot 'event-log-config.json'

if (-not (Test-Path -LiteralPath $analyzerPath -PathType Leaf)) {
    throw "Shared event-log analyzer not found: $analyzerPath"
}
if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
    throw "GTA V event-log profile not found: $profilePath"
}

$analyzerParameters = @{
    ConfigPath = (Resolve-Path -LiteralPath $profilePath).Path
}

foreach ($entry in $PSBoundParameters.GetEnumerator()) {
    $analyzerParameters[$entry.Key] = $entry.Value
}

if (-not $analyzerParameters.ContainsKey('OutputPath')) {
    $analyzerParameters.OutputPath = Join-Path $PSScriptRoot 'output'
}

& (Resolve-Path -LiteralPath $analyzerPath).Path @analyzerParameters
