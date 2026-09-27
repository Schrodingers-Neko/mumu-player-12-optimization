#requires -Version 5.1
# Dependency-free regression suite. Never connects to a real emulator.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'mumu_common.ps1')
$hostExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('mumu-regression-' + [guid]::NewGuid().ToString('N'))
$savedPath = $env:PATH
$savedAppData = $env:APPDATA
$savedTestEnv = @{}
foreach ($key in @('MUMU_TEST_ROOT', 'MUMU_TEST_SCENARIO', 'MUMU_TEST_DEVICE', 'MUMU_TEST_WRAPPER_EXIT')) { $savedTestEnv[$key] = [Environment]::GetEnvironmentVariable($key) }
$script:passed = 0
$script:failures = @()

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $message = $null
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    if ($null -eq $message -or $message -notmatch $Pattern) { throw "Expected error matching '$Pattern'; received '$message'." }
}
function Run-Test {
    param([string]$Name, [scriptblock]$Action)
    try { & $Action; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failures += "$Name : $($_.Exception.Message)"; Write-Host "FAIL $Name : $($_.Exception.Message)" -ForegroundColor Red }
}
function New-TestCase {
    param([string]$Scenario = 'success')
    $caseDir = Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
    $caseRepo = Join-Path $caseDir 'repo'
    $installDir = Join-Path $caseDir 'install'
    foreach ($dir in @($caseDir, $caseRepo, (Join-Path $installDir 'nx_main'), (Join-Path $installDir 'nx_device\15.0\shell'), (Join-Path $installDir 'vms\MuMuPlayer-15.0-1\configs'))) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    foreach ($name in @('mumu_common.ps1', 'install_apk.ps1', 'install_apk.bat', 'replace_lawnchair.ps1', 'restore_lawnchair.ps1', 'mumu_debloater.ps1', 'platform.x509.pem', 'hosts')) { Copy-Item -LiteralPath (Join-Path $repo $name) -Destination $caseRepo }
    Copy-Item -LiteralPath $fakeExe -Destination (Join-Path $installDir 'nx_main\mumu-cli.exe')
    Copy-Item -LiteralPath $fakeExe -Destination (Join-Path $installDir 'nx_device\15.0\shell\adb.exe')
    [IO.File]::WriteAllText((Join-Path $installDir 'vms\MuMuPlayer-15.0-1\configs\customer_config.json'), '{"customer":{"network_bridge_opened":false}}')
    foreach ($name in @('app.apk', 'Lawnchair.15.0.0.Beta.3.0-aligned-signed.apk', 'uber-apk-signer.jar')) { [IO.File]::WriteAllText((Join-Path $caseRepo $name), 'replacement fixture') }
    $factory = Join-Path $caseDir 'remote\system\priv-app\Lawnchair\Lawnchair.apk'
    New-Item -ItemType Directory -Path (Split-Path $factory -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($factory, 'factory fixture')
    $env:MUMU_TEST_ROOT = $caseDir
    $env:MUMU_TEST_SCENARIO = $Scenario
    $env:MUMU_TEST_DEVICE = '127.0.0.1:23456'
    $env:APPDATA = Join-Path $caseDir 'appdata'
    return [pscustomobject]@{ Root = $caseDir; Repo = $caseRepo; Install = $installDir; App = (Join-Path $caseRepo 'app.apk'); Adb = (Join-Path $installDir 'nx_device\15.0\shell\adb.exe') }
}
function Read-Calls { param($Case) if (Test-Path -LiteralPath (Join-Path $Case.Root 'calls.txt')) { Get-Content -LiteralPath (Join-Path $Case.Root 'calls.txt') -Raw } else { '' } }
function Invoke-EntryPoint {
    param($Case, [string]$Script, [string[]]$Extra = @())
    Invoke-MumuNative $hostExe (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Case.Repo $Script), '-MumuInstallDir', $Case.Install) + $Extra) -AllowFailure -TimeoutSeconds 30
}
function Add-TestBackup {
    param($Case)
    $backup = Join-Path $Case.Repo 'backup\vm-1'
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $backup 'Lawnchair_mumu_original.apk'), 'factory fixture')
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $fakeBin = Join-Path $testRoot 'bin'
    New-Item -ItemType Directory -Path $fakeBin | Out-Null
    $fakeExe = Join-Path $fakeBin 'native.exe'
    $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Invoke-MumuNative $windowsPowerShell @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'build_fake.ps1'), '-OutputPath', $fakeExe) | Out-Null
    foreach ($name in @('java.exe', 'pwsh.exe', 'powershell.exe')) { Copy-Item -LiteralPath $fakeExe -Destination (Join-Path $fakeBin $name) }
    $env:PATH = "$fakeBin;$savedPath"

    Run-Test 'all PowerShell sources parse in this host' {
        foreach ($file in @(Get-ChildItem -LiteralPath $repo -Filter *.ps1) + @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.ps1)) {
            $tokens=$null; $errors=$null
            $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            Assert-True ($errors.Count -eq 0) "$($file.Name): $($errors.Message -join '; ')"
        }
    }
    Run-Test 'native argument quoting preserves shell characters and trailing slashes' {
        $case = New-TestCase
        $arguments = @('a & b! [x].apk', 'embedded "quote"', 'C:\space folder\', '')
        Invoke-MumuNative $fakeExe $arguments | Out-Null
        for ($i=0; $i -lt $arguments.Count; $i++) { Assert-True ([IO.File]::ReadAllText((Join-Path $case.Root "arg$i.txt")) -ceq $arguments[$i]) "Argument $i changed." }
    }
    Run-Test 'native failures preserve stdout, stderr and exit status' {
        $case = New-TestCase
        $result = Invoke-MumuNative $fakeExe @('fail') -AllowFailure
        Assert-True ($result.ExitCode -eq 7 -and $result.StdOut -match 'stdout diagnostic' -and $result.StdErr -match 'stderr diagnostic') 'Diagnostics were lost.'
        Assert-Throws { Invoke-MumuNative $fakeExe @('fail') } 'exit 7'
    }
    Run-Test 'large native stdout and stderr do not deadlock' {
        $case = New-TestCase
        $result = Invoke-MumuNative $fakeExe @('streams')
        Assert-True ($result.StdOut.Length -eq 100000 -and $result.StdErr.Length -eq 100000) 'Stream output truncated.'
    }
    Run-Test 'native processes have a bounded timeout' {
        $case = New-TestCase
        Assert-Throws { Invoke-MumuNative $fakeExe @('sleep') -TimeoutSeconds 1 } 'timed out'
        Assert-True ((Invoke-MumuNative $fakeExe @('sleep') -TimeoutSeconds 1 -AllowFailure).ExitCode -eq 124) 'Expected timeout cannot be retried.'
    }
    Run-Test 'NAT uses the queried port and root is verified' {
        $case = New-TestCase
        $connection = New-MumuConnection $case.Install 1 -Root
        Assert-True ($connection.Device -eq '127.0.0.1:23456') 'Port was guessed.'
        Assert-True ((Read-Calls $case) -match 'id -u') 'Root was not verified.'
    }
    foreach ($scenario in @('wrong-vm', 'missing-port', 'invalid-json', 'cli-failure', 'offline', 'stopped')) {
        Run-Test "connection refuses $scenario before mutation" {
            $case = New-TestCase $scenario
            $result = Invoke-EntryPoint $case 'install_apk.ps1' @('-ApkPath', $case.App)
            Assert-True ($result.ExitCode -eq 1) 'Connection error did not fail.'
            Assert-True ((Read-Calls $case) -notmatch '\tinstall\t') 'Installation happened after connection failure.'
        }
    }
    Run-Test 'missing executable aborts before CLI/ADB access' {
        $case = New-TestCase
        Remove-Item -LiteralPath $case.Adb
        Assert-Throws { New-MumuConnection $case.Install 1 } 'Executable not found'
        Assert-True ((Read-Calls $case) -eq '') 'A process was started despite missing ADB.'
    }
    Run-Test 'debloater launch permission starts only the requested VM' {
        $case = New-TestCase 'stopped'
        $connection = New-MumuConnection $case.Install 1 -Launch
        Assert-True ((Read-Calls $case) -match 'control\t-v\t1\tlaunch') 'VM was not launched correctly.'
    }
    Run-Test 'VM startup timeout prevents ADB access' {
        $case = New-TestCase 'start-timeout'
        Assert-Throws { New-MumuConnection $case.Install 1 -Launch -StartupTimeoutSeconds 1 } 'did not start'
        Assert-True ((Read-Calls $case) -notmatch 'adb\t') 'ADB accessed before startup.'
    }
    Run-Test 'non-root device aborts privileged work' {
        $case = New-TestCase 'no-root'
        Assert-Throws { New-MumuConnection $case.Install 1 -Root -RootTimeoutSeconds 1 } 'Root access'
    }
    Run-Test 'bridge discovery is adapter-specific and works without a cached neighbor' {
        $case = New-TestCase
        $script:probes = 0
        function Get-NetAdapter { [pscustomobject]@{ InterfaceDescription='configured'; ifIndex=42; Status='Up' }; [pscustomobject]@{ InterfaceDescription='other'; ifIndex=99; Status='Up' } }
        function Get-NetIPAddress { param($InterfaceIndex,$AddressFamily,$ErrorAction) Assert-True ($InterfaceIndex -eq 42) 'Wrong adapter scanned.'; [pscustomobject]@{ IPAddress='192.0.2.2'; PrefixLength=29; AddressState='Preferred' } }
        function Get-NetNeighbor { param($InterfaceIndex,$AddressFamily,$ErrorAction) Assert-True ($InterfaceIndex -eq 42) 'Wrong neighbor table.'; if ($script:probes -gt 0) { [pscustomobject]@{ LinkLayerAddress='00-11-22-33-44-55'; IPAddress='192.0.2.3'; State='Reachable' } } }
        function New-Object {
            param([string]$TypeName)
            if ($TypeName -ne 'Net.NetworkInformation.Ping') { return Microsoft.PowerShell.Utility\New-Object $TypeName }
            $ping = [pscustomobject]@{}
            $ping | Add-Member ScriptMethod SendPingAsync { param($Ip,$Timeout) $script:probes++; [Threading.Tasks.Task]::Delay(1) }
            $ping | Add-Member ScriptMethod Dispose { }
            return $ping
        }
        $ip = Find-MumuBridgeIp 'configured' '00-11-22-33-44-55' -TimeoutSeconds 1
        Assert-True ($ip -eq '192.0.2.3' -and $script:probes -gt 0) 'Discovery failed.'
    }
    Run-Test 'unresolved bridge never falls back to NAT' {
        $case = New-TestCase
        [IO.File]::WriteAllText((Join-Path $case.Install 'vms\MuMuPlayer-15.0-1\configs\customer_config.json'), '{"customer":{"network_bridge_opened":true,"network_current_bridge_card":"configured"}}')
        [IO.File]::WriteAllText((Join-Path $case.Install 'vms\MuMuPlayer-15.0-1\macaddress'), '001122334455')
        function Find-MumuBridgeIp { throw 'Bridge discovery failed. NAT fallback is disabled.' }
        Assert-Throws { New-MumuConnection $case.Install 1 } 'NAT fallback is disabled'
        Assert-True ((Read-Calls $case) -notmatch 'adb\t') 'NAT connection attempted.'
    }
    Run-Test 'ambiguous bridge adapter is rejected' {
        function Get-NetAdapter { 1..2 | ForEach-Object { [pscustomobject]@{ InterfaceDescription='configured'; ifIndex=$_; Status='Up' } } }
        Assert-Throws { Find-MumuBridgeIp 'configured' '00-11-22-33-44-55' } 'uniquely resolve'
    }
    Run-Test 'invalid signature aborts before connecting to MuMu' {
        $case = New-TestCase 'bad-signature'
        $result = Invoke-EntryPoint $case 'replace_lawnchair.ps1'
        Assert-True ($result.ExitCode -eq 1 -and $result.Output -match 'Signature mismatch') 'Signature was not rejected.'
        Assert-True ((Read-Calls $case) -notmatch 'mumu-cli\t|adb\t') 'Emulator accessed before signature verification.'
    }
    Run-Test 'missing signed APK never falls back to original filename' {
        $case = New-TestCase
        Remove-Item -LiteralPath (Join-Path $case.Repo 'Lawnchair.15.0.0.Beta.3.0-aligned-signed.apk')
        [IO.File]::WriteAllText((Join-Path $case.Repo 'Lawnchair.15.0.0.Beta.3.0.apk'), 'original filename')
        Assert-True ((Invoke-EntryPoint $case 'replace_lawnchair.ps1').ExitCode -eq 1) 'Unsigned filename fallback occurred.'
        Assert-True ((Read-Calls $case) -eq '') 'Process started before prerequisite validation.'
    }
    Run-Test 'missing signer prevents emulator access' {
        $case = New-TestCase
        Remove-Item -LiteralPath (Join-Path $case.Repo 'uber-apk-signer.jar')
        Assert-True ((Invoke-EntryPoint $case 'replace_lawnchair.ps1').ExitCode -eq 1) 'Missing signer ignored.'
        Assert-True ((Read-Calls $case) -eq '') 'Emulator accessed without signer.'
    }
    Run-Test 'missing Java prevents emulator access' {
        $case = New-TestCase
        $previousPath = $env:PATH
        try {
            $env:PATH = Join-Path $env:WINDIR 'System32'
            Assert-True ((Invoke-EntryPoint $case 'replace_lawnchair.ps1').ExitCode -eq 1) 'Missing Java ignored.'
            Assert-True ((Read-Calls $case) -eq '') 'Emulator accessed without Java.'
        } finally { $env:PATH = $previousPath }
    }
    foreach ($scenario in @('pull-failure', 'empty-backup', 'push-failure', 'hash-mismatch', 'mount-failure', 'copy-failure')) {
        Run-Test "launcher $scenario prevents restart and success" {
            $case = New-TestCase $scenario
            $result = Invoke-EntryPoint $case 'replace_lawnchair.ps1'
            $calls = Read-Calls $case
            Assert-True ($result.ExitCode -eq 1) 'Failed launcher operation reported success.'
            Assert-True ($calls -notmatch 'setprop ctl.restart|cat > /data/adb/post-fs-data.d/00_lawnchair.sh') 'Failed deployment was persisted or restarted.'
            if ($scenario -in @('pull-failure','empty-backup')) { Assert-True ($calls -notmatch '\tpush\t') 'Upload happened after backup failure.' }
            if ($scenario -in @('pull-failure','empty-backup','push-failure','hash-mismatch')) { Assert-True ($calls -notmatch 'mount -o bind') 'Mount happened after a prerequisite failure.' }
        }
    }
    Run-Test 'successful launcher install verifies checksum, mount and HOME role' {
        $case = New-TestCase
        $result = Invoke-EntryPoint $case 'replace_lawnchair.ps1'
        Assert-True ($result.ExitCode -eq 0 -and $result.Output -match 'HOME role verified') $result.Output
        $calls = Read-Calls $case
        Assert-True ($calls -match '--onlyVerify' -and $calls -match 'sha256sum' -and $calls -match 'get-role-holders' -and $calls -match 'pidof app.lawnchair') 'Required verification absent.'
        Assert-True (Test-Path -LiteralPath (Join-Path $case.Repo 'backup\vm-1\Lawnchair_mumu_original.apk')) 'Per-VM backup missing.'
    }
    Run-Test 'restoration without factory or backup preserves hook and module' {
        $case = New-TestCase
        Remove-Item -LiteralPath (Join-Path $case.Root 'remote\system\priv-app\Lawnchair\Lawnchair.apk')
        [IO.File]::WriteAllText((Join-Path $case.Root 'mounted'), '1')
        $result = Invoke-EntryPoint $case 'restore_lawnchair.ps1'
        Assert-True ($result.ExitCode -eq 1) 'Restore proceeded without source.'
        Assert-True ((Read-Calls $case) -notmatch 'rm -f /data/adb/post-fs-data.d|rm -rf /data/adb/modules|setprop ctl.restart|pm clear') 'Destructive restore operations occurred.'
    }
    Run-Test 'failed unmount preserves module and prevents restart' {
        $case = New-TestCase 'unmount-failure'
        [IO.File]::WriteAllText((Join-Path $case.Root 'mounted'), '1')
        $result = Invoke-EntryPoint $case 'restore_lawnchair.ps1'
        Assert-True ($result.ExitCode -eq 1) 'Unmount failure ignored.'
        Assert-True ((Read-Calls $case) -notmatch 'rm -rf /data/adb/modules|setprop ctl.restart|pm clear') 'Restore continued after unmount failure.'
    }
    Run-Test 'restoration from backup verifies bytes before deleting module' {
        $case = New-TestCase
        Add-TestBackup $case
        Remove-Item -LiteralPath (Join-Path $case.Root 'remote\system\priv-app\Lawnchair\Lawnchair.apk')
        [IO.File]::WriteAllText((Join-Path $case.Root 'mounted'), '1')
        $result = Invoke-EntryPoint $case 'restore_lawnchair.ps1'
        Assert-True ($result.ExitCode -eq 0 -and $result.Output -match 'HOME role verified') $result.Output
        $calls = Read-Calls $case
        Assert-True ($calls.IndexOf("umount '/system/priv-app/Lawnchair/Lawnchair.apk'") -lt $calls.IndexOf('rm -rf /data/adb/modules/lawnchair')) 'Module removed before unmount.'
    }
    Run-Test 'failed backup restoration does not clear state or restart' {
        $case = New-TestCase 'copy-failure'
        Add-TestBackup $case
        Remove-Item -LiteralPath (Join-Path $case.Root 'remote\system\priv-app\Lawnchair\Lawnchair.apk')
        Assert-True ((Invoke-EntryPoint $case 'restore_lawnchair.ps1').ExitCode -eq 1) 'Copy failure ignored.'
        Assert-True ((Read-Calls $case) -notmatch 'setprop ctl.restart|pm clear|rm -rf /data/adb/modules') 'Restoration continued after failed copy.'
    }
    foreach ($scenario in @('ready-timeout','launcher-timeout','wrong-role','restart-ignored')) {
        Run-Test "restart verification rejects $scenario" {
            $case = New-TestCase $scenario
            $connection = [pscustomobject]@{ AdbPath=$case.Adb; Device='127.0.0.1:23456' }
            Assert-Throws { Complete-MumuLauncherRestart $connection -ReadyTimeoutSeconds 1 -LauncherTimeoutSeconds 1 } 'did not'
        }
    }
    foreach ($scenario in @('missing-ime','ime-failure','ime-unverified')) {
        Run-Test "HeliBoard $scenario prevents all debloating" {
            $case = New-TestCase $scenario
            $adDir = Join-Path $env:APPDATA 'Netease\MuMuPlayer\data\ProgramAds'
            New-Item -ItemType Directory -Path $adDir -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $adDir 'programAds.json'), 'untouched')
            $result = Invoke-EntryPoint $case 'mumu_debloater.ps1'
            Assert-True ($result.ExitCode -eq 1) 'Keyboard failure ignored.'
            Assert-True ((Read-Calls $case) -notmatch 'pm disable-user|pm uninstall|\tpush\t|cp .*hosts') 'Debloating occurred before keyboard readiness.'
            Assert-True ([IO.File]::ReadAllText((Join-Path $adDir 'programAds.json')) -eq 'untouched') 'Host cleanup ran before keyboard readiness.'
        }
    }
    Run-Test 'successful debloating verifies state and supports reruns' {
        $case = New-TestCase
        $adDir = Join-Path $env:APPDATA 'Netease\MuMuPlayer\data\ProgramAds'
        New-Item -ItemType Directory -Path $adDir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $adDir 'programAds.json'), 'old')
        $first = Invoke-EntryPoint $case 'mumu_debloater.ps1'
        Assert-True ($first.ExitCode -eq 0) $first.Output
        $calls = Read-Calls $case
        Assert-True ($calls.IndexOf('settings get secure default_input_method') -lt $calls.IndexOf('pm disable-user')) 'Keyboard validation ordered incorrectly.'
        $disableCount = ([regex]::Matches($calls, 'pm disable-user')).Count
        $second = Invoke-EntryPoint $case 'mumu_debloater.ps1'
        Assert-True ($second.ExitCode -eq 0 -and ([regex]::Matches((Read-Calls $case), 'pm disable-user')).Count -eq $disableCount) 'Rerun repeated package mutations.'
        Assert-True ((Get-Item -LiteralPath (Join-Path $adDir 'programAds.json')).IsReadOnly) 'Host config not locked.'
    }
    foreach ($scenario in @('success','install-failure','install-no-success')) {
        Run-Test "APK entry point propagates $scenario" {
            $case = New-TestCase $scenario
            $result = Invoke-EntryPoint $case 'install_apk.ps1' @('-ApkPath', $case.App)
            $expected = if ($scenario -eq 'success') { 0 } else { 1 }
            Assert-True ($result.ExitCode -eq $expected) 'Wrong installer exit status.'
            Assert-True ([IO.File]::ReadAllText((Join-Path $case.Root 'installed-path.txt')) -eq $case.App) 'APK argument changed.'
        }
    }
    foreach ($name in @('space name.apk','a&echo INJECTED&rem .apk','bang!name.apk')) {
        foreach ($exitCode in @(0,1)) {
            Run-Test "batch preserves '$name' and exit $exitCode" {
                $case = New-TestCase
                $path = Join-Path $case.Repo $name
                [IO.File]::WriteAllText($path, 'apk')
                $env:MUMU_TEST_WRAPPER_EXIT = [string]$exitCode
                # Feed pause from redirected stdin, and call an exact copy of the real wrapper.
                $process = New-Object Diagnostics.Process
                $process.StartInfo = New-Object Diagnostics.ProcessStartInfo
                $process.StartInfo.FileName = $env:ComSpec
                $process.StartInfo.Arguments = '/d /v:off /c ""' + (Join-Path $case.Repo 'install_apk.bat') + '" "' + $path + '""'
                $process.StartInfo.UseShellExecute = $false
                $process.StartInfo.CreateNoWindow = $true
                $process.StartInfo.RedirectStandardInput = $true
                $process.StartInfo.RedirectStandardOutput = $true
                $process.StartInfo.RedirectStandardError = $true
                try {
                    [void]$process.Start(); $outTask=$process.StandardOutput.ReadToEndAsync(); $errTask=$process.StandardError.ReadToEndAsync()
                    $process.StandardInput.WriteLine('x'); $process.StandardInput.Close()
                    Assert-True ($process.WaitForExit(10000)) 'Wrapper timed out.'
                    $output = $outTask.GetAwaiter().GetResult() + $errTask.GetAwaiter().GetResult()
                    Assert-True ($process.ExitCode -eq $exitCode) "Batch lost exit status: $output"
                    Assert-True ($output -notmatch 'INJECTED') 'Filename executed as a command.'
                    Assert-True ([IO.File]::ReadAllText((Join-Path $case.Root 'wrapper-input.txt')) -ceq $path) 'Filename altered by cmd.exe.'
                } finally { if (-not $process.HasExited) { $process.Kill() }; $process.Dispose() }
            }
        }
    }
    Write-Host "$script:passed checks passed under PowerShell $($PSVersionTable.PSVersion)."
    if ($script:failures.Count -gt 0) { throw ($script:failures -join "`n") }
} finally {
    $env:PATH = $savedPath
    $env:APPDATA = $savedAppData
    foreach ($key in $savedTestEnv.Keys) { [Environment]::SetEnvironmentVariable($key, $savedTestEnv[$key]) }
    # The tree contains only files created/copied by this test run.
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedRoot.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolvedRoot) -like 'mumu-regression-*') {
        if (Test-Path -LiteralPath $resolvedRoot) {
            Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File -Force | ForEach-Object { $_.IsReadOnly = $false }
            Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
        }
    }
}
