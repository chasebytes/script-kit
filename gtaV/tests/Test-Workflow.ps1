# Safe regression checks: temporary files only, no Windows configuration changes.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\Investigation.Common.ps1"
# Common helper resolves output relative to its own file, not this test folder.
New-InvestigationRun 'tests' @{}
try {
    $tokens=$null; $errors=$null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\Repair-Gta.ps1'),[ref]$tokens,[ref]$errors)
    if ($errors) { throw ($errors | Out-String) }
    foreach ($name in 'Add-Action','Add-Backup','Invoke-Action') {
        $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    $plan = [Collections.Generic.List[object]]::new()
    $fixture = Join-Path $script:RunPath 'fixture.txt'
    'original' | Set-Content $fixture
    Add-Backup $fixture
    $a=$plan[0]
    Invoke-Action $a $false
    if ((Test-Path $fixture) -or -not (Test-Path $a.After)) { throw 'Move failed' }
    Invoke-Action $a $true
    if ((Get-Content $fixture) -ne 'original') { throw 'Restore failed' }
    Invoke-Action $a $false
    'replacement' | Set-Content $fixture
    $blocked=$false
    try { Invoke-Action $a $true } catch { $blocked=$true }
    if (-not $blocked -or (Get-Content $fixture) -ne 'replacement') { throw 'Overwrite guard failed' }
    $other = Join-Path $script:RunPath 'other.txt'
    'before' | Set-Content $other
    Add-Backup $other
    'changed' | Set-Content $other
    $blocked=$false
    try { Invoke-Action $plan[1] $false } catch { $blocked=$true }
    if (-not $blocked) { throw 'Hash guard failed' }
    $profile=Join-Path $script:RunPath 'save-parent\Profiles'
    New-Item -ItemType Directory -Path $profile -Force | Out-Null
    $blocked=$false
    try { Add-Backup (Split-Path $profile -Parent) } catch { $blocked=$true }
    if (-not $blocked) { throw 'Save profile guard failed' }
    Save-Evidence 'intentional-failure' { throw 'regression failure fixture' }
    $records = Get-Content $script:Journal | ForEach-Object { $_ | ConvertFrom-Json }
    if (-not @($records | Where-Object { $_.Action -eq 'intentional-failure' -and $_.Status -eq 'Failed' }).Count) { throw 'Failure was not journaled' }
    # Verify native failures propagate and are recorded; cmd only exits, no file operations.
    $blocked=$false
    try { Invoke-Native cmd.exe @('/d','/c','exit 7') } catch { $blocked=$true }
    if (-not $blocked) { throw 'Native failure was ignored' }
    $records = Get-Content $script:Journal | ForEach-Object { $_ | ConvertFrom-Json }
    if (-not @($records | Where-Object { $_.Status -eq 'Native' -and $_.Detail.ExitCode -eq 7 }).Count) { throw 'Exit code not recorded' }
    Write-Host 'PASS: backup/restore, overwrite refusal, changed-source refusal, save-profile protection, failed collection journal, native exit checks.'
} finally { Complete-InvestigationRun }
