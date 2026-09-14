#requires -version 5.1

[CmdletBinding()]
param(
    # Perform repairs when corruption is detected. Without this switch, the
    # script only diagnoses and verifies.
    [switch]$Repair,

    # Number of days of System events to inspect.
    [ValidateRange(1, 365)]
    [int]$EventDays = 30,

    # Do not open the completed report in Notepad.
    [switch]$NoOpen
)

$ErrorActionPreference = 'Continue'
$script:CancelRequested = $false
$script:CancellationRecorded = $false
$script:Jobs = [System.Collections.ArrayList]::new()
$script:StartedAt = Get-Date
$script:ReportPath = $null
$script:TemporaryDirectory = $null

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-AsAdministrator {
    $argumentList = [System.Collections.Generic.List[string]]::new()
    $argumentList.Add('-NoProfile')
    $argumentList.Add('-ExecutionPolicy')
    $argumentList.Add('Bypass')
    $argumentList.Add('-File')
    $argumentList.Add(('"{0}"' -f $PSCommandPath))

    if ($Repair) {
        $argumentList.Add('-Repair')
    }

    $argumentList.Add('-EventDays')
    $argumentList.Add($EventDays.ToString())

    if ($NoOpen) {
        $argumentList.Add('-NoOpen')
    }

    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argumentList
}

function Write-ReportLine {
    param([AllowEmptyString()][string]$Text = '')

    if ($script:ReportPath) {
        $Text | Out-File -FilePath $script:ReportPath -Append -Encoding utf8
    }
}

function Write-ReportSection {
    param(
        [Parameter(Mandatory)][string]$Title,
        [AllowEmptyString()][string]$Content
    )

    Write-ReportLine
    Write-ReportLine ('=' * 96)
    Write-ReportLine $Title.ToUpperInvariant()
    Write-ReportLine ('=' * 96)

    if ([string]::IsNullOrWhiteSpace($Content)) {
        Write-ReportLine 'No output was returned.'
    }
    else {
        Write-ReportLine $Content.TrimEnd()
    }
}

function Write-Status {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )

    $elapsed = (Get-Date) - $script:StartedAt
    $prefix = '[{0:hh\:mm\:ss}]' -f $elapsed
    $color = switch ($Level) {
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        default   { 'Cyan' }
    }

    Write-Host "$prefix $Message" -ForegroundColor $color
}

function Stop-ReadOnlyJobs {
    foreach ($task in $script:Jobs) {
        if ($task.Job.State -in @('Running', 'NotStarted')) {
            Stop-Job -Job $task.Job -ErrorAction SilentlyContinue
        }
    }
}

function Request-SafeCancellation {
    param([switch]$ServicingCommandActive)

    if ($script:CancelRequested) {
        return
    }

    $script:CancelRequested = $true
    Stop-ReadOnlyJobs

    if (-not $script:CancellationRecorded) {
        Write-ReportLine
        Write-ReportLine "Cancellation requested at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')."
        $script:CancellationRecorded = $true
    }

    if ($ServicingCommandActive) {
        Write-Status 'Cancellation requested. Waiting for the active Windows servicing command to finish safely...' 'Warning'
    }
    else {
        Write-Status 'Cancellation requested. Stopping remaining read-only checks...' 'Warning'
    }
}

function Test-CancelKey {
    param([switch]$ServicingCommandActive)

    try {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -in @([ConsoleKey]::Q, [ConsoleKey]::Escape)) {
                Request-SafeCancellation -ServicingCommandActive:$ServicingCommandActive
            }
        }
    }
    catch {
        # KeyAvailable can fail in hosts without an interactive console. Ctrl+C
        # remains available, and the report is finalized in the outer finally.
    }

    $script:CancelRequested
}

function Start-DiagnosticJob {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$JobArguments = @()
    )

    $job = Start-Job -Name $Name -ScriptBlock {
        param($Work, $WorkArguments)

        $ErrorActionPreference = 'Continue'
        try {
            $output = & $Work @WorkArguments 2>&1 | Out-String -Width 320
            [pscustomobject]@{
                Succeeded = $true
                Output    = $output
                Error     = $null
            }
        }
        catch {
            [pscustomobject]@{
                Succeeded = $false
                Output    = $null
                Error     = $_.Exception.Message
            }
        }
    } -ArgumentList $ScriptBlock, (, $JobArguments)

    [void]$script:Jobs.Add([pscustomobject]@{
        Name      = $Name
        Job       = $job
        Collected = $false
    })
}

