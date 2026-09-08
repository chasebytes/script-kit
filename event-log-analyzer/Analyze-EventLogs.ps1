<#
.SYNOPSIS
Searches and correlates Windows event logs using a JSON configuration.

.DESCRIPTION
Loads an investigation profile from JSON, applies command-line overrides,
queries Windows Event Log, correlates nearby context, and writes CSV/JSON
reports with a human-readable summary.

.EXAMPLE
.\Analyze-EventLogs.ps1

.EXAMPLE
.\Analyze-EventLogs.ps1 -Days 1 -LogName Application,System -Level Error,Warning -Term crash,timeout
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
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
    [switch] $SkipElevation,
    [Parameter(DontShow)] [switch] $ElevationAttempted
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Setting {
    param([AllowNull()] $Object, [Parameter(Mandatory)] [string] $Name, [AllowNull()] $Default)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Resolve-ProjectPath {
    param([Parameter(Mandatory)] [string] $Path)
    $expandedPath = [Environment]::ExpandEnvironmentVariables($Path)
    if ([IO.Path]::IsPathRooted($expandedPath)) { return [IO.Path]::GetFullPath($expandedPath) }
    return [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $expandedPath))
}

function Get-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ElevatedScript {
    param([Parameter(Mandatory)] [string] $ScriptPath, [Parameter(Mandatory)] [hashtable] $BoundParameters)
    $parameterXml = [Management.Automation.PSSerializer]::Serialize($BoundParameters)
    $parameterData = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($parameterXml))
    $escapedScriptPath = $ScriptPath.Replace("'", "''")
    $elevatedCommand = @"
`$xml = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$parameterData'))
`$parameters = [Management.Automation.PSSerializer]::Deserialize(`$xml)
& '$escapedScriptPath' @parameters -ElevationAttempted
exit `$LASTEXITCODE
"@
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($elevatedCommand))
    $executable = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    return Start-Process -FilePath (Join-Path $PSHOME $executable) -Verb RunAs `
        -ArgumentList '-NoProfile', '-EncodedCommand', $encodedCommand -Wait -PassThru
}

function Resolve-EventLevels {
    param([AllowEmptyCollection()] [object[]] $Values)
    $map = @{ Critical = 1; Error = 2; Warning = 3; Information = 4; Verbose = 5 }
    $resolved = foreach ($value in @($Values)) {
        $text = [string] $value
        $number = 0
        if ([int]::TryParse($text, [ref] $number)) {
            if ($number -notin 1..5) { throw "Invalid event level '$text'. Numeric levels must be 1-5." }
            $number
        }
        elseif ($map.ContainsKey($text)) { $map[$text] }
        else { throw "Invalid event level '$text'. Use Critical, Error, Warning, Information, Verbose, or 1-5." }
    }
    return @($resolved | Select-Object -Unique)
}

function Get-AvailableLogs {
    param([Parameter(Mandatory)] [string[]] $Patterns, [string[]] $ExcludedPatterns = @())
    $logsByName = @{}
    foreach ($pattern in $Patterns) {
        foreach ($log in @(Get-WinEvent -ListLog $pattern -ErrorAction SilentlyContinue)) {
            if ($log.IsEnabled -and $log.RecordCount -gt 0) { $logsByName[$log.LogName] = $log }
        }
    }
    return @($logsByName.Values | Where-Object {
        $candidate = $_.LogName
        -not (@($ExcludedPatterns | Where-Object { $candidate -like $_ }).Count -gt 0)
    } | Sort-Object LogName)
}

function Get-EventMessage {
    param([Parameter(Mandatory)] $EventRecord)
    try { return [string] $EventRecord.Message } catch { return '' }
}

function Get-EventSearchText {
    param(
        [Parameter(Mandatory)] $EventRecord,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Message,
        [Parameter(Mandatory)] [string[]] $Fields
    )
    $parts = foreach ($field in $Fields) {
        switch ($field.ToLowerInvariant()) {
            'message' { $Message }
            'provider' { $EventRecord.ProviderName }
            'logname' { $EventRecord.LogName }
            'id' { [string] $EventRecord.Id }
            'level' { $EventRecord.LevelDisplayName }
            'task' { $EventRecord.TaskDisplayName }
            'opcode' { $EventRecord.OpcodeDisplayName }
            'properties' {
                foreach ($property in $EventRecord.Properties) {
                    if ($null -ne $property.Value) { [string] $property.Value }
                }
            }
            default { throw "Unknown match field '$field'." }
        }
    }
    return @($parts) -join "`n"
}

