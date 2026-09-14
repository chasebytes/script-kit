#requires -Version 5.1
<#
.SYNOPSIS
Read-only GTA/BattlEye investigation. All artifacts stay in gtaV/output.
#>
[CmdletBinding()]
param(
    [string]$GamePath = 'C:\Program Files (x86)\Steam\steamapps\common\Grand Theft Auto V Enhanced',
    [ValidateSet('Baseline','PostKick')][string]$Phase = 'Baseline',
    [switch]$IncludeEventScan,
    [switch]$SkipNetwork
)
. "$PSScriptRoot\Investigation.Common.ps1"
New-InvestigationRun "diagnostic-$Phase" $PSBoundParameters
function Write-Step([string]$Message) { Write-Host $Message }
$OutputDirectory = $script:RunPath
$ClearBattlEyeCache = $RepairAll = $ResetNetworkStack = $RepairWindows = $false
$SkipDefenderExclusions = $SkipFirewallRules = $true
$cacheBackupPath = $repairBackupPath = $null
function Get-SecurityFileEvidence {
    param([Parameter(Mandatory)][string[]] $Paths)

    foreach ($path in $Paths | Sort-Object -Unique) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            [pscustomobject]@{ Path = $path; Exists = $false; SignatureStatus = $null; Signer = $null; Version = $null; SHA256 = $null }
            continue
        }

        $signature = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction SilentlyContinue
        $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        $hash = Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Path            = $path
            Exists          = $true
            SignatureStatus = if ($signature) { [string] $signature.Status } else { $null }
            Signer          = if ($signature -and $signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { $null }
            Version         = if ($item) { $item.VersionInfo.FileVersion } else { $null }
            SHA256          = if ($hash) { $hash.Hash } else { $null }
        }
    }
}

function Test-IsPrivateOrCarrierAddress {
    param([Parameter(Mandatory)][string] $Address)

    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref] $parsed) -or
        $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        return $false
    }

    $bytes = $parsed.GetAddressBytes()
    return (
        $bytes[0] -eq 10 -or
        ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
        ($bytes[0] -eq 192 -and $bytes[1] -eq 168) -or
        ($bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127) -or
        ($bytes[0] -eq 169 -and $bytes[1] -eq 254)
    )
}

function Get-AddressCategory {
    param([Parameter(Mandatory)][string] $Address)

    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref] $parsed)) { return 'Unknown' }
    if ($parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return 'IPv6' }

    $bytes = $parsed.GetAddressBytes()
    if ($bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127) { return 'Carrier-grade NAT range' }
    if (Test-IsPrivateOrCarrierAddress $Address) { return 'Private/local range' }
    return 'Public range'
}

function Hide-PublicAddress {
    param([AllowNull()][string] $Address)

    if ([string]::IsNullOrWhiteSpace($Address)) { return $Address }
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref] $parsed)) { return $Address }
    if ($parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return '[IPv6 address redacted]' }
    if (Test-IsPrivateOrCarrierAddress $Address) { return $Address }

    $bytes = $parsed.GetAddressBytes()
    return "$($bytes[0]).$($bytes[1]).$($bytes[2]).x"
}

function Test-PingQuality {
    param(
        [Parameter(Mandatory)][string] $Target,
        [int] $Count = 8,
        [int] $TimeoutMilliseconds = 1200
    )

    $latencies = [Collections.Generic.List[double]]::new()
    $ping = [Net.NetworkInformation.Ping]::new()
    try {
        for ($index = 0; $index -lt $Count; $index++) {
            try {
                $reply = $ping.Send($Target, $TimeoutMilliseconds)
                if ($reply.Status -eq [Net.NetworkInformation.IPStatus]::Success) {
                    $latencies.Add([double] $reply.RoundtripTime)
                }
            }
            catch { }
        }
    }
    finally {
        $ping.Dispose()
    }

    $received = $latencies.Count
    $lossPercent = [math]::Round((($Count - $received) / [double] $Count) * 100, 1)
    $average = if ($received -gt 0) {
        [math]::Round(($latencies | Measure-Object -Average).Average, 1)
    }
    else { $null }

    [pscustomobject]@{
        Target           = $Target
        Sent             = $Count
        Received         = $received
        PacketLossPercent = $lossPercent
        AverageLatencyMs = $average
        Note             = if ($received -eq 0) { 'Target may block ICMP; this alone does not prove an outage.' } else { $null }
    }
}

