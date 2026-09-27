# Shared helpers. Keep compatible with Windows PowerShell 5.1 and PowerShell 7.

function ConvertTo-MumuNativeArgument {
    param([AllowEmptyString()][string]$Value)
    # Windows CommandLineToArgvW rules, including quotes and trailing backslashes.
    '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-MumuNative {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [string[]]$ArgumentList = @(),
        [switch]$AllowFailure,
        [ValidateRange(1,3600)][int]$TimeoutSeconds = 30
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Executable not found: $Path" }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $process.StartInfo.FileName = $Path
    $process.StartInfo.Arguments = ($ArgumentList | ForEach-Object { ConvertTo-MumuNativeArgument $_ }) -join ' '
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    try {
        if (-not $process.Start()) { throw "Could not start $Path" }
        # Read both streams concurrently; stderr must not become a PowerShell 5.1 error.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
        if ($timedOut) {
            $process.Kill()
            $process.WaitForExit()
            if (-not $AllowFailure) { throw "$([IO.Path]::GetFileName($Path)) timed out after $TimeoutSeconds seconds." }
        }
        $result = [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdoutTask.GetAwaiter().GetResult().Trim()
            StdErr = $stderrTask.GetAwaiter().GetResult().Trim()
        }
        if ($timedOut) { $result.ExitCode = 124; $result.StdErr += "`nTimed out after $TimeoutSeconds seconds." }
        $result | Add-Member -NotePropertyName Output -NotePropertyValue (($result.StdOut, $result.StdErr | Where-Object { $_ }) -join "`n")
        if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
            throw "$([IO.Path]::GetFileName($Path)) failed (exit $($result.ExitCode)): $($result.Output)"
        }
        return $result
    } finally { $process.Dispose() }
}

function Get-MumuVmInfo {
    param([string]$CliPath, [int]$VmIndex, [int]$TimeoutSeconds = 30)
    $result = Invoke-MumuNative $CliPath @('info', '-v', [string]$VmIndex) -TimeoutSeconds $TimeoutSeconds
    try { $info = $result.StdOut | ConvertFrom-Json -ErrorAction Stop } catch { throw "Invalid MuMu VM status: $($result.Output)" }
    if ($null -eq $info -or @($info).Count -ne 1 -or [string]$info.index -ne [string]$VmIndex -or $info.error_code -ne 0) {
        throw "MuMu did not return a valid identity for VM $VmIndex."
    }
    if ([string]$info.android_version -ne '15.0') { throw "VM $VmIndex must use Android 15.0." }
    return $info
}

function Get-MumuNeighborIp {
    param([int]$InterfaceIndex, [string]$Mac)
    $neighbors = @(Get-NetNeighbor -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object {
            ([string]$_.LinkLayerAddress -replace '[:-]', '').ToUpperInvariant() -eq ($Mac -replace '-', '') -and
            $_.State -notin @('Unreachable', 'Incomplete') -and $_.IPAddress -notmatch '^(127\.|169\.254\.|0\.)'
        } | Select-Object -ExpandProperty IPAddress -Unique)
    if ($neighbors.Count -gt 1) { throw "Multiple IP addresses match the VM MAC on the bridge adapter. Clear stale neighbor entries and retry." }
    if ($neighbors.Count -eq 1) { return $neighbors[0] }
}