function ConvertTo-EventResult {
    param(
        [Parameter(Mandatory)] $EventRecord,
        [string] $MatchedTerms = '',
        [string] $Relationship = 'Direct match',
        $Anchor
    )
    [pscustomobject] [ordered] @{
        TimeCreated       = $EventRecord.TimeCreated
        Relationship      = $Relationship
        LogName           = $EventRecord.LogName
        Provider          = $EventRecord.ProviderName
        Id                = $EventRecord.Id
        Level             = $EventRecord.LevelDisplayName
        RecordId          = $EventRecord.RecordId
        ProcessId         = $EventRecord.ProcessId
        ThreadId          = $EventRecord.ThreadId
        MatchedTerms      = $MatchedTerms
        Message           = Get-EventMessage -EventRecord $EventRecord
        AnchorTimeCreated = if ($null -ne $Anchor) { $Anchor.TimeCreated } else { $null }
        AnchorLogName     = if ($null -ne $Anchor) { $Anchor.LogName } else { '' }
        AnchorProvider    = if ($null -ne $Anchor) { $Anchor.Provider } else { '' }
        AnchorId          = if ($null -ne $Anchor) { $Anchor.Id } else { $null }
        AnchorRecordId    = if ($null -ne $Anchor) { $Anchor.RecordId } else { $null }
    }
}

function Export-EventCsv {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $InputObject,
        [Parameter(Mandatory)] [string] $Path
    )
    if ($InputObject.Count -gt 0) {
        $InputObject | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
    }
    else {
        '"TimeCreated","Relationship","LogName","Provider","Id","Level","RecordId","ProcessId","ThreadId","MatchedTerms","Message","AnchorTimeCreated","AnchorLogName","AnchorProvider","AnchorId","AnchorRecordId"' |
            Set-Content -LiteralPath $Path -Encoding UTF8
    }
}

function Format-GroupSummary {
    param([object[]] $Groups)
    if ($Groups.Count -eq 0) { return 'None' }
    return ($Groups | ForEach-Object { '{0,6}  {1}' -f $_.Count, $_.Name }) -join [Environment]::NewLine
}

$resolvedConfigPath = Resolve-ProjectPath -Path $ConfigPath
if (-not (Test-Path -LiteralPath $resolvedConfigPath -PathType Leaf)) { throw "Configuration file not found: $resolvedConfigPath" }
try { $config = Get-Content -LiteralPath $resolvedConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json }
catch { throw "Could not parse configuration file '$resolvedConfigPath': $($_.Exception.Message)" }

$searchConfig = Get-Setting $config 'search' $null
$contextConfig = Get-Setting $config 'context' $null
$outputConfig = Get-Setting $config 'output' $null
$executionConfig = Get-Setting $config 'execution' $null

$requestElevation = [bool] (Get-Setting $executionConfig 'requestElevation' $true)
$isAdministrator = Get-IsAdministrator
if ($requestElevation -and -not $isAdministrator -and -not $SkipElevation) {
    if ($ElevationAttempted) {
        Write-Warning 'The elevated process is still not running as Administrator. Continuing with reduced coverage.'
    }
    else {
        Write-Host 'Administrator access improves event-log coverage. Requesting elevation...'
        try {
            $elevatedParameters = @{}
            foreach ($entry in $PSBoundParameters.GetEnumerator()) { $elevatedParameters[$entry.Key] = $entry.Value }
            $elevatedParameters['ConfigPath'] = $resolvedConfigPath
            $process = Invoke-ElevatedScript -ScriptPath $PSCommandPath -BoundParameters $elevatedParameters
            exit $process.ExitCode
        }
        catch [System.ComponentModel.Win32Exception] {
            Write-Warning 'Elevation was declined or could not be started. Continuing with reduced coverage.'
        }
        catch {
            Write-Warning "Elevation could not be started: $($_.Exception.Message) Continuing with reduced coverage."
        }
    }
}