function Receive-DiagnosticJobs {
    param([switch]$Wait)

    do {
        $completed = @($script:Jobs | Where-Object { $_.Job.State -notin @('Running', 'NotStarted') }).Count
        $total = $script:Jobs.Count
        $percent = if ($total -gt 0) { [int](($completed / $total) * 100) } else { 100 }

        Write-Progress -Id 1 `
            -Activity 'Collecting Windows diagnostics' `
            -Status "$completed of $total checks finished - press Q or Esc to cancel" `
            -PercentComplete $percent

        foreach ($task in $script:Jobs | Where-Object { -not $_.Collected -and $_.Job.State -notin @('Running', 'NotStarted') }) {
            $task.Collected = $true

            if ($task.Job.State -eq 'Completed') {
                $result = Receive-Job -Job $task.Job -ErrorAction SilentlyContinue
                if ($result -and $result.Succeeded) {
                    Write-ReportSection -Title $task.Name -Content $result.Output
                    Write-Status "Completed: $($task.Name)" 'Success'
                }
                else {
                    $message = if ($result.Error) { $result.Error } else { 'The check returned no result.' }
                    Write-ReportSection -Title $task.Name -Content "CHECK FAILED: $message"
                    Write-Status "Failed: $($task.Name)" 'Error'
                }
            }
            elseif ($task.Job.State -eq 'Stopped') {
                Write-ReportSection -Title $task.Name -Content 'CANCELLED before completion.'
                Write-Status "Cancelled: $($task.Name)" 'Warning'
            }
            else {
                $reason = $task.Job.ChildJobs[0].JobStateInfo.Reason
                Write-ReportSection -Title $task.Name -Content "CHECK FAILED: $reason"
                Write-Status "Failed: $($task.Name)" 'Error'
            }
        }

        if (-not $Wait -or $completed -eq $total -or $script:CancelRequested) {
            break
        }

        Test-CancelKey | Out-Null
        Start-Sleep -Milliseconds 250
    } while ($true)

    Write-Progress -Id 1 -Activity 'Collecting Windows diagnostics' -Completed
}

function Invoke-NativeCheck {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$ServicingCommand
    )

    if ($script:CancelRequested) {
        Write-ReportSection -Title $Title -Content 'SKIPPED because cancellation was requested.'
        return $null
    }

    $safeName = $Title -replace '[^a-zA-Z0-9.-]', '_'
    $stdoutPath = Join-Path $script:TemporaryDirectory "$safeName.stdout.txt"
    $stderrPath = Join-Path $script:TemporaryDirectory "$safeName.stderr.txt"
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()

    Write-Status "Starting: $Title"

    try {
        $process = Start-Process `
            -FilePath $FilePath `
            -ArgumentList $Arguments `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -NoNewWindow `
            -PassThru

        while (-not $process.HasExited) {
            $status = if ($script:CancelRequested -and $ServicingCommand) {
                'Cancellation pending; allowing Windows servicing to finish safely'
            }
            else {
                'Running; press Q or Esc to cancel safely'
            }

            Write-Progress -Id 2 `
                -Activity $Title `
                -Status "$status - elapsed $($stopwatch.Elapsed.ToString('hh\:mm\:ss'))"

            if (-not $script:CancelRequested) {
                Test-CancelKey -ServicingCommandActive:$ServicingCommand | Out-Null
            }

            Start-Sleep -Milliseconds 350
            $process.Refresh()
        }

        Write-Progress -Id 2 -Activity $Title -Completed
        $stopwatch.Stop()

        $stdout = if (Test-Path $stdoutPath) { Get-Content $stdoutPath -Raw -ErrorAction SilentlyContinue } else { '' }
        $stderr = if (Test-Path $stderrPath) { Get-Content $stderrPath -Raw -ErrorAction SilentlyContinue } else { '' }
        $content = @(
            "Command: $FilePath $($Arguments -join ' ')"
            "Exit code: $($process.ExitCode)"
            "Duration: $($stopwatch.Elapsed.ToString('hh\:mm\:ss'))"
            ''
            $stdout
            $stderr
        ) -join [Environment]::NewLine

        Write-ReportSection -Title $Title -Content $content

        if ($process.ExitCode -eq 0) {
            Write-Status "Completed: $Title ($($stopwatch.Elapsed.ToString('hh\:mm\:ss')))" 'Success'
        }
        else {
            Write-Status "$Title returned exit code $($process.ExitCode). See the report." 'Warning'
        }

        [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output   = "$stdout`n$stderr"
        }
    }
    catch {
        Write-Progress -Id 2 -Activity $Title -Completed
        Write-ReportSection -Title $Title -Content "CHECK FAILED: $($_.Exception.Message)"
        Write-Status "Failed: $Title" 'Error'
        $null
    }
}