function Find-MumuBridgeIp {
    param([string]$AdapterDescription, [string]$Mac, [int]$TimeoutSeconds = 30)
    $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.InterfaceDescription -eq $AdapterDescription -and $_.Status -eq 'Up' })
    if ($adapters.Count -ne 1) { throw "Cannot uniquely resolve configured bridge adapter '$AdapterDescription'." }
    $interfaceIndex = $adapters[0].ifIndex
    $knownIp = Get-MumuNeighborIp $interfaceIndex $Mac
    if ($knownIp) { return $knownIp }
    $addresses = @(Get-NetIPAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.|0\.)' -and $_.AddressState -eq 'Preferred' })
    if ($addresses.Count -eq 0) { throw "The configured bridge adapter has no usable IPv4 subnet." }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    foreach ($address in $addresses) {
        $octets = [Net.IPAddress]::Parse($address.IPAddress).GetAddressBytes()
        [long]$localNumber = ([long]$octets[0] * 16777216) + ([long]$octets[1] * 65536) + ([long]$octets[2] * 256) + $octets[3]
        [long]$size = [math]::Pow(2, 32 - [int]$address.PrefixLength)
        [long]$network = [math]::Floor($localNumber / $size) * $size
        # Probe outwards from the host on large subnets, rather than starting miles away.
        [long]$hostOffset = $localNumber - $network
        for ([long]$distance = 1; $distance -lt $size -and $watch.Elapsed.TotalSeconds -lt $TimeoutSeconds;) {
            $pending = @()
            try {
                for ($batch = 0; $batch -lt 25 -and $distance -lt $size -and $watch.Elapsed.TotalSeconds -lt $TimeoutSeconds; $batch++, $distance++) {
                    foreach ($candidate in @(($hostOffset + $distance), ($hostOffset - $distance))) {
                        if ($candidate -le 0 -or $candidate -ge ($size - 1)) { continue }
                        [long]$number = $network + $candidate
                        $ip = '{0}.{1}.{2}.{3}' -f ([math]::Floor($number / 16777216)), ([math]::Floor($number / 65536) % 256), ([math]::Floor($number / 256) % 256), ($number % 256)
                        $ping = New-Object Net.NetworkInformation.Ping
                        try { $pending += [pscustomobject]@{ Ping = $ping; Task = $ping.SendPingAsync($ip, 150) } }
                        catch { $ping.Dispose() }
                    }
                }
                foreach ($entry in $pending) {
                    $remaining = [math]::Max(0, [int](($TimeoutSeconds - $watch.Elapsed.TotalSeconds) * 1000))
                    try { [void]$entry.Task.Wait($remaining) } catch { } # A missed ping is not a discovery failure.
                }
            } finally { foreach ($entry in $pending) { $entry.Ping.Dispose() } }
            $knownIp = Get-MumuNeighborIp $interfaceIndex $Mac
            if ($knownIp) { return $knownIp }
        }
        if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
    }
    throw "Bridge discovery failed for MAC $Mac after probing the configured adapter. NAT fallback is disabled."
}

function New-MumuConnection {
    param([string]$MumuInstallDir, [ValidateRange(0,2147483647)][int]$VmIndex, [switch]$Launch, [switch]$Root, [int]$StartupTimeoutSeconds = 75, [int]$RootTimeoutSeconds = 15)
    $cli = Join-Path $MumuInstallDir 'nx_main\mumu-cli.exe'
    $adb = Join-Path $MumuInstallDir 'nx_device\15.0\shell\adb.exe'
    if (-not (Test-Path -LiteralPath $adb -PathType Leaf)) { $adb = Join-Path $MumuInstallDir 'shell\adb.exe' }
    foreach ($executable in @($cli, $adb)) {
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw "Executable not found: $executable" }
    }
    $info = Get-MumuVmInfo $cli $VmIndex
    if ([string]$info.is_android_started -ne 'True') {
        if (-not $Launch) { throw "VM $VmIndex is not running. Start it in MuMu first." }
        Invoke-MumuNative $cli @('control', '-v', [string]$VmIndex, 'launch') | Out-Null
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while ($watch.Elapsed.TotalSeconds -lt $StartupTimeoutSeconds) {
            Start-Sleep -Milliseconds 200
            $info = Get-MumuVmInfo $cli $VmIndex -TimeoutSeconds ([math]::Max(1, [math]::Ceiling($StartupTimeoutSeconds - $watch.Elapsed.TotalSeconds)))
            if ([string]$info.is_android_started -eq 'True') { break }
        }
        if ([string]$info.is_android_started -ne 'True') { throw "VM $VmIndex did not start within $StartupTimeoutSeconds seconds." }
    }
    $vmDir = Join-Path $MumuInstallDir "vms\MuMuPlayer-15.0-$VmIndex"
    $configPath = Join-Path $vmDir 'configs\customer_config.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw "VM network configuration not found: $configPath" }
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $bridgeValue = [string]$config.customer.network_bridge_opened
    if ($bridgeValue -notin @('True', 'False')) { throw 'VM network_bridge_opened must be true or false.' }
    if ($bridgeValue -eq 'True') {
        $rawMac = (Get-Content -LiteralPath (Join-Path $vmDir 'macaddress') -Raw).Trim() -replace '[:-]', ''
        if ($rawMac -notmatch '^[0-9a-fA-F]{12}$') { throw 'Invalid VM MAC address.' }
        $mac = ($rawMac.ToUpperInvariant() -replace '..(?!$)', '$0-')
        $ip = Find-MumuBridgeIp ([string]$config.customer.network_current_bridge_card) $mac
        $device = "${ip}:5555"
    } else {
        $port = 0
        if (-not [int]::TryParse([string]$info.adb_port, [ref]$port) -or $port -lt 1 -or $port -gt 65535) { throw "VM $VmIndex has no valid allocated ADB port." }
        $device = "127.0.0.1:$port"
    }
    $connection = [pscustomobject]@{ AdbPath = $adb; Device = $device; VmIndex = $VmIndex }
    Write-Host "Connecting to VM $VmIndex at $device..."
    Invoke-MumuNative $adb @('connect', $device) | Out-Null
    $state = Invoke-MumuNative $adb @('-s', $device, 'get-state')
    if ($state.StdOut -ne 'device') { throw "ADB target $device is not ready: $($state.Output)" }
    if ($Root) {
        Invoke-MumuNative $adb @('-s', $device, 'root') | Out-Null
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $uid = $null
        while ($watch.Elapsed.TotalSeconds -lt $RootTimeoutSeconds) {
            Invoke-MumuNative $adb @('connect', $device) -AllowFailure -TimeoutSeconds 2 | Out-Null
            $uid = Invoke-MumuShell $connection 'id -u' -AllowFailure -TimeoutSeconds 2
            if ($uid.ExitCode -eq 0 -and $uid.StdOut -eq '0') { break }
            Start-Sleep -Milliseconds 500
        }
        if ($null -eq $uid -or $uid.ExitCode -ne 0 -or $uid.StdOut -ne '0') { throw "Root access could not be verified on $device." }
    }
    return $connection
}

