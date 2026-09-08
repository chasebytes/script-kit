Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DefaultConfigPath { Join-Path $PSScriptRoot 'config.json' }

function Read-TemplateConfig {
    param([string] $Path)
    $resolved = if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path (Get-Location) $Path }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Electron template config not found: $resolved" }
    try { return Get-Content -LiteralPath $resolved -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw "Invalid Electron template config '$resolved': $($_.Exception.Message)" }
}

function Get-ElectronTemplateConfig {
    [CmdletBinding()]
    param([string] $ConfigPath = (Get-DefaultConfigPath))
    Read-TemplateConfig $ConfigPath
}

function Set-PropertyValue {
    param($Object, [string] $Name, $Value)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
    else { $property.Value = $Value }
}

function Set-PackageSpec {
    param($Map, [string] $Spec)
    $name = $Spec
    $version = 'latest'
    if ($Spec.StartsWith('@')) {
        $separator = $Spec.IndexOf('@', 1)
        if ($separator -gt 0) { $name = $Spec.Substring(0, $separator); $version = $Spec.Substring($separator + 1) }
    }
    elseif ($Spec.LastIndexOf('@') -gt 0) {
        $separator = $Spec.LastIndexOf('@')
        $name = $Spec.Substring(0, $separator)
        $version = $Spec.Substring($separator + 1)
    }
    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($version)) { throw "Invalid package specification: $Spec" }
    Set-PropertyValue $Map $name $version
}

