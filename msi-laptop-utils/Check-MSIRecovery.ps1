param(
  [Parameter(Mandatory=$true)]
  [ValidatePattern('^[A-Z]$')]
  [string]$DriveLetter
)

$drivePath = "$DriveLetter`:"
$dir = Join-Path $drivePath 'RECOVERY_DVD'

if (-not (Test-Path $dir)) { Write-Host "Folder not found: $dir" -ForegroundColor Red; exit 1 }

# Collect and order all Install*.swm parts
$parts = Get-ChildItem $dir -Filter 'Install*.swm' -ErrorAction SilentlyContinue |
  Sort-Object {
    $m = [regex]::Match($_.BaseName,'(\d+)$')
    if ($m.Success) { [int]$m.Groups[1].Value } else { 1 }  # base 'Install.swm' will be treated as 1
  }

if (-not $parts) { Write-Host "No SWM parts found in $dir" -ForegroundColor Red; exit 1 }

# Basic continuity check: expect Install.swm + Install2.swm..N (no gaps)
$base = Join-Path $dir 'Install.swm'
if (-not (Test-Path $base)) { Write-Host "Missing base part: $base" -ForegroundColor Red; exit 1 }

$existingSuffixes = $parts | ForEach-Object {
  $m = [regex]::Match($_.BaseName,'(\d+)$')
  if ($m.Success) { [int]$m.Groups[1].Value } else { 1 }
} | Sort-Object

# Validate each part with DISM /Get-WimInfo (no /SWMFile here)
$allOk = $true
foreach ($p in $parts) {
  Write-Host "`n=== Checking $($p.FullName) ===" -ForegroundColor Cyan
  $out = & dism /Get-WimInfo /WimFile:"$($p.FullName)" 2>&1
  if ($LASTEXITCODE -eq 0) {
    Write-Host "PASS: Readable." -ForegroundColor Green
  } else {
    Write-Host "FAIL: DISM error." -ForegroundColor Red
    $out | Select-String 'Error|0x' | ForEach-Object { Write-Host $_.Line -ForegroundColor DarkRed }
    $allOk = $false
  }
}

Write-Host "`nParts present:" -ForegroundColor Yellow
$parts | Format-Table Name, @{N='Size(MB)';E={[math]::Round($_.Length/1MB,1)}}

if ($allOk) {
  Write-Host "`n=== RESULT: All split parts are readable. ===" -ForegroundColor Green
  Write-Host "Next step to fully validate: test-boot the USB (F11 on MSI) and confirm the MSI Recovery UI loads."
} else {
  Write-Host "`n=== RESULT: One or more parts failed to read. ===" -ForegroundColor Red
  Write-Host "If only a single part fails, the set is unusable until that file is replaced."
}