function Invoke-MumuShell {
    param($Connection, [string]$Command, [switch]$AllowFailure, [int]$TimeoutSeconds = 30)
    Invoke-MumuNative $Connection.AdbPath @('-s', $Connection.Device, 'shell', ($Command -replace "`r`n", "`n")) -AllowFailure:$AllowFailure -TimeoutSeconds $TimeoutSeconds
}

function Test-MumuFile {
    param($Connection, [string]$Path)
    $result = Invoke-MumuShell $Connection "if [ -s '$Path' ]; then echo PRESENT; else echo MISSING; fi"
    if ($result.StdOut -notin @('PRESENT', 'MISSING')) { throw "Could not check device file $Path." }
    return $result.StdOut -eq 'PRESENT'
}

function Test-MumuLauncherMount {
    param($Connection)
    $result = Invoke-MumuShell $Connection 'test -r /proc/mounts || exit 1; while read -r source destination rest; do if [ "$destination" = /system/priv-app/Lawnchair/Lawnchair.apk ]; then echo MOUNTED; exit 0; fi; done < /proc/mounts; echo UNMOUNTED'
    if ($result.StdOut -notin @('MOUNTED', 'UNMOUNTED')) { throw 'Could not inspect the launcher mount.' }
    return $result.StdOut -eq 'MOUNTED'
}

function Send-MumuVerifiedFile {
    param($Connection, [string]$LocalPath, [string]$RemotePath)
    $item = Get-Item -LiteralPath $LocalPath -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -eq 0) { throw "File is empty or invalid: $LocalPath" }
    Invoke-MumuNative $Connection.AdbPath @('-s', $Connection.Device, 'push', $item.FullName, $RemotePath) -TimeoutSeconds 300 | Out-Null
    $expected = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $actual = Invoke-MumuShell $Connection "sha256sum '$RemotePath'"
    if (($actual.StdOut -split '\s+')[0] -ne $expected) { throw "Uploaded file checksum mismatch: $RemotePath" }
}

function Get-MumuPlatformFingerprint {
    $pem = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'platform.x509.pem') -Raw -ErrorAction Stop
    $der = [Convert]::FromBase64String(($pem -replace '-----BEGIN CERTIFICATE-----|-----END CERTIFICATE-----|\s', ''))
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash($der)) -replace '-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Assert-MumuSignedApk {
    param([string]$SignedApkPath, [string]$SignerJarPath)
    foreach ($path in @($SignedApkPath, $SignerJarPath)) {
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($item.PSIsContainer -or $item.Length -eq 0) { throw "Missing or empty prerequisite: $path" }
    }
    if ([IO.Path]::GetExtension($SignedApkPath) -ne '.apk') { throw 'SignedApkPath must point to an .apk file.' }
    $java = (Get-Command java.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    Invoke-MumuNative $java @('-jar', (Get-Item -LiteralPath $SignerJarPath).FullName, '-a', (Get-Item -LiteralPath $SignedApkPath).FullName, '--onlyVerify', '--verifySha256', (Get-MumuPlatformFingerprint)) -TimeoutSeconds 90 | Out-Null
}