function Set-ElectronTemplateConfig {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $ConfigPath = (Get-DefaultConfigPath),
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
    if ($OpenDevTools -and $CloseDevTools) { throw 'Use either -OpenDevTools or -CloseDevTools, not both.' }
    if ($InstallDependencies -and $SkipInstall) { throw 'Use either -InstallDependencies or -SkipInstall, not both.' }
    $config = Read-TemplateConfig $ConfigPath
    if ($PSBoundParameters.ContainsKey('ProjectName')) { $config.project.name = $ProjectName }
    if ($PSBoundParameters.ContainsKey('DisplayName')) { $config.project.displayName = $DisplayName }
    if ($PSBoundParameters.ContainsKey('Version')) { $config.project.version = $Version }
    if ($PSBoundParameters.ContainsKey('Description')) { $config.project.description = $Description }
    if ($PSBoundParameters.ContainsKey('Author')) { $config.project.author = $Author }
    if ($PSBoundParameters.ContainsKey('License')) { $config.project.license = $License }
    if ($PSBoundParameters.ContainsKey('Language')) { $config.template.language = $Language }
    if ($PSBoundParameters.ContainsKey('OutputDirectory')) { $config.template.outputDirectory = $OutputDirectory }
    if ($PSBoundParameters.ContainsKey('WindowWidth')) { $config.window.width = $WindowWidth }
    if ($PSBoundParameters.ContainsKey('WindowHeight')) { $config.window.height = $WindowHeight }
    if ($OpenDevTools) { $config.window.openDevTools = $true }
    if ($CloseDevTools) { $config.window.openDevTools = $false }
    if ($InstallDependencies) { $config.tooling.installDependencies = $true }
    if ($SkipInstall) { $config.tooling.installDependencies = $false }
    if ($ClearDependencies) { $config.dependencies = [pscustomobject] @{} }
    if ($ClearDevDependencies) { $config.devDependencies = [pscustomobject] @{} }
    foreach ($spec in @($Dependency | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        Set-PackageSpec $config.dependencies $spec
    }
    foreach ($spec in @($DevDependency | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        Set-PackageSpec $config.devDependencies $spec
    }
    if ($PSBoundParameters.ContainsKey('ElectronVersion')) { Set-PropertyValue $config.devDependencies 'electron' $ElectronVersion }
    elseif ($null -eq $config.devDependencies.PSObject.Properties['electron']) { Set-PropertyValue $config.devDependencies 'electron' 'latest' }
    $resolved = if ([IO.Path]::IsPathRooted($ConfigPath)) { $ConfigPath } else { Join-Path (Get-Location) $ConfigPath }
    if ($PSCmdlet.ShouldProcess($resolved, 'Update Electron template configuration')) {
        $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolved -Encoding UTF8
        Write-Host "Updated Electron template config: $resolved"
    }
    if ($PassThru) { $config }
}

function ConvertTo-DependencyMap {
    param($ConfiguredMap, [string[]] $AdditionalSpecs)
    $result = [ordered] @{}
    foreach ($property in $ConfiguredMap.PSObject.Properties) { $result[$property.Name] = [string] $property.Value }
    foreach ($spec in @($AdditionalSpecs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $holder = [pscustomobject] @{}
        Set-PackageSpec $holder $spec
        foreach ($property in $holder.PSObject.Properties) { $result[$property.Name] = [string] $property.Value }
    }
    return $result
}

function Invoke-NpmInstall {
    param([string] $WorkingDirectory)
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($null -eq $node) { throw 'Node.js was not found. Install the current Node.js LTS release or use -SkipInstall.' }
    $npmCli = Join-Path (Split-Path $node.Source -Parent) 'node_modules\npm\bin\npm-cli.js'
    Push-Location $WorkingDirectory
    try {
        if (Test-Path -LiteralPath $npmCli) { & $node.Source $npmCli install }
        else { & npm install }
        if ($LASTEXITCODE -ne 0) { throw "npm install failed with exit code $LASTEXITCODE." }
    }
    finally { Pop-Location }
}

function Copy-RenderedTemplate {
    param([string] $SourceRoot, [string] $DestinationRoot, [hashtable] $Tokens)
    foreach ($source in Get-ChildItem -LiteralPath $SourceRoot -Recurse -File) {
        $relative = $source.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
        $destination = Join-Path $DestinationRoot $relative
        $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
        $content = Get-Content -LiteralPath $source.FullName -Raw -Encoding UTF8
        foreach ($token in $Tokens.Keys) { $content = $content.Replace("{{$token}}", [string] $Tokens[$token]) }
        Set-Content -LiteralPath $destination -Value $content -Encoding UTF8
    }
}

function New-ElectronApp {
    [CmdletBinding()]
    param(
        [string] $ConfigPath = (Get-DefaultConfigPath),
        [ValidatePattern('^[a-z0-9][a-z0-9._-]*$')] [string] $ProjectName,
        [ValidateSet('JavaScript', 'TypeScript')] [string] $Language,
        [string] $DisplayName,
        [string] $Author,
        [string] $Version,
        [string] $Description,
        [string] $License,
        [string] $OutputDirectory,
        [ValidateRange(320, 7680)] [int] $WindowWidth,
        [ValidateRange(240, 4320)] [int] $WindowHeight,
        [string] $ElectronVersion,
        [string[]] $ExtraDependencies,
        [string[]] $ExtraDevDependencies,
        [switch] $OpenDevTools,
        [switch] $SkipInstall,
        [switch] $Force
    )
    $config = Read-TemplateConfig $ConfigPath
    $name = if ($PSBoundParameters.ContainsKey('ProjectName')) { $ProjectName } else { [string] $config.project.name }
    $languageValue = if ($PSBoundParameters.ContainsKey('Language')) { $Language } else { [string] $config.template.language }
    $display = if ($PSBoundParameters.ContainsKey('DisplayName')) { $DisplayName } else { [string] $config.project.displayName }
    $authorValue = if ($PSBoundParameters.ContainsKey('Author')) { $Author } else { [string] $config.project.author }
    $versionValue = if ($PSBoundParameters.ContainsKey('Version')) { $Version } else { [string] $config.project.version }
    $descriptionValue = if ($PSBoundParameters.ContainsKey('Description')) { $Description } else { [string] $config.project.description }
    $licenseValue = if ($PSBoundParameters.ContainsKey('License')) { $License } else { [string] $config.project.license }
    $output = if ($PSBoundParameters.ContainsKey('OutputDirectory')) { $OutputDirectory } else { [string] $config.template.outputDirectory }
    $width = if ($PSBoundParameters.ContainsKey('WindowWidth')) { $WindowWidth } else { [int] $config.window.width }
    $height = if ($PSBoundParameters.ContainsKey('WindowHeight')) { $WindowHeight } else { [int] $config.window.height }
    $devTools = if ($OpenDevTools) { $true } else { [bool] $config.window.openDevTools }
    $install = -not $SkipInstall -and [bool] $config.tooling.installDependencies
    $outputRoot = if ([IO.Path]::IsPathRooted($output)) { $output } else { Join-Path (Get-Location) $output }
    $projectPath = [IO.Path]::GetFullPath((Join-Path $outputRoot $name))
    if (Test-Path -LiteralPath $projectPath) {
        $existing = @(Get-ChildItem -LiteralPath $projectPath -Force)
        if ($existing.Count -gt 0 -and -not $Force) { throw "Project directory is not empty: $projectPath. Use -Force to overwrite generated files." }
    }
    $null = New-Item -ItemType Directory -Path $projectPath -Force
    $dependencies = ConvertTo-DependencyMap $config.dependencies $ExtraDependencies
    $devDependencies = ConvertTo-DependencyMap $config.devDependencies $ExtraDevDependencies
    if ($PSBoundParameters.ContainsKey('ElectronVersion')) { $devDependencies['electron'] = $ElectronVersion }
    if (-not $devDependencies.Contains('electron')) { $devDependencies['electron'] = 'latest' }
    if ($languageValue -eq 'TypeScript') {
        if (-not $devDependencies.Contains('typescript')) { $devDependencies['typescript'] = 'latest' }
        if (-not $devDependencies.Contains('@types/node')) { $devDependencies['@types/node'] = 'latest' }
    }
    $isTypeScript = $languageValue -eq 'TypeScript'
    $scripts = [ordered] @{ start = if ($isTypeScript) { 'npm run build && electron .' } else { 'electron .' } }
    if ($isTypeScript) { $scripts.build = 'tsc -p tsconfig.json'; $scripts.watch = 'tsc -p tsconfig.json --watch' }
    $package = [ordered] @{
        name = $name; productName = $display; version = $versionValue; description = $descriptionValue
        author = $authorValue; license = $licenseValue; private = $true
        main = if ($isTypeScript) { 'dist/main.js' } else { 'main.js' }
        scripts = $scripts; dependencies = $dependencies; devDependencies = $devDependencies
    }
    $package | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $projectPath 'package.json') -Encoding UTF8
    $templateFolder = if ($isTypeScript) { 'templates\typescript' } else { 'templates\javascript' }
    $templateRoot = Join-Path $PSScriptRoot $templateFolder
    $tokens = @{
        DISPLAY_NAME = [Net.WebUtility]::HtmlEncode($display)
        WINDOW_WIDTH = $width
        WINDOW_HEIGHT = $height
        OPEN_DEVTOOLS = $devTools.ToString().ToLowerInvariant()
    }
    Copy-RenderedTemplate $templateRoot $projectPath $tokens
    @('node_modules/', 'dist/', 'out/', '*.log') | Set-Content -LiteralPath (Join-Path $projectPath '.gitignore') -Encoding UTF8
    if ($install) { Write-Host 'Installing dependencies...'; Invoke-NpmInstall $projectPath }
    Write-Host "Created $languageValue Electron app: $projectPath"
    Write-Host "Next: cd '$projectPath'; npm start"
    return Get-Item -LiteralPath $projectPath
}

Export-ModuleMember -Function Get-ElectronTemplateConfig, Set-ElectronTemplateConfig, New-ElectronApp