function Test-TcpReachability {
    param(
        [Parameter(Mandatory)][string] $HostName,
        [int] $Port = 443,
        [int] $TimeoutMilliseconds = 3500
    )

    $resolved = @()
    try {
        $resolved = @([Net.Dns]::GetHostAddresses($HostName) | ForEach-Object { Hide-PublicAddress $_.IPAddressToString })
    }
    catch {
        return [pscustomobject]@{
            HostName = $HostName; Port = $Port; DnsResolved = $false
            ResolvedAddresses = @(); TcpConnected = $false; Error = $_.Exception.Message
        }
    }

    $client = [Net.Sockets.TcpClient]::new()
    try {
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            throw "Connection timed out after $TimeoutMilliseconds ms."
        }
        $client.EndConnect($async)
        $connected = $client.Connected
        $errorText = $null
    }
    catch {
        $connected = $false
        $errorText = $_.Exception.Message
    }
    finally {
        $client.Dispose()
    }

    [pscustomobject]@{
        HostName          = $HostName
        Port              = $Port
        DnsResolved       = $resolved.Count -gt 0
        ResolvedAddresses = $resolved
        TcpConnected      = $connected
        Error             = $errorText
    }
}

function Invoke-StunRequest {
    param(
        [Parameter(Mandatory)][Net.Sockets.UdpClient] $Client,
        [Parameter(Mandatory)][string] $Server,
        [int] $Port = 19302
    )

    try {
        $serverAddress = [Net.Dns]::GetHostAddresses($Server) |
            Where-Object AddressFamily -eq ([Net.Sockets.AddressFamily]::InterNetwork) |
            Select-Object -First 1
        if ($null -eq $serverAddress) { throw 'No IPv4 address was returned.' }

        $request = New-Object byte[] 20
        $request[0] = 0x00; $request[1] = 0x01
        $request[2] = 0x00; $request[3] = 0x00
        $cookie = [byte[]] @(0x21, 0x12, 0xA4, 0x42)
        [Array]::Copy($cookie, 0, $request, 4, 4)
        $random = [Security.Cryptography.RandomNumberGenerator]::Create()
        try {
            $transaction = New-Object byte[] 12
            $random.GetBytes($transaction)
        }
        finally { $random.Dispose() }
        [Array]::Copy($transaction, 0, $request, 8, 12)

        $endpoint = [Net.IPEndPoint]::new($serverAddress, $Port)
        $null = $Client.Send($request, $request.Length, $endpoint)
        $remote = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
        $response = $Client.Receive([ref] $remote)

        $offset = 20
        while (($offset + 4) -le $response.Length) {
            $attributeType = ($response[$offset] -shl 8) -bor $response[$offset + 1]
            $attributeLength = ($response[$offset + 2] -shl 8) -bor $response[$offset + 3]
            $valueOffset = $offset + 4

            if (($attributeType -eq 0x0020 -or $attributeType -eq 0x0001) -and
                $attributeLength -ge 8 -and $response[$valueOffset + 1] -eq 0x01) {
                $mappedPort = ($response[$valueOffset + 2] -shl 8) -bor $response[$valueOffset + 3]
                $addressBytes = New-Object byte[] 4
                for ($byteIndex = 0; $byteIndex -lt 4; $byteIndex++) {
                    $addressBytes[$byteIndex] = $response[$valueOffset + 4 + $byteIndex]
                }

                if ($attributeType -eq 0x0020) {
                    $mappedPort = $mappedPort -bxor 0x2112
                    for ($byteIndex = 0; $byteIndex -lt 4; $byteIndex++) {
                        $addressBytes[$byteIndex] = $addressBytes[$byteIndex] -bxor $cookie[$byteIndex]
                    }
                }

                $mappedAddress = [Net.IPAddress]::new($addressBytes).IPAddressToString
                return [pscustomobject]@{
                    Server = $Server; Success = $true; Address = $mappedAddress
                    MaskedAddress = Hide-PublicAddress $mappedAddress
                    Port = $mappedPort; Error = $null
                }
            }

            $offset = $valueOffset + $attributeLength
            $offset += (4 - ($offset % 4)) % 4
        }
        throw 'The STUN response did not contain an IPv4 mapped-address attribute.'
    }
    catch {
        return [pscustomobject]@{
            Server = $Server; Success = $false; Address = $null
            MaskedAddress = $null; Port = $null; Error = $_.Exception.Message
        }
    }
}

