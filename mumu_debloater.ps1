# MuMu Player 12 (Android 15) Debloater & Adware Removal Script
# Target: MuMu Player 6.0+ (MuMu 12) with Android 15 engine
# Supports both NAT Mode and Bridged Mode automatically

param(
    [int]$VmIndex = 1,
    [string]$MumuInstallDir = "D:\Program Files\Netease\MuMu Player 12"
)

$ErrorActionPreference = "Stop"

Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  MuMu Player 12 (Android 15) ADB Debloater & Adware Tool " -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

$mumuCli = Join-Path $MumuInstallDir "nx_main\mumu-cli.exe"
$adbPath = Join-Path $MumuInstallDir "nx_device\15.0\shell\adb.exe"

if (-not (Test-Path $mumuCli)) {
    Write-Error "mumu-cli.exe not found at $mumuCli"
}
if (-not (Test-Path $adbPath)) {
    $adbPath = Join-Path $MumuInstallDir "shell\adb.exe"
}

Write-Host "[1/6] Querying VM $VmIndex status via mumu-cli..." -ForegroundColor Yellow
$vmJson = & $mumuCli info -v $VmIndex
$vmInfo = $vmJson | ConvertFrom-Json

if ($vmInfo.is_android_started -ne $true) {
    Write-Host "VM $VmIndex is not running. Launching VM $VmIndex..." -ForegroundColor Yellow
    & $mumuCli control -v $VmIndex launch
    for ($i = 0; $i -lt 25; $i++) {
        Start-Sleep -Seconds 3
        $vmJson = & $mumuCli info -v $VmIndex
        $vmInfo = $vmJson | ConvertFrom-Json
        if ($vmInfo.is_android_started -eq $true) {
            Write-Host "VM $VmIndex successfully started." -ForegroundColor Green
            break
        }
    }
}

# Auto-detect Network Mode: Bridged vs NAT
Write-Host "[2/6] Detecting network mode and resolving target device..." -ForegroundColor Yellow

$macFilePath = Join-Path $MumuInstallDir "vms\MuMuPlayer-15.0-$VmIndex\macaddress"
$customerConfigPath = Join-Path $MumuInstallDir "vms\MuMuPlayer-15.0-$VmIndex\configs\customer_config.json"
$isBridgeMode = $false
$vmMac = $null

if (Test-Path $customerConfigPath) {
    try {
        $custJson = Get-Content $customerConfigPath -Raw | ConvertFrom-Json
        if ($custJson.customer.network_bridge_opened -eq "true" -or $custJson.customer.network_bridge_opened -eq $true) {
            $isBridgeMode = $true
        }
    } catch {}
}

if (Test-Path $macFilePath) {
    $rawMac = (Get-Content $macFilePath -Raw).Trim()
    if ($rawMac) {
        $vmMac = ($rawMac -replace '..(?!$)', '$0-')
    }
}

$bridgedIp = $null
if ($isBridgeMode -and $vmMac) {
    # Check known neighbor or ping broadcast
    $bridgedNeighbor = Get-NetNeighbor -LinkLayerAddress $vmMac -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike "169.254*" -and $_.AddressFamily -eq "IPv4" } | Select-Object -First 1
    if (-not $bridgedNeighbor) {
        try {
            $localIp = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254*" } | Select-Object -First 1).IPAddress
            $subnetPrefix = if ($localIp) { $localIp.Substring(0, $localIp.LastIndexOf('.')) } else { "192.168.1" }
            1..254 | ForEach-Object -Parallel {
                $p = New-Object System.Net.NetworkInformation.Ping
                try { $p.Send("$using:subnetPrefix.$_", 150) | Out-Null } catch {}
            } -ThrottleLimit 50
        } catch {}
        $bridgedNeighbor = Get-NetNeighbor -LinkLayerAddress $vmMac -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike "169.254*" -and $_.AddressFamily -eq "IPv4" } | Select-Object -First 1
    }
    if ($bridgedNeighbor) {
        $bridgedIp = $bridgedNeighbor.IPAddress
    }
}

if ($bridgedIp) {
    $device = "$($bridgedIp):5555"
    Write-Host "  [+] Bridged mode detected (MAC: $vmMac). Target: $device" -ForegroundColor Green
} else {
    $port = $vmInfo.adb_port
    if (-not $port) { $port = 16416 }
    $device = "127.0.0.1:$port"
    Write-Host "  [+] NAT mode active (or fallback). Target: $device" -ForegroundColor Green
}

Write-Host "  [*] Connecting ADB to $device..." -ForegroundColor Gray
& $adbPath connect $device | Out-Null
& $adbPath -s $device root | Out-Null
Start-Sleep -Seconds 2
& $adbPath connect $device | Out-Null