function Complete-MumuLauncherRestart {
    param($Connection, [int]$ReadyTimeoutSeconds = 90, [int]$LauncherTimeoutSeconds = 30)
    $previousServer = Invoke-MumuShell $Connection 'pidof system_server'
    if ($previousServer.StdOut -notmatch '^\d+$') { throw 'Could not identify the current Android runtime before restart.' }
    Invoke-MumuShell $Connection 'setprop ctl.restart zygote' | Out-Null
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $ready = $false
    while ($watch.Elapsed.TotalSeconds -lt $ReadyTimeoutSeconds) {
        Invoke-MumuNative $Connection.AdbPath @('connect', $Connection.Device) -AllowFailure -TimeoutSeconds 2 | Out-Null
        # boot_completed may stay 1 across a restart. Require a new system_server
        # PID so the old, still-running runtime cannot produce a false success.
        $server = Invoke-MumuShell $Connection 'pidof system_server' -AllowFailure -TimeoutSeconds 2
        $boot = Invoke-MumuShell $Connection 'getprop sys.boot_completed' -AllowFailure -TimeoutSeconds 2
        $package = Invoke-MumuShell $Connection 'cmd package path app.lawnchair' -AllowFailure -TimeoutSeconds 2
        if ($server.ExitCode -eq 0 -and $server.StdOut -match '^\d+$' -and $server.StdOut -ne $previousServer.StdOut -and $boot.ExitCode -eq 0 -and $boot.StdOut -eq '1' -and $package.ExitCode -eq 0 -and $package.StdOut -match '^package:') { $ready = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $ready) { throw "Android/PackageManager did not become ready within $ReadyTimeoutSeconds seconds." }
    Invoke-MumuShell $Connection 'cmd package install-existing --user 0 app.lawnchair' | Out-Null
    Invoke-MumuShell $Connection 'cmd role add-role-holder --user 0 android.app.role.HOME app.lawnchair' | Out-Null
    Invoke-MumuShell $Connection 'am start -a android.intent.action.MAIN -c android.intent.category.HOME' | Out-Null
    $watch.Restart()
    while ($watch.Elapsed.TotalSeconds -lt $LauncherTimeoutSeconds) {
        $role = Invoke-MumuShell $Connection 'cmd role get-role-holders --user 0 android.app.role.HOME' -AllowFailure -TimeoutSeconds 2
        $pidResult = Invoke-MumuShell $Connection 'pidof app.lawnchair' -AllowFailure -TimeoutSeconds 2
        if ($role.ExitCode -eq 0 -and ($role.StdOut -split '\s+') -contains 'app.lawnchair' -and $pidResult.ExitCode -eq 0 -and $pidResult.StdOut -match '^\d+(\s+\d+)*$') { return }
        Start-Sleep -Milliseconds 500
    }
    throw "Lawnchair did not acquire the HOME role and start within $LauncherTimeoutSeconds seconds."
}

function Enable-MumuHeliBoard {
    param($Connection)
    $ime = 'helium314.keyboard/.latin.LatinIME'
    $installed = Invoke-MumuShell $Connection 'ime list -a -s'
    if (($installed.StdOut -split '\s+') -notcontains $ime) { throw 'Install HeliBoard before debloating. Sogou has been left enabled.' }
    Invoke-MumuShell $Connection "ime enable $ime" | Out-Null
    Invoke-MumuShell $Connection "ime set $ime" | Out-Null
    $selected = Invoke-MumuShell $Connection 'settings get secure default_input_method'
    $enabled = Invoke-MumuShell $Connection 'ime list -s'
    if ($selected.StdOut -ne $ime -or ($enabled.StdOut -split '\s+') -notcontains $ime) { throw 'HeliBoard activation could not be verified. Sogou has been left enabled.' }
}

function Test-MumuPackage {
    param($Connection, [string]$Package, [switch]$Disabled)
    $command = 'pm list packages --user 0'
    if ($Disabled) { $command += ' -d' }
    $result = Invoke-MumuShell $Connection "$command $Package"
    return ($result.StdOut -split '\s+') -contains "package:$Package"
}