function Test-StunMapping {
    $client = [Net.Sockets.UdpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
    $client.Client.ReceiveTimeout = 3500
    $client.Client.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Any, 0))
    try {
        $first = Invoke-StunRequest -Client $client -Server 'stun.l.google.com'
        $second = Invoke-StunRequest -Client $client -Server 'stun1.l.google.com'
    }
    finally { $client.Dispose() }

    if ($first.Success -and $second.Success) {
        $sameMapping = $first.Address -eq $second.Address -and $first.Port -eq $second.Port
        $assessment = if ($sameMapping) {
            'Endpoint-independent UDP mapping observed. This is favorable, but does not by itself prove an Open NAT.'
        }
        else {
            'The UDP mapping changed between STUN destinations. This suggests destination-dependent/symmetric mapping and can contribute to Strict NAT.'
        }
    }
    else {
        $sameMapping = $null
        $assessment = 'STUN was inconclusive. UDP 19302 may be blocked, filtered, or unavailable.'
    }

    [pscustomobject]@{
        SameMapping = $sameMapping
        Assessment  = $assessment
        Results     = @(
            [pscustomobject]@{ Server = $first.Server; Success = $first.Success; MappedAddress = $first.MaskedAddress; MappedPort = $first.Port; Error = $first.Error },
            [pscustomobject]@{ Server = $second.Server; Success = $second.Success; MappedAddress = $second.MaskedAddress; MappedPort = $second.Port; Error = $second.Error }
        )
    }
}