$effectiveDays = if ($PSBoundParameters.ContainsKey('Days')) { [int] $Days } else { [int] (Get-Setting $searchConfig 'days' 7) }
$configuredSince = Get-Setting $searchConfig 'since' $null
$configuredUntil = Get-Setting $searchConfig 'until' $null
$endTime = if ($PSBoundParameters.ContainsKey('Until')) { [datetime] $Until } elseif ($configuredUntil) { [datetime] $configuredUntil } else { Get-Date }
$startTime = if ($PSBoundParameters.ContainsKey('Since')) { [datetime] $Since } elseif ($configuredSince) { [datetime] $configuredSince } else { $endTime.AddDays(-$effectiveDays) }
if ($startTime -ge $endTime) { throw 'The effective start time must be earlier than the end time.' }

$terms = @(
    @($(if ($PSBoundParameters.ContainsKey('Term')) { $Term } else { Get-Setting $searchConfig 'terms' @() })) |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) } |
        Select-Object -Unique
)
$termMatchMode = if ($PSBoundParameters.ContainsKey('TermMatch')) { $TermMatch } else { [string] (Get-Setting $searchConfig 'termMatch' 'Any') }
$useRegexTerms = if ($UseRegex) { $true } else { [bool] (Get-Setting $searchConfig 'useRegex' $false) }
$caseSensitiveTerms = if ($CaseSensitive) { $true } else { [bool] (Get-Setting $searchConfig 'caseSensitive' $false) }
$matchFields = @((Get-Setting $searchConfig 'matchFields' @('Message', 'Provider', 'LogName', 'Properties')))
$logPatterns = @($(if ($PSBoundParameters.ContainsKey('LogName')) { $LogName } else { Get-Setting $searchConfig 'logNames' @('Application', 'System') }))
$excludedLogPatterns = @($(if ($PSBoundParameters.ContainsKey('ExcludeLogName')) { $ExcludeLogName } else { Get-Setting $searchConfig 'excludeLogNames' @() }))
$providerNames = @($(if ($PSBoundParameters.ContainsKey('ProviderName')) { $ProviderName } else { Get-Setting $searchConfig 'providerNames' @() }))
$eventIds = @($(if ($PSBoundParameters.ContainsKey('EventId')) { $EventId } else { Get-Setting $searchConfig 'eventIds' @() }))
$levelValues = @($(if ($PSBoundParameters.ContainsKey('Level')) { $Level } else { Get-Setting $searchConfig 'levels' @('Critical', 'Error') }))
$levels = @(Resolve-EventLevels -Values $levelValues)
$effectiveMaxEvents = if ($PSBoundParameters.ContainsKey('MaxEventsPerLog')) { [int] $MaxEventsPerLog } else { [int] (Get-Setting $searchConfig 'maxEventsPerLog' 0) }

$contextEnabled = -not $SkipContext -and [bool] (Get-Setting $contextConfig 'enabled' $true)
$effectiveContextMinutes = if ($PSBoundParameters.ContainsKey('ContextMinutes')) { [int] $ContextMinutes } else { [int] (Get-Setting $contextConfig 'minutes' 3) }
$effectiveMaxAnchors = if ($PSBoundParameters.ContainsKey('MaxContextAnchors')) { [int] $MaxContextAnchors } else { [int] (Get-Setting $contextConfig 'maxAnchors' 100) }
$contextLogPatterns = @((Get-Setting $contextConfig 'logNames' @('Application', 'System')))
$contextLevels = @(Resolve-EventLevels -Values @((Get-Setting $contextConfig 'levels' @('Critical', 'Error', 'Warning'))))

$configuredOutput = if ($PSBoundParameters.ContainsKey('OutputPath')) { $OutputPath } else { [string] (Get-Setting $outputConfig 'directory' './output') }
$timestampedOutput = -not $NoTimestampedOutput -and [bool] (Get-Setting $outputConfig 'timestampedDirectory' $true)
$outputFormats = @($(if ($PSBoundParameters.ContainsKey('OutputFormat')) { $OutputFormat } else { Get-Setting $outputConfig 'formats' @('Csv', 'Json') })) |
    ForEach-Object { ([string] $_).ToLowerInvariant() } | Select-Object -Unique
$effectiveSortOrder = if ($PSBoundParameters.ContainsKey('SortOrder')) { $SortOrder } else { [string] (Get-Setting $outputConfig 'sortOrder' 'NewestFirst') }