if (-not (Test-IsAdministrator)) {
    Write-Host 'Administrator access is required. Opening an elevated terminal...' -ForegroundColor Yellow
    Restart-AsAdministrator
    exit
}

$desktop = [Environment]::GetFolderPath('Desktop')
$timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$script:ReportPath = Join-Path $desktop "Windows-Diagnostic-Report_$timestamp.txt"
$script:TemporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) "WindowsDiagnostic_$timestamp"
[void][IO.Directory]::CreateDirectory($script:TemporaryDirectory)

Write-ReportLine 'WINDOWS COMPREHENSIVE DIAGNOSTIC REPORT'
Write-ReportLine "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
Write-ReportLine "Computer: $env:COMPUTERNAME"
Write-ReportLine "User: $env:USERDOMAIN\$env:USERNAME"
Write-ReportLine "Mode: $(if ($Repair) { 'Diagnostics and repair' } else { 'Diagnostics only' })"
Write-ReportLine "Event history: $EventDays days"

Write-Host
Write-Host 'Windows Diagnostic Report' -ForegroundColor White
Write-Host '-------------------------' -ForegroundColor DarkGray
Write-Host "Mode:   $(if ($Repair) { 'Diagnostics + repair' } else { 'Diagnostics only' })"
Write-Host "Report: $script:ReportPath"
Write-Host 'Cancel: press Q or Esc. Ctrl+C is available for emergency interruption.' -ForegroundColor Yellow
Write-Host

$completedNormally = $false

