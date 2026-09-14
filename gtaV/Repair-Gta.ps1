#requires -Version 5.1
<#
.SYNOPSIS
Build an audited repair plan; -Apply executes it. -RestoreRun restores reversible actions.
#>
[CmdletBinding()]
param(
    [string]$GamePath = 'C:\Program Files (x86)\Steam\steamapps\common\Grand Theft Auto V Enhanced',
    [switch]$Apply,
    [switch]$SkipFirewallRules,
    [switch]$AddDefenderExclusions,
    [switch]$RepairPermissions,
    [switch]$ReinstallBattlEye,
    [switch]$ResetNetworkStack,
    [switch]$RepairWindows,
    [switch]$IncludeSharedCaches,
    [string[]]$DisableServiceName = @(),
    [switch]$IsolationOnly,
    [string]$RestoreRun
)
. "$PSScriptRoot\Investigation.Common.ps1"
New-InvestigationRun 'repair' $PSBoundParameters
$plan = [Collections.Generic.List[object]]::new()
function Add-Action($Kind, $Target, $Before, $After) {
    $plan.Add([pscustomobject]@{ Id=[guid]::NewGuid().ToString('N'); Kind=$Kind; Target=$Target; Before=$Before; After=$After })
}
function Add-Backup([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing linked backup source: $Path" }
    if ($item.PSIsContainer) {
        if (@(Get-ChildItem -LiteralPath $item.FullName -Force -Recurse | Where-Object { $_.Name -eq 'Profiles' -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) }).Count) { throw "Backup contains save profiles or links: $Path" }
    }
    $destination = Join-Path $script:RunPath ('backups\' + [guid]::NewGuid().ToString('N') + '-' + $item.Name)
    $inventory = @(
        if ($item.PSIsContainer) { Get-ChildItem -LiteralPath $item.FullName -File -Recurse -Force | Get-FileHash -Algorithm SHA256 | Select-Object Path,Hash }
        else { Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256 | Select-Object Path,Hash }
    )
    Add-Action Move $item.FullName $inventory $destination
}
function Invoke-Action($a, [bool]$Undo) {
    switch ($a.Kind) {
        Move {
            $source = if ($Undo) { $a.After } else { $a.Target }
            $destination = if ($Undo) { $a.Target } else { $a.After }
            if (Test-Path -LiteralPath $destination) { throw "Destination exists; refusing overwrite: $destination" }
            $resolved = (Resolve-Path -LiteralPath $source).Path
            if ($resolved -ne [IO.Path]::GetFullPath($source)) { throw "Unexpected source resolution: $source" }
            if ((Get-Item -LiteralPath $source -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked source: $source" }
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            foreach ($f in @($a.Before)) {
                $relative = $f.Path.Substring($a.Target.Length).TrimStart('\')
                $checkPath = if ($relative) { Join-Path $source $relative } else { $source }
                if ((Get-FileHash -LiteralPath $checkPath -Algorithm SHA256).Hash -ne $f.Hash) { throw "Backup/source changed since planning: $checkPath" }
            }
            Move-Item -LiteralPath $resolved -Destination $destination
        }
        Service {
            $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$($a.Target)"
            if ($Undo) {
                $mode = switch ([int]$a.Before.Start) { 2 {'Automatic'} 3 {'Manual'} 4 {'Disabled'} default { throw 'Unsupported service startup value' } }
                Set-Service -Name $a.Target -StartupType $mode
                if ($null -ne $a.Before.DelayedAutoStart) { Set-ItemProperty -LiteralPath $regPath -Name DelayedAutoStart -Value ([int]$a.Before.DelayedAutoStart) }
                if ($a.Before.State -eq 'Running') { Start-Service -Name $a.Target } else { Stop-Service -Name $a.Target -ErrorAction Stop }
            } else {
                # No Force: do not stop dependent services implicitly.
                Set-Service -Name $a.Target -StartupType Disabled
                Stop-Service -Name $a.Target -ErrorAction Stop
                if ((Get-Service $a.Target).Status -ne 'Stopped') { throw 'Service did not stop' }
            }
        }
        Firewall {
            if ($Undo) { Remove-NetFirewallRule -Name $a.After.Name } else {
                New-NetFirewallRule -Name $a.After.Name -DisplayName $a.After.Name -Program $a.Target -Direction $a.After.Direction -Action Allow -Profile Any | Out-Null
            }
        }
        Defender {
            $args = @{}; $args[$a.After.Property] = $a.Target
            if ($Undo) { Remove-MpPreference @args } else { Add-MpPreference @args }
        }
        Acl {
            if ($Undo) { $acl=Get-Acl -LiteralPath $a.Target; $acl.SetSecurityDescriptorSddlForm($a.Before); Set-Acl -LiteralPath $a.Target -AclObject $acl }
            else { Invoke-Native icacls.exe @($a.Target,'/grant','*S-1-5-18:F') }
        }
        Native {
            if ($Undo) { throw 'System repair has no automatic rollback; consult native output and Windows recovery.' }
            Invoke-Native $a.Target @($a.After)
        }
        default { throw "Unknown action kind: $($a.Kind)" }
    }
}
try {
    if ($Apply -and -not (Test-Administrator)) { throw 'Open PowerShell as Administrator and rerun the same command. No system changes made.' }
    if ($RestoreRun) {
        $restorePath = (Resolve-Path -LiteralPath $RestoreRun).Path
        $outputRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'output')) + '\'
        if (-not $restorePath.StartsWith($outputRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'RestoreRun must be a run directory under gtaV/output.' }
        $previous = @(Get-Content -LiteralPath (Join-Path $restorePath 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
        # Started records cover interrupted/partially failed actions as well as successful ones.
        $actions = @($previous | Where-Object { $_.Status -eq 'Started' -and $_.Action -eq 'Change' } | ForEach-Object Detail)
        [array]::Reverse($actions)
        foreach ($a in $actions) {
            if ($a.Kind -eq 'Native') { Write-Audit ManualRecovery 'Restore' $a; continue }
            if ($a.Kind -eq 'Move' -and -not (Test-Path -LiteralPath $a.After)) { continue }
            if ($a.Kind -eq 'Firewall' -and -not (Get-NetFirewallRule -Name $a.After.Name -ErrorAction SilentlyContinue)) { continue }
            $plan.Add($a)
        }
    } else {
        if (-not (Test-Path -LiteralPath $GamePath -PathType Container)) { throw "Game directory missing: $GamePath" }
        $GamePath = (Resolve-Path -LiteralPath $GamePath).Path
        foreach ($name in $DisableServiceName) {
            if ($name -match '[*?\[\]]') { throw 'Use exact service names, not wildcards.' }
            $s = Get-CimInstance Win32_Service | Where-Object Name -eq $name
            if (-not $s -or ($s.Name + $s.DisplayName + $s.PathName) -notmatch 'Razer|Armoury|Aura|LightingService|ROG Live') { throw "Not a discovered Razer/ASUS utility service: $name" }
            $r = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
            $delayed = if ($r.PSObject.Properties['DelayedAutoStart']) { $r.DelayedAutoStart } else { $null }
            Add-Action Service $name @{Start=$r.Start; DelayedAutoStart=$delayed; State=$s.State; PathName=$s.PathName} 'Disabled'
        }
        if ($IsolationOnly -and $DisableServiceName.Count -eq 0) { throw 'IsolationOnly requires exact DisableServiceName values from diagnostics.' }
        if (-not $IsolationOnly) {
            $artifacts = @('commandline.txt','dinput8.dll','ScriptHookV.dll','OpenIV.asi','version.dll','dxgi.dll','d3d9.dll','dsound.dll','winmm.dll','winhttp.dll','ReShade.ini','SpecialK.ini','mods','scripts','plugins','reshade-shaders','lml')
            $artifacts += @(Get-ChildItem -LiteralPath $GamePath -Filter '*.asi' -File | Select-Object -ExpandProperty Name)
            foreach ($name in $artifacts | Sort-Object -Unique) { Add-Backup (Join-Path $GamePath $name) }
            foreach ($base in @($env:LOCALAPPDATA,$env:APPDATA,$env:ProgramData)) {
                foreach ($relative in @('Rockstar Games\Launcher\webcache','Rockstar Games\Launcher\cache','Rockstar Games\Launcher\GPUCache')) { Add-Backup (Join-Path $base $relative) }
            }
            if ($IncludeSharedCaches) {
                foreach ($relative in @('BattlEye','DigitalEntitlements','Rockstar Games\Social Club','Steam\htmlcache','D3DSCache','NVIDIA\DXCache','NVIDIA\GLCache','AMD\DxCache')) { Add-Backup (Join-Path $env:LOCALAPPDATA $relative) }
                foreach ($relative in @('config\htmlcache','appcache\httpcache')) { Add-Backup (Join-Path ${env:ProgramFiles(x86)} "Steam\$relative") }
            }
            $shared = Join-Path ${env:ProgramFiles(x86)} 'Common Files\BattlEye'
            $be = Join-Path $GamePath 'BattlEye'
            $executables = @((Join-Path $GamePath 'GTA5_Enhanced.exe'),(Join-Path $GamePath 'GTA5_Enhanced_BE.exe'),(Join-Path $GamePath 'PlayGTAV.exe'),(Join-Path $shared 'BEService.exe'),(Join-Path $be 'BEService_x64.exe'),(Join-Path $env:ProgramFiles 'Rockstar Games\Launcher\Launcher.exe'),(Join-Path $env:ProgramFiles 'Rockstar Games\Launcher\RockstarService.exe')) | Where-Object { Test-Path -LiteralPath $_ }
            if (-not $SkipFirewallRules) {
                foreach ($exe in $executables) { foreach ($direction in 'Inbound','Outbound') {
                    $sha = [Security.Cryptography.SHA256]::Create()
                    try { $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($exe.ToLowerInvariant() + $direction))).Replace('-','').Substring(0,24) } finally { $sha.Dispose() }
                    $ruleName = "GTA-Investigation-$key"
                    if (-not (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)) { Add-Action Firewall $exe $null @{Name=$ruleName; Direction=$direction} }
                } }
            }
            if ($AddDefenderExclusions) {
                $mp = Get-MpPreference
                foreach ($p in @($shared,$be) | Where-Object { Test-Path -LiteralPath $_ }) {
                    if ($p -notin @($mp.ExclusionPath)) { Add-Action Defender $p $null @{Property='ExclusionPath'} }
                }
                foreach ($exe in $executables) {
                    if ($exe -notin @($mp.ExclusionProcess)) { Add-Action Defender $exe $null @{Property='ExclusionProcess'} }
                    if ([int]$mp.EnableControlledFolderAccess -ne 0 -and $exe -notin @($mp.ControlledFolderAccessAllowedApplications)) { Add-Action Defender $exe $null @{Property='ControlledFolderAccessAllowedApplications'} }
                }
            }
            if ($RepairPermissions) { foreach ($p in @($GamePath,$be,$shared) | Where-Object { Test-Path -LiteralPath $_ }) { Add-Action Acl $p (Get-Acl -LiteralPath $p).Sddl 'SYSTEM full access on this directory only' } }
            if ($ReinstallBattlEye) {
                $installer = Join-Path $be 'BEService_x64.exe'
                if (-not (Test-Path -LiteralPath $installer) -or (Get-AuthenticodeSignature -LiteralPath $installer).Status -ne 'Valid') { throw 'A valid signed game-supplied BEService_x64.exe is required.' }
                Add-Action Native $installer $null @('-install')
            }
            if ($ResetNetworkStack) {
                Add-Action Native 'netsh.exe' $null @('winsock','reset')
                Add-Action Native 'netsh.exe' $null @('int','ip','reset',(Join-Path $script:RunPath 'ip-reset.log'))
            }
            if ($RepairWindows) {
                Add-Action Native 'DISM.exe' $null @('/Online','/Cleanup-Image','/RestoreHealth',("/LogPath:" + (Join-Path $script:RunPath 'dism.log')))
                Add-Action Native 'sfc.exe' $null @('/scannow')
            }
        }
    }
    ConvertTo-Json -InputObject @($plan.ToArray()) -Depth 12 | Set-Content (Join-Path $script:RunPath 'plan.json') -Encoding UTF8
    if (-not $Apply) { Write-Host 'Preview only. Review plan.json; rerun with -Apply to execute.'; return }
    $processGuard = if (@($plan | Where-Object Kind -ne 'Service').Count -eq 0) { '^GTA5|^PlayGTAV$' } else { '^GTA5|^PlayGTAV$|^Launcher$|^RockstarGamesLauncher$|^RockstarService$|^LauncherPatcher$|^SocialClubHelper$|^steam$|^steamwebhelper$' }
    $running = @(Get-Process | Where-Object ProcessName -match $processGuard)
    if ($running.Count) { throw "Close game and launchers before repair/restore: $($running.ProcessName -join ', '). Stop Rockstar service manually if still active." }
    Save-Evidence 'services-before' { Get-CimInstance Win32_Service | Select-Object Name,State,StartMode,PathName }
    Save-Evidence 'defender-before' { Get-MpPreference }
    Save-Evidence 'network-before' { Get-NetIPConfiguration -Detailed }
    foreach ($a in $plan) {
        Write-Audit Started 'Change' $a
        try { Invoke-Action $a ([bool]$RestoreRun); Write-Audit Completed 'Change' $a }
        catch { $script:Failures++; Write-Audit Failed 'Change' @{Operation=$a;Error=$_.Exception.Message}; throw }
    }
    Save-Evidence 'services-after' { Get-CimInstance Win32_Service | Select-Object Name,State,StartMode,PathName }
    Write-Host 'Actions completed. Capture another diagnostic and perform one controlled Online test.'
} catch { $script:Failures++; Write-Audit Failed Repair $_.Exception.Message; throw }
finally { Complete-InvestigationRun }