foreach ($format in $outputFormats) { if ($format -notin @('csv', 'json')) { throw "Unsupported output format '$format'. Use Csv or Json." } }
if ($termMatchMode -notin @('Any', 'All')) { throw "Invalid termMatch '$termMatchMode'. Use Any or All." }
if ($effectiveSortOrder -notin @('NewestFirst', 'OldestFirst')) { throw "Invalid sortOrder '$effectiveSortOrder'." }
if ($logPatterns.Count -eq 0) { throw 'At least one log name or wildcard is required.' }
if ($matchFields.Count -eq 0 -and $terms.Count -gt 0) { throw 'At least one match field is required when terms are configured.' }

$outputRoot = Resolve-ProjectPath -Path $configuredOutput
$reportPath = if ($timestampedOutput) { Join-Path $outputRoot (Get-Date -Format 'yyyyMMdd-HHmmss') } else { $outputRoot }
$null = New-Item -ItemType Directory -Path $reportPath -Force
$reportPath = (Resolve-Path -LiteralPath $reportPath).Path

$regexOptions = [Text.RegularExpressions.RegexOptions]::CultureInvariant -bor [Text.RegularExpressions.RegexOptions]::Compiled
if (-not $caseSensitiveTerms) { $regexOptions = $regexOptions -bor [Text.RegularExpressions.RegexOptions]::IgnoreCase }
$termPatterns = @(
    foreach ($searchTerm in $terms) {
        $patternText = if ($useRegexTerms) { [string] $searchTerm } else { [regex]::Escape([string] $searchTerm) }
        try { [pscustomobject] @{ Term = [string] $searchTerm; Regex = [regex]::new($patternText, $regexOptions) } }
        catch { throw "Invalid search expression '$searchTerm': $($_.Exception.Message)" }
    }
)
$combinedRegex = if ($termPatterns.Count -gt 0) {
    [regex]::new((($termPatterns | ForEach-Object { '(?:' + $_.Regex.ToString() + ')' }) -join '|'), $regexOptions)
} else { $null }

$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$availableLogs = @(Get-AvailableLogs -Patterns $logPatterns -ExcludedPatterns $excludedLogPatterns)
$results = [Collections.Generic.List[object]]::new()
$skippedLogs = [Collections.Generic.List[string]]::new()
$scannedLogs = 0

if (-not $isAdministrator) { Write-Warning 'Running without administrator access; some logs may be inaccessible.' }
Write-Host "Searching $($availableLogs.Count) enabled event log(s) from $startTime through $endTime..."
if ($terms.Count -gt 0) { Write-Host "Terms ($termMatchMode): $($terms -join ', ')" }
else { Write-Host 'Terms: none; returning every event that passes the structured filters.' }

