# MuMu Player 12 ADB APK Installer
# Installs any APK or XAPK directly into MuMu Player via high-speed ADB.
# Supports drag-and-drop onto this script, CLI argument, or GUI file picker.

param(
    [Parameter(Position=0)]
    [string]$ApkPath,
    [int]$VmIndex = 1,
    [string]$MumuInstallDir = "D:\Program Files\Netease\MuMu Player 12"
)

$ErrorActionPreference = "Stop"

Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "         MuMu Player 12 - High-Speed ADB Installer        " -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

$mumuCli = Join-Path $MumuInstallDir "nx_main\mumu-cli.exe"
$adbPath = Join-Path $MumuInstallDir "nx_device\15.0\shell\adb.exe"

if (-not (Test-Path $adbPath)) {
    $adbPath = Join-Path $MumuInstallDir "shell\adb.exe"
}

# If no APK path was provided, open a Windows File Picker dialog
if (-not $ApkPath -or -not (Test-Path $ApkPath)) {
    Write-Host "[*] No APK specified. Opening file browser..." -ForegroundColor Yellow
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "Android Package (*.apk)|*.apk|All Files (*.*)|*.*"
    $dialog.Title = "Select APK to Install in MuMu Player"
    $dialog.InitialDirectory = [Environment]::GetFolderPath("UserProfile") + "\Downloads"
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $ApkPath = $dialog.FileName
    } else {
        Write-Host "[-] Installation cancelled by user." -ForegroundColor Red
        exit 0
    }
}

Write-Host "[+] Target APK: $ApkPath" -ForegroundColor Green
$fileItem = Get-Item $ApkPath
$fileSizeMB = [math]::Round($fileItem.Length / 1MB, 2)
Write-Host "    Size: $fileSizeMB MB" -ForegroundColor Gray

# Resolve VM Device (Bridged vs NAT)
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
} else {
    $port = 16416
    if (Test-Path $mumuCli) {
        try {
            $vmInfo = & $mumuCli info -v $VmIndex | ConvertFrom-Json
            if ($vmInfo.adb_port) { $port = $vmInfo.adb_port }
        } catch {}
    }
    $device = "127.0.0.1:$port"
}

Write-Host "[*] Connecting ADB to $device..." -ForegroundColor Yellow
& $adbPath connect $device | Out-Null

Write-Host "[*] Installing APK directly to Android 15..." -ForegroundColor Yellow
$installOutput = & $adbPath -s $device install -r -d -g "$ApkPath" 2>&1

if ($installOutput -like "*Success*") {
    Write-Host "=========================================================" -ForegroundColor Green
    Write-Host "  SUCCESS: APK installed successfully into MuMu Player!   " -ForegroundColor Green
    Write-Host "=========================================================" -ForegroundColor Green
} else {
    Write-Host "[-] Install Output: $installOutput" -ForegroundColor Red
}