function Test-UpnpDiscovery {
    $client = [Net.Sockets.UdpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
    $client.Client.ReceiveTimeout = 3000
    try {
        $requestText = "M-SEARCH * HTTP/1.1`r`nHOST: 239.255.255.250:1900`r`nMAN: `"ssdp:discover`"`r`nMX: 2`r`nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1`r`n`r`n"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes($requestText)
        $destination = [Net.IPEndPoint]::new([Net.IPAddress]::Parse('239.255.255.250'), 1900)
        $null = $client.Send($requestBytes, $requestBytes.Length, $destination)
        $remote = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
        $responseBytes = $client.Receive([ref] $remote)
        $responseText = [Text.Encoding]::ASCII.GetString($responseBytes)
        $serverHeader = if ($responseText -match '(?im)^SERVER:\s*(.+)$') { $Matches[1].Trim() } else { $null }
        return [pscustomobject]@{
            GatewayAdvertised = $true
            ResponderAddress  = $remote.Address.IPAddressToString
            ServerHeader      = $serverHeader
            Note              = 'A UPnP Internet Gateway Device responded. This does not prove that port mapping is enabled in router settings.'
        }
    }
    catch {
        return [pscustomobject]@{
            GatewayAdvertised = $false
            ResponderAddress  = $null
            ServerHeader      = $null
            Note              = 'No UPnP gateway response was received. UPnP may be disabled, filtered, unsupported, or slow to respond.'
        }
    }
    finally { $client.Dispose() }
}

function Get-TracerouteIndicators {
    $raw = & tracert.exe -d -h 6 -w 700 1.1.1.1 2>&1 | Out-String
    $addresses = [regex]::Matches($raw, '(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)') |
        ForEach-Object Value |
        Where-Object { $_ -ne '1.1.1.1' } |
        Select-Object -Unique

    $hops = foreach ($address in $addresses) {
        [pscustomobject]@{
            Address  = Hide-PublicAddress $address
            Category = Get-AddressCategory $address
        }
    }

    $privateHopCount = @($hops | Where-Object Category -in @('Private/local range', 'Carrier-grade NAT range')).Count
    [pscustomobject]@{
        Hops                = @($hops)
        PrivateLikeHopCount = $privateHopCount
        Assessment          = if (@($hops | Where-Object Category -eq 'Carrier-grade NAT range').Count -gt 0) {
            'A carrier-grade NAT address appeared upstream. Ask the ISP whether your connection uses CGNAT.'
        }
        elseif ($privateHopCount -gt 1) {
            'Multiple private-address hops were observed. This can indicate double NAT, although some ISP routing can look similar.'
        }
        else {
            'No obvious CGNAT/double-NAT indicator was found in the responding hops.'
        }
    }
}


try {
# Capture transient evidence before slower network probes and hashing.
Save-Evidence 'process-commandlines' { Get-CimInstance Win32_Process | Select-Object Name,ProcessId,ParentProcessId,ExecutablePath,CommandLine,CreationDate }
Save-Evidence 'services' { Get-CimInstance Win32_Service | Select-Object Name,DisplayName,State,StartMode,PathName,ProcessId,ExitCode,ServiceSpecificExitCode }
Save-Evidence 'drivers' { Get-CimInstance Win32_SystemDriver | Select-Object Name,DisplayName,State,StartMode,PathName,ExitCode }
Save-Evidence 'gta-modules-live' { Get-Process GTA5_Enhanced -ErrorAction Stop | ForEach-Object Modules | Select-Object ModuleName,FileName,FileVersionInfo }
Save-Evidence 'tcp-live' { Get-NetTCPConnection | Select-Object OwningProcess,State,LocalAddress,LocalPort,RemoteAddress,RemotePort }
Save-Evidence 'udp-live' { Get-NetUDPEndpoint | Select-Object OwningProcess,LocalAddress,LocalPort }
Save-Evidence 'startup' { Get-CimInstance Win32_StartupCommand | Select-Object Name,Command,Location,User }
Save-Evidence 'hardware-tasks' { Get-ScheduledTask | Where-Object { ($_.TaskName + $_.TaskPath) -match 'Razer|Armoury|ASUS|Aura' } | Select-Object TaskName,TaskPath,State,Actions,Triggers }
Save-Evidence 'network-bindings' { Get-NetAdapterBinding -AllBindings | Select-Object Name,DisplayName,ComponentID,Enabled }
Save-Evidence 'filter-drivers' { Invoke-Native fltmc.exe @('filters') }
Save-Evidence 'boot' { Invoke-Native bcdedit.exe @('/enum') }
Save-Evidence 'defender-threats' { Get-MpThreatDetection }
Save-Evidence 'firewall-effective' { Get-NetFirewallRule -PolicyStore ActiveStore | Select-Object Name,DisplayName,Enabled,Direction,Action,PolicyStoreSource,PolicyStoreSourceType }
Save-Evidence 'firewall-applications' { Get-NetFirewallApplicationFilter -PolicyStore ActiveStore | Select-Object InstanceID,Program,Package }
Save-Evidence 'firewall-ports' { Get-NetFirewallPortFilter -PolicyStore ActiveStore | Select-Object InstanceID,Protocol,LocalPort,RemotePort }
Save-Evidence 'wfp-block-events' { Get-WinEvent -FilterHashtable @{ LogName='Security'; Id=5152,5157; StartTime=(Get-Date).AddHours(-2) } -MaxEvents 1000 -ErrorAction Stop | Select-Object TimeCreated,Id,Message }
Save-Evidence 'permissions' { foreach ($p in @($GamePath,(Join-Path $GamePath 'BattlEye'),(Join-Path ${env:ProgramFiles(x86)} 'Common Files\BattlEye'))) { Get-Acl -LiteralPath $p | Select-Object Path,Sddl,AccessToString } }
Save-Evidence 'battleye-log-inventory' { foreach ($p in @((Join-Path $GamePath 'BattlEye'),(Join-Path ${env:ProgramFiles(x86)} 'Common Files\BattlEye'),(Join-Path $env:LOCALAPPDATA 'BattlEye'))) { if (Test-Path $p) { Get-ChildItem -LiteralPath $p -Recurse -File | Select-Object FullName,Length,LastWriteTime } } }
if ($SkipNetwork) {
    function Test-PingQuality { param($Target) [pscustomobject]@{Target=$Target;PacketLossPercent=0;Received=0;Skipped=$true} }
    function Test-TcpReachability { param($HostName) [pscustomobject]@{HostName=$HostName;Port=443;TcpConnected=$true;Skipped=$true} }
    function Test-StunMapping { [pscustomobject]@{SameMapping=$null;Assessment='Skipped'} }
    function Test-UpnpDiscovery { [pscustomobject]@{GatewayAdvertised=$null;Note='Skipped'} }
    function Get-TracerouteIndicators { [pscustomobject]@{Assessment='Skipped'} }
}
Write-Step 'Collecting adapter and route information'
$ipConfigurations = foreach ($configuration in Get-NetIPConfiguration -ErrorAction SilentlyContinue) {
    if ($null -eq $configuration.IPv4DefaultGateway -and $null -eq $configuration.IPv4Address) { continue }

    $ipv4Addresses = @()
    if ($null -ne $configuration.IPv4Address) {
        $ipv4Addresses = @($configuration.IPv4Address | ForEach-Object {
            "$($_.IPAddress)/$($_.PrefixLength)"
        })
    }

    $defaultGateways = @()
    if ($null -ne $configuration.IPv4DefaultGateway) {
        $defaultGateways = @($configuration.IPv4DefaultGateway | ForEach-Object {
            $_.NextHop
        })
    }

    $dnsServers = @()
    if ($null -ne $configuration.DNSServer) {
        $dnsServers = @($configuration.DNSServer | ForEach-Object {
            if ($null -ne $_.ServerAddresses) {
                $_.ServerAddresses
            }
        })
    }

    [pscustomobject]@{
        InterfaceAlias = $configuration.InterfaceAlias
        InterfaceIndex = $configuration.InterfaceIndex
        IPv4Addresses  = $ipv4Addresses
        DefaultGateway = $defaultGateways
        DnsServers     = $dnsServers
    }
}

$adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue |
    Select-Object Name, InterfaceDescription, Status, LinkSpeed, MediaConnectionState)
$ipInterfaces = @(Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object ConnectionState -eq 'Connected' |
    Select-Object InterfaceAlias, InterfaceMetric, NlMtu, Dhcp, ConnectionState)
$defaultRoutes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Sort-Object RouteMetric, InterfaceMetric |
    Select-Object InterfaceAlias, InterfaceIndex, NextHop, RouteMetric, InterfaceMetric)

$defaultGateway = $defaultRoutes | Select-Object -First 1 -ExpandProperty NextHop -ErrorAction SilentlyContinue

Write-Step 'Testing packet loss and basic service reachability'
$pingResults = [Collections.Generic.List[object]]::new()
if ($defaultGateway) { $pingResults.Add((Test-PingQuality -Target $defaultGateway)) }
$pingResults.Add((Test-PingQuality -Target '1.1.1.1'))

$tcpResults = @(
    Test-TcpReachability -HostName 'www.battleye.com'
    Test-TcpReachability -HostName 'signin.rockstargames.com'
    Test-TcpReachability -HostName 'prod.ros.rockstargames.com'
)

Write-Step 'Testing UDP mapping consistency and UPnP discovery'
$stun = Test-StunMapping
$upnp = Test-UpnpDiscovery

Write-Step 'Looking for double-NAT and CGNAT indicators'
$traceIndicators = Get-TracerouteIndicators

Write-Step 'Capturing live GTA and BattlEye state'
$battleyeService = Get-CimInstance Win32_Service -Filter "Name='BEService'" -ErrorAction SilentlyContinue
$bedaisyService = Get-CimInstance Win32_SystemDriver -Filter "Name='BEDaisy'" -ErrorAction SilentlyContinue

$processPattern = 'GTA|BattlEye|BEService|Rockstar|Steam|RTSS|Afterburner|AutoHotkey|WeMod|CheatEngine|ProcessHacker|SystemInformer|NetLimiter|GlassWire|Overwolf|WARP|Nahimic|A-Volute|MSI|Mystic|LEDKeeper|CC_Engine|Armoury|Aura|Razer|Corsair|iCUE|Logitech|GHub|SteelSeries|SpecialK|ReShade|OBS|Discord'
$relevantProcesses = foreach ($process in Get-Process -ErrorAction SilentlyContinue | Where-Object ProcessName -match $processPattern) {
    $path = try { $process.Path } catch { $null }
    [pscustomobject]@{
        ProcessName = $process.ProcessName
        Id          = $process.Id
        Path        = $path
    }
}
$potentialInterferencePattern = 'RTSS|Afterburner|AutoHotkey|WeMod|CheatEngine|ProcessHacker|SystemInformer|NetLimiter|GlassWire|Overwolf|WARP|Nahimic|A-Volute|MSI|Mystic|LEDKeeper|CC_Engine|Armoury|Aura|Razer|Corsair|iCUE|Logitech|GHub|SteelSeries|SpecialK|ReShade|OBS|Discord'
$potentiallyInterferingProcesses = @($relevantProcesses |
    Where-Object ProcessName -match $potentialInterferencePattern)
$connectedVpnLikeAdapters = @($adapters |
    Where-Object {
        $_.Status -eq 'Up' -and
        ($_.Name -match 'VPN|WARP|WireGuard|TAP|TUN|Hamachi|Radmin' -or
         $_.InterfaceDescription -match 'VPN|WARP|WireGuard|TAP|TUN|Hamachi|Radmin')
    })

$driverPattern = 'RTCore|WinRing|AsIO|inpout|MSI|Nahimic|AVolute|Corsair|Razer|Logi|GHub|SteelSeries|Elgato|VBox|VMware|Npcap|WinDivert'
$potentiallyRelevantDrivers = @(Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue |
    Where-Object {
        $_.State -eq 'Running' -and
        ($_.Name -match $driverPattern -or $_.DisplayName -match $driverPattern -or $_.PathName -match $driverPattern)
    } |
    Select-Object Name, DisplayName, State, StartMode, PathName)

$gtaModules = @()
try {
    $gtaModules = @(Get-Process -Name 'GTA5_Enhanced' -ErrorAction Stop |
        ForEach-Object Modules |
        Select-Object ModuleName, FileName, Company)
}
catch { Write-Audit Unavailable 'Legacy collection' $_.Exception.Message }

$antivirusProducts = @()
try {
    $antivirusProducts = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop |
        Select-Object displayName, pathToSignedProductExe, productState)
}
catch { Write-Audit Unavailable 'Legacy collection' $_.Exception.Message }

$securityFilePaths = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Common Files\BattlEye\BEService.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Common Files\BattlEye\BEDaisy.sys'),
    (Join-Path $GamePath 'BattlEye\BEService_x64.exe'),
    (Join-Path $GamePath 'GTA5_Enhanced_BE.exe'),
    (Join-Path $GamePath 'GTA5_Enhanced.exe'),
    (Join-Path $GamePath 'PlayGTAV.exe')
)
$securityFileEvidence = @(Get-SecurityFileEvidence -Paths $securityFilePaths)

$relevantProcessIds = @($relevantProcesses | Select-Object -ExpandProperty Id)
$tcpEndpoints = if ($relevantProcessIds.Count -gt 0) {
    @(Get-NetTCPConnection -ErrorAction SilentlyContinue |
        Where-Object OwningProcess -in $relevantProcessIds |
        Select-Object State, LocalAddress, LocalPort, RemoteAddress, RemotePort, OwningProcess)
}
else { @() }
$udpEndpoints = if ($relevantProcessIds.Count -gt 0) {
    @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
        Where-Object OwningProcess -in $relevantProcessIds |
        Select-Object LocalAddress, LocalPort, OwningProcess)
}
else { @() }

$firewallProfiles = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue |
    Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction)
$firewallRules = @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
    Where-Object DisplayName -match 'GTA|Grand Theft Auto|BattlEye|Rockstar' |
    Select-Object DisplayName, Enabled, Direction, Action, Profile)

$hostsOverrides = @()
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
if (Test-Path -LiteralPath $hostsPath) {
    $hostsOverrides = @(Get-Content -LiteralPath $hostsPath -ErrorAction SilentlyContinue |
        Where-Object { $_ -notmatch '^\s*#' -and $_ -match 'battleye|rockstar|gta' })
}

$launchConfigurationMatches = [Collections.Generic.List[object]]::new()
$commandLineFile = Join-Path $GamePath 'commandline.txt'
if (Test-Path -LiteralPath $commandLineFile) {
    $launchConfigurationMatches.Add([pscustomobject]@{
        Path = $commandLineFile
        Match = (Get-Content -LiteralPath $commandLineFile -Raw -ErrorAction SilentlyContinue)
    })
}
$launchSearchRoots = @(
    (Join-Path $env:LOCALAPPDATA 'Rockstar Games'),
    (Join-Path ${env:ProgramFiles(x86)} 'Steam\userdata')
)
foreach ($searchRoot in $launchSearchRoots) {
    if (-not (Test-Path -LiteralPath $searchRoot -PathType Container)) { continue }
    Get-ChildItem -LiteralPath $searchRoot -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -lt 5MB -and $_.Extension -match '^\.(vdf|ini|cfg|conf|json|xml|txt)$' } |
        Select-String -Pattern 'LaunchOptions|launcharguments|nobattleye|no_battleye' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $launchConfigurationMatches.Add([pscustomobject]@{ Path = $_.Path; Match = $_.Line.Trim() })
        }
}

$defenderConfiguration = $null
if (Get-Command Get-MpPreference -ErrorAction SilentlyContinue) {
    try {
        $mp = Get-MpPreference -ErrorAction Stop
        $defenderConfiguration = [pscustomobject]@{
            ControlledFolderAccess = $mp.EnableControlledFolderAccess
            ExclusionPaths          = @($mp.ExclusionPath | Where-Object { $_ -match 'BattlEye|Grand Theft Auto|GTA5' })
            ExclusionProcesses      = @($mp.ExclusionProcess | Where-Object { $_ -match 'BattlEye|Grand Theft Auto|GTA5|PlayGTAV' })
            AllowedApplications     = @($mp.ControlledFolderAccessAllowedApplications | Where-Object { $_ -match 'BattlEye|Grand Theft Auto|GTA5|PlayGTAV' })
        }
    }
    catch { Write-Audit Unavailable 'Legacy collection' $_.Exception.Message }
}

$eventCutoff = (Get-Date).AddHours(-2)
$relevantEvents = [Collections.Generic.List[object]]::new()
foreach ($logName in 'System', 'Application', 'Microsoft-Windows-CodeIntegrity/Operational', 'Microsoft-Windows-Windows Defender/Operational') {
    try {
        Get-WinEvent -FilterHashtable @{ LogName = $logName; StartTime = $eventCutoff } -ErrorAction Stop |
            Where-Object Message -match 'BattlEye|BEService|BEDaisy|GTA5|Grand Theft Auto|Rockstar' |
            Select-Object TimeCreated, LogName, ProviderName, Id, LevelDisplayName, Message |
            ForEach-Object { $relevantEvents.Add($_) }
    }
    catch { Write-Audit Unavailable 'Legacy collection' $_.Exception.Message }
}

$proxyState = (& netsh.exe winhttp show proxy 2>&1 | Out-String).Trim()
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = (Get-Location).Path }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$reportPath = Join-Path $OutputDirectory "GTA-Network-Diagnostics-$timestamp.json"

$warnings = [Collections.Generic.List[string]]::new()
if ($null -eq $battleyeService) {
    $warnings.Add('BEService is not installed or could not be queried.')
}
elseif ($battleyeService.State -ne 'Running') {
    $warnings.Add("BEService state is '$($battleyeService.State)'. This is expected when GTA is closed, but suspicious if captured while GTA Online or the kick alert was still open.")
}
if ($null -eq $bedaisyService) { $warnings.Add('The BEDaisy kernel driver was not found or could not be queried.') }
elseif ($bedaisyService.State -ne 'Running') { $warnings.Add("BEDaisy driver state is '$($bedaisyService.State)'.") }
foreach ($pingResult in $pingResults) {
    if ($pingResult.PacketLossPercent -gt 0 -and $pingResult.Received -gt 0) {
        $warnings.Add("Packet loss to $($pingResult.Target): $($pingResult.PacketLossPercent)%.")
    }
}
if ($stun.SameMapping -eq $false) { $warnings.Add($stun.Assessment) }
if (-not $SkipNetwork -and -not $upnp.GatewayAdvertised) { $warnings.Add($upnp.Note) }
if ($traceIndicators.Assessment -match '^A carrier-grade NAT address') { $warnings.Add($traceIndicators.Assessment) }
foreach ($tcpResult in $tcpResults) {
    if (-not $tcpResult.TcpConnected) { $warnings.Add("TCP connection failed: $($tcpResult.HostName):$($tcpResult.Port).") }
}
if ($hostsOverrides.Count -gt 0) { $warnings.Add('The Windows hosts file contains entries mentioning Rockstar, GTA, or BattlEye.') }
if ($launchConfigurationMatches.Count -gt 0) {
    $warnings.Add('Launch configuration evidence was captured; inspect LaunchConfigMatches. Empty LaunchOptions values are normal, and matches may belong to other Steam games.')
}
if ($potentiallyInterferingProcesses.Count -gt 0) {
    $names = ($potentiallyInterferingProcesses.ProcessName | Sort-Object -Unique) -join ', '
    $warnings.Add("Potentially relevant overlay, monitoring, macro, or filtering processes were running: $names.")
}
if ($potentiallyRelevantDrivers.Count -gt 0) {
    $names = ($potentiallyRelevantDrivers.Name | Sort-Object -Unique) -join ', '
    $warnings.Add("Potentially relevant low-level hardware, monitoring, capture, or network drivers were running: $names. Presence alone does not establish a conflict.")
}
foreach ($fileEvidence in $securityFileEvidence) {
    if (-not $fileEvidence.Exists) {
        $warnings.Add("Expected security/game file was not found: $($fileEvidence.Path).")
    }
    elseif ($fileEvidence.SignatureStatus -and $fileEvidence.SignatureStatus -ne 'Valid') {
        $warnings.Add("Authenticode signature is $($fileEvidence.SignatureStatus): $($fileEvidence.Path).")
    }
}
if (@($antivirusProducts | Where-Object displayName -match 'AVG|Trend Micro').Count -gt 0) {
    $warnings.Add('AVG or Trend Micro was detected. Rockstar specifically lists these antivirus products as known BattlEye compatibility problems.')
}
$thirdPartyAntivirus = @($antivirusProducts | Where-Object displayName -notmatch 'Microsoft Defender|Windows Defender')
if ($thirdPartyAntivirus.Count -gt 0) {
    $names = ($thirdPartyAntivirus.displayName | Sort-Object -Unique) -join ', '
    $warnings.Add("Third-party antivirus detected: $names. PowerShell cannot safely configure vendor-specific exclusions; add both BattlEye folders manually in that product.")
}
if ($connectedVpnLikeAdapters.Count -gt 0) {
    $names = ($connectedVpnLikeAdapters.Name | Sort-Object -Unique) -join ', '
    $warnings.Add("Connected VPN-like or virtual network adapters were detected: $names.")
}
if (@($firewallRules | Where-Object { [int]$_.Enabled -eq 1 -and [int]$_.Action -eq 2 }).Count -eq 0) {
    $warnings.Add('No enabled GTA, Rockstar, or BattlEye allow rules were found by display name in the active Windows Firewall policy.')
}

$report = [ordered]@{
    Phase                  = $Phase
    NetworkTestsSkipped    = [bool]$SkipNetwork
    CollectionFailures     = $script:Failures
    CapturedAt             = Get-Date
    Instructions           = 'For best results, capture while GTA Online is running or immediately after a BattlEye kick without closing GTA.'
    RanElevated            = (Test-Administrator)
    CacheClearRequested    = [bool] $ClearBattlEyeCache
    CacheBackupPath        = $cacheBackupPath
    ComprehensiveRepair    = [bool] $RepairAll
    RepairBackupPath       = $repairBackupPath
    NetworkResetRequested  = [bool] $ResetNetworkStack
    WindowsRepairRequested = [bool] $RepairWindows
    DefenderExclusionsUsed = [bool]($RepairAll -and -not $SkipDefenderExclusions)
    FirewallRulesRequested = -not [bool] $SkipFirewallRules
    GamePath               = $GamePath
    GamePathExists         = Test-Path -LiteralPath $GamePath
    Findings               = @($warnings)
    BattlEyeService        = if ($battleyeService) { $battleyeService | Select-Object Name, State, Status, StartMode, ProcessId, PathName, ExitCode, ServiceSpecificExitCode } else { $null }
    BattlEyeDriver         = if ($bedaisyService) { $bedaisyService | Select-Object Name, State, Status, StartMode, PathName } else { $null }
    Adapters               = $adapters
    IPv4Configuration      = @($ipConfigurations)
    IPv4Interfaces         = $ipInterfaces
    DefaultRoutes          = $defaultRoutes
    PingTests              = @($pingResults)
    TcpReachability        = $tcpResults
    StunMappingTest        = $stun
    UpnpDiscovery          = $upnp
    RouteIndicators        = $traceIndicators
    RelevantProcesses      = @($relevantProcesses)
    PotentialInterference  = $potentiallyInterferingProcesses
    PotentialDrivers       = $potentiallyRelevantDrivers
    LoadedGtaModules       = $gtaModules
    AntivirusProducts      = $antivirusProducts
    SecurityFileEvidence   = $securityFileEvidence
    DefenderConfiguration  = $defenderConfiguration
    LaunchConfigMatches    = @($launchConfigurationMatches)
    ConnectedVpnAdapters   = $connectedVpnLikeAdapters
    RelevantTcpConnections = $tcpEndpoints
    RelevantUdpEndpoints   = $udpEndpoints
    FirewallProfiles       = $firewallProfiles
    RelevantFirewallRules  = $firewallRules
    HostsFileOverrides     = $hostsOverrides
    WinHttpProxy           = $proxyState
    RelevantWindowsEvents  = @($relevantEvents)
}

$report | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath $reportPath -Encoding UTF8

Write-Step 'Diagnostic capture complete'
Write-Host "Report: $reportPath" -ForegroundColor Green
Write-Host "BattlEye service: $(if ($battleyeService) { $battleyeService.State } else { 'Not found' })" -ForegroundColor Yellow
Write-Host "BattlEye driver:  $(if ($bedaisyService) { $bedaisyService.State } else { 'Not found' })" -ForegroundColor Yellow
Write-Host "STUN result:       $($stun.Assessment)" -ForegroundColor Yellow
Write-Host "UPnP advertised:   $($upnp.GatewayAdvertised)" -ForegroundColor Yellow
Write-Host "Route assessment:  $($traceIndicators.Assessment)" -ForegroundColor Yellow

if ($warnings.Count -gt 0) {
    Write-Host "`nFindings:" -ForegroundColor Yellow
    foreach ($warning in $warnings) { Write-Host " - $warning" }
}
else {
    Write-Host 'No automatic finding was generated. Review collection failures and compare baseline with a live kick capture before drawing conclusions.' -ForegroundColor Green
}


if ($IncludeEventScan) {
    Save-Evidence 'event-scan' {
        & "$PSScriptRoot\..\event-log-analyzer\Analyze-EventLogs.ps1" -ConfigPath "$PSScriptRoot\event-log-config.json" -OutputPath (Join-Path $script:RunPath 'events') -SkipElevation
    }
}
} catch { $script:Failures++; Write-Audit Failed Diagnostic $_.Exception.Message; throw }
finally { Complete-InvestigationRun }