for ($index = 0; $index -lt $availableLogs.Count; $index++) {
    $log = $availableLogs[$index]
    Write-Progress -Activity 'Searching Windows Event Logs' -Status $log.LogName `
        -PercentComplete ([int] (($index / [math]::Max(1, $availableLogs.Count)) * 100))
    try {
        $filter = @{ LogName = $log.LogName; StartTime = $startTime; EndTime = $endTime }
        if ($levels.Count -gt 0) { $filter.Level = $levels }
        if ($providerNames.Count -gt 0) { $filter.ProviderName = $providerNames }
        if ($eventIds.Count -gt 0) { $filter.Id = $eventIds }
        $getParameters = @{ FilterHashtable = $filter; ErrorAction = 'Stop' }
        if ($effectiveMaxEvents -gt 0) { $getParameters.MaxEvents = $effectiveMaxEvents }
        $events = Get-WinEvent @getParameters
        $scannedLogs++

        foreach ($eventRecord in $events) {
            $message = Get-EventMessage -EventRecord $eventRecord
            $hitTerms = @()
            if ($termPatterns.Count -gt 0) {
                $searchText = Get-EventSearchText -EventRecord $eventRecord -Message $message -Fields $matchFields
                if ($termMatchMode -eq 'Any' -and -not $combinedRegex.IsMatch($searchText)) { continue }
                $hitTerms = @($termPatterns | Where-Object { $_.Regex.IsMatch($searchText) } | ForEach-Object Term)
                if ($termMatchMode -eq 'All' -and $hitTerms.Count -ne $termPatterns.Count) { continue }
                if ($termMatchMode -eq 'Any' -and $hitTerms.Count -eq 0) { continue }
            }
            $results.Add((ConvertTo-EventResult -EventRecord $eventRecord -MatchedTerms ($hitTerms -join '; ')))
        }
    }
    catch [System.UnauthorizedAccessException] { $skippedLogs.Add("$($log.LogName) [Access denied]") }
    catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { $scannedLogs++; continue }
        $skippedLogs.Add("$($log.LogName) [$($_.Exception.Message)]")
    }
}
Write-Progress -Activity 'Searching Windows Event Logs' -Completed

$descending = $effectiveSortOrder -eq 'NewestFirst'
$sortedResults = @($results | Sort-Object TimeCreated, LogName, RecordId -Descending:$descending -Unique)
$contextResults = @()
$contextLogs = @()

if ($contextEnabled -and $effectiveContextMinutes -gt 0 -and $sortedResults.Count -gt 0) {
    $anchors = @($sortedResults | Sort-Object TimeCreated -Descending | Select-Object -First $effectiveMaxAnchors | Sort-Object TimeCreated)
    $contextLogs = @(Get-AvailableLogs -Patterns $contextLogPatterns)
    $windowSeconds = $effectiveContextMinutes * 60
    $contextStart = ([datetime] $anchors[0].TimeCreated).AddMinutes(-$effectiveContextMinutes)
    $contextEnd = ([datetime] $anchors[-1].TimeCreated).AddMinutes($effectiveContextMinutes)
    $directKeys = @{}
    foreach ($result in $sortedResults) { $directKeys["$($result.LogName)|$($result.RecordId)"] = $true }
    $contextByKey = @{}

    Write-Host "Correlating context around $($anchors.Count) newest direct result(s)..."
    foreach ($contextLog in $contextLogs) {
        try {
            $candidates = Get-WinEvent -FilterHashtable @{
                LogName = $contextLog.LogName; StartTime = $contextStart; EndTime = $contextEnd; Level = $contextLevels
            } -ErrorAction Stop
            foreach ($candidate in $candidates) {
                $key = "$($candidate.LogName)|$($candidate.RecordId)"
                if ($directKeys.ContainsKey($key)) { continue }

                $nearestAnchor = $null
                $nearestOffset = [double]::PositiveInfinity
                foreach ($anchor in $anchors) {
                    $offset = (([datetime] $candidate.TimeCreated) - ([datetime] $anchor.TimeCreated)).TotalSeconds
                    if ([math]::Abs($offset) -lt [math]::Abs($nearestOffset)) { $nearestAnchor = $anchor; $nearestOffset = $offset }
                }
                if ($null -ne $nearestAnchor -and [math]::Abs($nearestOffset) -le $windowSeconds) {
                    $relationship = "Nearby event ($([math]::Round($nearestOffset, 3)) seconds from direct result)"
                    $contextByKey[$key] = ConvertTo-EventResult -EventRecord $candidate -Relationship $relationship -Anchor $nearestAnchor
                }
            }
        }
        catch {
            if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') {
                $skippedLogs.Add("Context:$($contextLog.LogName) [$($_.Exception.Message)]")
            }
        }
    }
    $contextResults = @($contextByKey.Values | Sort-Object TimeCreated -Descending:$descending)
}

$stopwatch.Stop()
$eventsCsv = Join-Path $reportPath 'events.csv'
$eventsJson = Join-Path $reportPath 'events.json'
$contextCsv = Join-Path $reportPath 'context.csv'
$contextJson = Join-Path $reportPath 'context.json'
$runInfoJson = Join-Path $reportPath 'run-info.json'
$summaryTxt = Join-Path $reportPath 'summary.txt'

if ('csv' -in $outputFormats) {
    Export-EventCsv -InputObject $sortedResults -Path $eventsCsv
    Export-EventCsv -InputObject @($contextResults) -Path $contextCsv
}
if ('json' -in $outputFormats) {
    ConvertTo-Json -InputObject $sortedResults -Depth 5 | Set-Content -LiteralPath $eventsJson -Encoding UTF8
    ConvertTo-Json -InputObject @($contextResults) -Depth 5 | Set-Content -LiteralPath $contextJson -Encoding UTF8
}

$runInfo = [pscustomobject] [ordered] @{
    GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    DurationSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
    ConfigPath = $resolvedConfigPath
    ReportPath = $reportPath
    SearchStart = $startTime.ToString('o')
    SearchEnd = $endTime.ToString('o')
    LogPatterns = $logPatterns
    ExcludedLogPatterns = $excludedLogPatterns
    ProviderNames = $providerNames
    EventIds = $eventIds
    Levels = $levelValues
    Terms = $terms
    TermMatch = $termMatchMode
    UseRegex = $useRegexTerms
    CaseSensitive = $caseSensitiveTerms
    MatchFields = $matchFields
    MaxEventsPerLog = $effectiveMaxEvents
    EnabledLogsFound = $availableLogs.Count
    LogsScanned = $scannedLogs
    SkippedLogs = @($skippedLogs)
    DirectResultCount = $sortedResults.Count
    ContextEnabled = $contextEnabled
    ContextMinutes = $effectiveContextMinutes
    ContextAnchorLimit = $effectiveMaxAnchors
    ContextLogsFound = $contextLogs.Count
    ContextEventCount = $contextResults.Count
    OutputFormats = $outputFormats
    SortOrder = $effectiveSortOrder
    RanAsAdministrator = $isAdministrator
    ComputerName = $env:COMPUTERNAME
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
}
$runInfo | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $runInfoJson -Encoding UTF8

$providerSummary = Format-GroupSummary @($sortedResults | Group-Object Provider | Sort-Object Count -Descending)
$levelSummary = Format-GroupSummary @($sortedResults | Group-Object Level | Sort-Object Count -Descending)
$eventSummary = Format-GroupSummary @($sortedResults | Group-Object Provider, Id | Sort-Object Count -Descending | Select-Object -First 20)
$skippedSummary = if ($skippedLogs.Count -eq 0) { 'None' } else { @($skippedLogs) -join [Environment]::NewLine }
$newestSummary = if ($sortedResults.Count -eq 0) { 'None' } else {
    @($sortedResults | Sort-Object TimeCreated -Descending | Select-Object -First 20 | ForEach-Object {
        $firstLine = if ([string]::IsNullOrWhiteSpace($_.Message)) { '(no rendered message)' } else { ($_.Message -split "`r?`n")[0].Trim() }
        if ($firstLine.Length -gt 140) { $firstLine = $firstLine.Substring(0, 137) + '...' }
        '{0:yyyy-MM-dd HH:mm:ss}  {1,-11}  {2} / {3}  {4}' -f ([datetime] $_.TimeCreated), $_.Level, $_.Provider, $_.Id, $firstLine
    }) -join [Environment]::NewLine
}
$formatFiles = @()
if ('csv' -in $outputFormats) { $formatFiles += 'events.csv, context.csv' }
if ('json' -in $outputFormats) { $formatFiles += 'events.json, context.json' }

@"
Windows Event Log Analysis
==========================
Generated:            $(Get-Date)
Computer:             $env:COMPUTERNAME
Administrator:        $isAdministrator
Duration:             $([math]::Round($stopwatch.Elapsed.TotalSeconds, 3)) seconds
Configuration:        $resolvedConfigPath
Search window:        $startTime through $endTime
Log patterns:         $($logPatterns -join ', ')
Levels:               $($levelValues -join ', ')
Terms:                $(if ($terms.Count -gt 0) { $terms -join ', ' } else { '(none - structured filters only)' })
Enabled logs found:   $($availableLogs.Count)
Logs scanned:         $scannedLogs
Logs skipped/failed:  $($skippedLogs.Count)
Direct results:       $($sortedResults.Count)
Context events:       $($contextResults.Count)

Results by level
----------------
$levelSummary

Results by provider
-------------------
$providerSummary

Top provider/event ID pairs
---------------------------
$eventSummary

Newest direct results
---------------------
$newestSummary

Skipped or failed logs
----------------------
$skippedSummary

Files
-----
$($formatFiles -join [Environment]::NewLine)
run-info.json, summary.txt

Report folder: $reportPath
"@ | Set-Content -LiteralPath $summaryTxt -Encoding UTF8

Write-Host ''
Write-Host "Direct results: $($sortedResults.Count)"
Write-Host "Context events: $($contextResults.Count)"
Write-Host "Duration: $([math]::Round($stopwatch.Elapsed.TotalSeconds, 3)) seconds"
Write-Host "Report folder: $reportPath"
if ($sortedResults.Count -gt 0) {
    $sortedResults | Sort-Object TimeCreated -Descending | Select-Object -First 25 TimeCreated, Level, Provider, Id, MatchedTerms | Format-Table -AutoSize
}
else { Write-Warning 'No events matched the effective filters. Review run-info.json for exact settings and coverage.' }