Write-Host "[3/6] Removing Adware and Disabling Bloatware Packages..." -ForegroundColor Yellow
$packagesToUninstall = @(
    "com.nemu.googleinstaller"
)

foreach ($pkg in $packagesToUninstall) {
    Write-Host "  [-] Uninstalling $pkg..." -ForegroundColor Gray
    & $adbPath -s $device shell "pm uninstall $pkg 2>/dev/null; pm uninstall -k --user 0 $pkg 2>/dev/null" | Out-Null
}

# Disable all NetEase adware, store, SDK, and telemetry packages.
# Note: com.netease.mumu.cloner and advertising.id.ccpa.gdpr are preserved per user configuration.
# APK installations will be performed directly via ADB.
$packagesToDisable = @(
    "com.mumu.store",
    "com.mumu.shared.sdk",
    "com.mumu.acc",
    "com.nemu.oaidmanager",
    "com.nemu.nlp",
    "com.sohu.inputmethod.sogou.chuizi",
    "com.android.chromium",
    "com.android.camera2"
)

foreach ($pkg in $packagesToDisable) {
    Write-Host "  [-] Disabling $pkg..." -ForegroundColor Gray
    & $adbPath -s $device shell "am force-stop $pkg 2>/dev/null; pm disable-user --user 0 $pkg 2>/dev/null" | Out-Null
}

Write-Host "[4/6] Ensuring HeliBoard Keyboard is configured..." -ForegroundColor Yellow
$imeStatus = & $adbPath -s $device shell "settings get secure default_input_method"
if ($imeStatus -like "*helium314.keyboard*") {
    Write-Host "  [+] HeliBoard is active default IME." -ForegroundColor Green
} else {
    Write-Host "  [*] Enabling HeliBoard..." -ForegroundColor Yellow
    & $adbPath -s $device shell "ime enable helium314.keyboard/.latin.LatinIME; ime set helium314.keyboard/.latin.LatinIME" | Out-Null
}

Write-Host "[5/6] Updating Ad & Telemetry Blocking in /system/etc/hosts..." -ForegroundColor Yellow
$hosts = @"
127.0.0.1       localhost
::1             ip6-localhost

# NetEase MuMu Telemetry & Ad Blocking
0.0.0.0 sentry.netease.com
0.0.0.0 zsos-api.ntes53.netease.com
0.0.0.0 sigma-agentlog-a11xxna.proxima.nie.easebar.com
0.0.0.0 fcount-api.webapp.easebar.com
0.0.0.0 mumu-apk.fp.ps.netease.com
0.0.0.0 active.mumu.163.com
0.0.0.0 stat.nie.netease.com
0.0.0.0 gvod.nie.netease.com
0.0.0.0 adl.netease.com
0.0.0.0 crash.nie.netease.com
0.0.0.0 api.mumu.netease.com
0.0.0.0 api-pro.mumu.163.com
0.0.0.0 api.mumu.nie.netease.com
0.0.0.0 event.sc.gearupportal.com
0.0.0.0 oaid.wps.cn
0.0.0.0 log.immomo.com
0.0.0.0 track.tenjin.io
0.0.0.0 adash.man.aliyuncs.com
0.0.0.0 sensorsdata.analytics.netease.com
"@

$tmpHosts = [System.IO.Path]::GetTempFileName()
$hosts.Replace("`r`n", "`n") | Set-Content -Path $tmpHosts -NoNewline -Encoding utf8
& $adbPath -s $device push $tmpHosts /data/local/tmp/hosts | Out-Null
& $adbPath -s $device shell "cp /data/local/tmp/hosts /system/etc/hosts && chmod 644 /system/etc/hosts" | Out-Null
Remove-Item $tmpHosts -Force -ErrorAction SilentlyContinue

Write-Host "[6/6] Cleaning Windows Host Ad Cache & Reporting Configs..." -ForegroundColor Yellow
$adsDir = "$env:APPDATA\Netease\MuMuPlayer\data\ProgramAds"
if (Test-Path "$adsDir\advertisement") {
    Remove-Item "$adsDir\advertisement\*" -Force -Recurse -ErrorAction SilentlyContinue
}
if (Test-Path "$adsDir\programAds.json") {
    Set-ItemProperty "$adsDir\programAds.json" -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
    "{}" | Set-Content "$adsDir\programAds.json" -Force
    Set-ItemProperty "$adsDir\programAds.json" -Name IsReadOnly -Value $true -ErrorAction SilentlyContinue
}

$reportConfig = "$env:APPDATA\Netease\MuMuPlayer\configs\report_app_data_config.json"
if (Test-Path $reportConfig) {
    Set-ItemProperty $reportConfig -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
    "{}" | Set-Content $reportConfig -Force
    Set-ItemProperty $reportConfig -Name IsReadOnly -Value $true -ErrorAction SilentlyContinue
}

Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  Debloating & Adware Removal Completed Successfully!     " -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