try {
    Write-Status 'Starting read-only checks in parallel...'

    Start-DiagnosticJob 'System Information' {
        Get-ComputerInfo |
            Select-Object WindowsProductName, WindowsVersion, OsBuildNumber,
                OsArchitecture, CsManufacturer, CsModel, CsSystemType,
                CsProcessors, CsNumberOfLogicalProcessors, CsTotalPhysicalMemory,
                BiosManufacturer, BiosName, BiosVersion, BiosReleaseDate |
            Format-List
    }

    Start-DiagnosticJob 'Problem Devices Reported by Windows' {
        pnputil.exe /enum-devices /problem
    }

    Start-DiagnosticJob 'PowerShell PnP Device Problems' {
        $devices = Get-PnpDevice -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -ne 'OK' -or $_.Problem -ne 'CM_PROB_NONE' }

        if ($devices) {
            $devices | Sort-Object Class, FriendlyName |
                Format-Table Class, FriendlyName, Status, Problem, InstanceId -AutoSize
        }
        else {
            'No PnP device problems were reported.'
        }
    }

    Start-DiagnosticJob 'Signed Driver Inventory' {
        Get-CimInstance Win32_PnPSignedDriver |
            Sort-Object DeviceClass, DeviceName |
            Select-Object DeviceClass, DeviceName, DriverProviderName,
                DriverVersion, DriverDate, IsSigned, InfName |
            Format-Table -AutoSize
    }

    Start-DiagnosticJob 'Storage Health and Reliability' {
        $physicalDisks = Get-PhysicalDisk -ErrorAction SilentlyContinue
        if (-not $physicalDisks) {
            'Physical disk information is unavailable.'
            return
        }

        $physicalDisks |
            Select-Object FriendlyName, MediaType, BusType, HealthStatus,
                OperationalStatus, Size |
            Format-Table -AutoSize

        foreach ($disk in $physicalDisks) {
            "`nReliability counters: $($disk.FriendlyName)"
            try {
                $disk | Get-StorageReliabilityCounter -ErrorAction Stop |
                    Select-Object Temperature, TemperatureMax, ReadErrorsTotal,
                        ReadErrorsUncorrected, WriteErrorsTotal,
                        WriteErrorsUncorrected, Wear, PowerOnHours |
                    Format-List
            }
            catch {
                "Unavailable: $($_.Exception.Message)"
            }
        }
    }

    Start-DiagnosticJob 'Volumes and Free Space' {
        Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' |
            Select-Object DeviceID, VolumeName, FileSystem,
                @{ Name = 'SizeGB'; Expression = { [math]::Round($_.Size / 1GB, 2) } },
                @{ Name = 'FreeGB'; Expression = { [math]::Round($_.FreeSpace / 1GB, 2) } },
                @{ Name = 'FreePercent'; Expression = {
                    if ($_.Size) { [math]::Round(($_.FreeSpace / $_.Size) * 100, 1) }
                } } |
            Format-Table -AutoSize
    }

    Start-DiagnosticJob 'Memory and GPU Information' {
        'PHYSICAL MEMORY'
        Get-CimInstance Win32_PhysicalMemory |
            Select-Object Manufacturer, PartNumber, SerialNumber, Speed,
                ConfiguredClockSpeed,
                @{ Name = 'CapacityGB'; Expression = { [math]::Round($_.Capacity / 1GB, 2) } } |
            Format-Table -AutoSize

        "`nDISPLAY ADAPTERS"
        Get-CimInstance Win32_VideoController |
            Select-Object Name, DriverVersion, DriverDate, VideoProcessor,
                AdapterRAM, Status |
            Format-List

        "`nPREVIOUS WINDOWS MEMORY DIAGNOSTIC RESULTS"
        $events = Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results'
        } -MaxEvents 10 -ErrorAction SilentlyContinue

        if ($events) {
            $events | Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-List
        }
        else {
            'No previous Windows Memory Diagnostic results were found.'
        }
    }

    Start-DiagnosticJob 'Recent Hardware-Related Events' {
        param($Days)

        $providers = @(
            'Microsoft-Windows-WHEA-Logger', 'Disk', 'Ntfs', 'volmgr',
            'stornvme', 'storahci', 'iaStorAC', 'Display', 'Kernel-Power',
            'Microsoft-Windows-DriverFrameworks-UserMode'
        )

        $events = Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            StartTime = (Get-Date).AddDays(-$Days)
        } -ErrorAction SilentlyContinue |
            Where-Object { $_.ProviderName -in $providers } |
            Select-Object -First 300 TimeCreated, Id, ProviderName,
                LevelDisplayName, Message

        if ($events) { $events | Format-List } else { 'No matching events were found.' }
    } -JobArguments @($EventDays)

    Start-DiagnosticJob 'Unexpected Shutdowns and Bug Checks' {
        param($Days)

        Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            StartTime = (Get-Date).AddDays(-$Days)
            Id = 41, 1001, 6008
        } -ErrorAction SilentlyContinue |
            Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message |
            Format-List
    } -JobArguments @($EventDays)

    Start-DiagnosticJob 'Reliability History' {
        $records = Get-CimInstance Win32_ReliabilityRecords -ErrorAction SilentlyContinue |
            Sort-Object TimeGenerated -Descending |
            Select-Object -First 100

        if ($records) {
            $records | Select-Object TimeGenerated, SourceName, ProductName,
                EventIdentifier, Message | Format-List
        }
        else {
            'Reliability history is unavailable.'
        }
    }

    Start-DiagnosticJob 'Network Adapter Status' {
        Get-NetAdapter -ErrorAction SilentlyContinue |
            Select-Object Name, InterfaceDescription, Status, LinkSpeed,
                DriverInformation |
            Format-Table -AutoSize
    }

    Start-DiagnosticJob 'CHKDSK Online Scan' {
        chkdsk.exe C: /scan
    }

    # DISM and SFC intentionally run in order. They both interact with the
    # component store and should not be parallelized with each other.
    $dismResult = Invoke-NativeCheck `
        -Title 'DISM Component Store Scan' `
        -FilePath 'DISM.exe' `
        -Arguments @('/Online', '/Cleanup-Image', '/ScanHealth') `
        -ServicingCommand

    Receive-DiagnosticJobs

    if (-not $script:CancelRequested -and $Repair) {
        $repairableCorruption = $dismResult -and
            $dismResult.Output -notmatch 'No component store corruption detected' -and
            ($dismResult.Output -match 'component store corruption detected' -or
             $dismResult.Output -match 'component store is repairable')

        if ($repairableCorruption) {
            Invoke-NativeCheck `
                -Title 'DISM Component Store Repair' `
                -FilePath 'DISM.exe' `
                -Arguments @('/Online', '/Cleanup-Image', '/RestoreHealth') `
                -ServicingCommand | Out-Null
        }
        else {
            Write-ReportSection `
                -Title 'DISM Component Store Repair' `
                -Content 'SKIPPED because DISM did not report repairable corruption.'
            Write-Status 'DISM repair skipped; no repairable corruption was reported.' 'Success'
        }
    }

    if (-not $script:CancelRequested) {
        $sfcArguments = if ($Repair) { @('/scannow') } else { @('/verifyonly') }
        $sfcTitle = if ($Repair) { 'System File Checker Repair' } else { 'System File Checker Verification' }

        Invoke-NativeCheck `
            -Title $sfcTitle `
            -FilePath 'sfc.exe' `
            -Arguments $sfcArguments `
            -ServicingCommand | Out-Null
    }

    Receive-DiagnosticJobs -Wait
    $completedNormally = -not $script:CancelRequested
}
catch [System.Management.Automation.PipelineStoppedException] {
    Request-SafeCancellation
}
catch {
    Write-ReportSection -Title 'Unexpected Script Error' -Content ($_ | Out-String)
    Write-Status "Unexpected error: $($_.Exception.Message)" 'Error'
}
finally {
    Write-Progress -Id 1 -Activity 'Collecting Windows diagnostics' -Completed
    Write-Progress -Id 2 -Activity 'Windows servicing check' -Completed

    Stop-ReadOnlyJobs
    Receive-DiagnosticJobs

    foreach ($task in $script:Jobs) {
        Remove-Job -Job $task.Job -Force -ErrorAction SilentlyContinue
    }

    if ($script:TemporaryDirectory -and (Test-Path -LiteralPath $script:TemporaryDirectory)) {
        Remove-Item -LiteralPath $script:TemporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    $duration = (Get-Date) - $script:StartedAt
    Write-ReportLine
    Write-ReportLine ('=' * 96)
    Write-ReportLine 'REPORT STATUS'
    Write-ReportLine ('=' * 96)
    Write-ReportLine "Status: $(if ($completedNormally) { 'Completed' } elseif ($script:CancelRequested) { 'Cancelled - partial report' } else { 'Ended with errors - partial report' })"
    Write-ReportLine "Total duration: $($duration.ToString('hh\:mm\:ss'))"
    Write-ReportLine @'

This report contains Windows-reported diagnostics. A clean report cannot fully
exclude intermittent hardware failure. A complete RAM test requires a restart;
run mdsched.exe when you are ready to schedule one.
'@

    Write-Host
    if ($completedNormally) {
        Write-Status 'Diagnostic report completed.' 'Success'
    }
    else {
        Write-Status 'Diagnostic run ended. A partial report was preserved.' 'Warning'
    }

    Write-Host "Report: $script:ReportPath" -ForegroundColor Yellow

    if (-not $NoOpen -and (Test-Path -LiteralPath $script:ReportPath)) {
        Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $script:ReportPath)
    }

    if ($Host.Name -eq 'ConsoleHost') {
        Write-Host
        Read-Host 'Press Enter to close' | Out-Null
    }
}
