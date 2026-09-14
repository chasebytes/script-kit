#requires -Version 5.1
<#
.SYNOPSIS
Audit or launch ASUS's official Armoury Crate uninstall tool.
.DESCRIPTION
Default is a preview. Download/extract the official ASUS package yourself, then
supply ToolPath. The wrapper verifies the publisher, stages the entire extracted
package under gtaV/output, journals launch/exit and captures service inventory.
It never implements its own service/driver/registry removal or restarts Windows.
#>
[CmdletBinding()]
param(
    [string]$ToolPath,
    [switch]$Apply
)
. "$PSScriptRoot\..\gtaV\Investigation.Common.ps1"
New-InvestigationRun 'asus-uninstall' $PSBoundParameters
try {
    $faq = 'https://www.asus.com/us/support/faq/1041654/'
    $support = 'https://www.asus.com/supportonly/armoury%20crate/helpdesk_download/'
    $plan = [ordered]@{
        FAQ=$faq; DownloadPage=$support; WrapperHash=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
        Steps=@('Download Armoury Crate Uninstall Tool from ASUS support.', 'Extract the package into a dedicated directory.', 'Run this wrapper with ToolPath to preview publisher/hash and target.', 'Add Apply to launch the official interactive tool.', 'Follow ASUS prompts; restart Windows yourself to finish.', 'If unsuccessful, ASUS advises restarting and running the tool again; preserve ACUTLog*.logE for support.')
        AutomaticRollback=$false
        Scope='Official tool may remove Armoury Crate AND Aura Creator related components.'
    }
    if ($ToolPath) {
        $tool = Get-Item -LiteralPath $ToolPath
        if ($tool.PSIsContainer -or $tool.Extension -ne '.exe') { throw 'ToolPath must be the extracted official uninstall executable.' }
        if ($tool.Name -ne 'Armoury Crate Uninstall Tool.exe') { throw 'Expected Armoury Crate Uninstall Tool.exe; verify the official package before using a different filename.' }
        $signature = Get-AuthenticodeSignature -LiteralPath $tool.FullName
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'ASUSTeK COMPUTER INC') { throw 'A valid ASUSTeK signature is required.' }
        $plan.Tool=$tool.FullName
        $plan.SHA256=(Get-FileHash -LiteralPath $tool.FullName -Algorithm SHA256).Hash
        $plan.Publisher=$signature.SignerCertificate.Subject
        $plan.Version=$tool.VersionInfo.FileVersion
    }
    $plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:RunPath 'plan.json') -Encoding UTF8
    if (-not $Apply) { Write-Host "Preview saved. Official download: $support"; return }
    if (-not $ToolPath) { throw 'Apply requires ToolPath to the extracted official ASUS executable.' }
    if (-not (Test-Administrator)) { throw 'Run from Administrator PowerShell. No uninstall has started.' }
    if (@(Get-Process | Where-Object ProcessName -match '^GTA5|^PlayGTAV$').Count) { throw 'Close GTA before uninstalling.' }
    Save-Evidence 'asus-services-before' { Get-CimInstance Win32_Service | Where-Object { ($_.Name + $_.DisplayName + $_.PathName) -match 'ASUS|Armoury|Aura|LightingService|ROG' } | Select-Object Name,DisplayName,State,StartMode,PathName }
    $package = Split-Path -Parent $tool.FullName
    if ($script:RunPath.StartsWith($package.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Package directory contains the output directory; use a dedicated extracted package directory.' }
    $files = @(Get-ChildItem -LiteralPath $package -Force -Recurse)
    if (@($files | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -or ((Get-Item $package).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Extract into a dedicated directory without symbolic links or junctions.' }
    $staged = Join-Path $script:RunPath 'official-tool'
    Write-Audit Started 'Stage official package' @{Source=$package; Destination=$staged}
    Copy-Item -LiteralPath $package -Destination $staged -Recurse
    Get-ChildItem -LiteralPath $staged -File -Recurse | Get-FileHash -Algorithm SHA256 | Select-Object Path,Hash | ConvertTo-Json | Set-Content (Join-Path $script:RunPath 'package-hashes.json')
    $executable=Join-Path $staged $tool.Name
    if ((Get-FileHash -LiteralPath $executable).Hash -ne $plan.SHA256) { throw 'Executable changed while staging.' }
    Write-Audit Completed 'Stage official package' $staged
    Write-Audit Started 'Official uninstall tool' $plan
    # Visible because this is the ASUS interactive uninstall UI requested by the user.
    $process=Start-Process -FilePath $executable -WorkingDirectory $staged -PassThru -Wait
    Write-Audit Exited 'Official uninstall tool' @{ExitCode=$process.ExitCode; Logs=$staged; Interpretation='Exit alone does not prove removal; check ASUS UI, restart and inventory.'}
    Save-Evidence 'asus-services-after' { Get-CimInstance Win32_Service | Where-Object { ($_.Name + $_.DisplayName + $_.PathName) -match 'ASUS|Armoury|Aura|LightingService|ROG' } | Select-Object Name,DisplayName,State,StartMode,PathName }
    Write-Host 'Follow the ASUS result dialog and restart Windows to finish. Preserve official-tool logs.'
} catch { $script:Failures++; Write-Audit Failed 'ASUS uninstall workflow' $_.Exception.Message; throw }
finally { Complete-InvestigationRun }

