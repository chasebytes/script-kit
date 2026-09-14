#requires -Version 5.1
# Internal helpers shared by the two entry points; no actions on import.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Test-Administrator {
    $p = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function New-InvestigationRun([string]$Kind, $Parameters) {
    $script:InitialError = if ($Error.Count) { $Error[0] } else { $null }
    $root = Join-Path $PSScriptRoot 'output'
    $script:RunPath = Join-Path $root ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + $Kind + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $script:RunPath -Force | Out-Null
    $script:Journal = Join-Path $script:RunPath 'journal.jsonl'
    $script:Failures = 0
    @{ StartedUtc = [datetime]::UtcNow.ToString('o'); Kind = $Kind; Parameters = $Parameters; Elevated = (Test-Administrator); User = [Environment]::UserName; Computer = $env:COMPUTERNAME; PowerShell = $PSVersionTable.PSVersion.ToString(); Scripts = @(Get-ChildItem $PSScriptRoot -File | Where-Object Extension -in '.ps1','.psm1','.json' | Get-FileHash | Select-Object Path,Hash) } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:RunPath 'run.json') -Encoding UTF8
    Start-Transcript -Path (Join-Path $script:RunPath 'transcript.txt') | Out-Null
    Write-Host "Output: $script:RunPath"
}
function Write-Audit([string]$Status, [string]$Action, $Detail) {
    @{ TimeUtc = [datetime]::UtcNow.ToString('o'); Status = $Status; Action = $Action; Detail = $Detail } | ConvertTo-Json -Depth 12 -Compress | Add-Content -LiteralPath $script:Journal -Encoding UTF8
}
function Save-Evidence([string]$Name, [scriptblock]$Collect) {
    Write-Audit Started $Name $null
    try {
        $priorError = if ($Error.Count) { $Error[0] } else { $null }
        $data = @(& $Collect)
        if ($Error.Count -and $Error[0] -ne $priorError) { throw "Collection emitted an error: $($Error[0])" }
        ConvertTo-Json -InputObject $data -Depth 12 | Set-Content -LiteralPath (Join-Path $script:RunPath "$Name.json") -Encoding UTF8
        Write-Audit Completed $Name @{ Count = $data.Count }
    } catch { $script:Failures++; Write-Audit Failed $Name $_.Exception.Message; Write-Warning "$Name : $_" }
}
function Invoke-Native([string]$File, [string[]]$Arguments) {
    $result = & $File @Arguments 2>&1
    $code = $LASTEXITCODE
    Write-Audit Native $File @{ Arguments = $Arguments; ExitCode = $code; Output = ($result | Out-String) }
    $result
    if ($code -ne 0) { throw "$File exited with $code. See journal." }
}
function Complete-InvestigationRun {
    $runErrors = @(
        foreach ($record in $Error) {
            if ($record -eq $script:InitialError) { break }
            [pscustomobject]@{ Message=$record.Exception.Message; Id=$record.FullyQualifiedErrorId; Position=$record.InvocationInfo.PositionMessage; Category=[string]$record.CategoryInfo }
        }
    )
    ConvertTo-Json -InputObject $runErrors -Depth 5 | Set-Content -LiteralPath (Join-Path $script:RunPath 'errors.json') -Encoding UTF8
    Write-Audit Finished Run @{ Failures = $script:Failures }
    "Completed with $script:Failures failed operations/collections. Read journal.jsonl before interpreting missing evidence. No collection proves the absence of a conflict." | Set-Content (Join-Path $script:RunPath 'summary.txt')
    Stop-Transcript | Out-Null
}



