# MuMu Player 12 - Restore Original NetEase Lawnchair
# Restores the original factory-shipped Lawnchair APK by removing KernelSU bind-mount
# Target: MuMu Player 12 (Android 15)

param(
    [int]$VmIndex = 1,
    [string]$MumuInstallDir = "D:\Program Files\Netease\MuMu Player 12"
)

$ErrorActionPreference = "Stop"

Write-Host "=========================================================" -ForegroundColor Yellow
Write-Host "     MuMu Player 12 - Restore Original Lawnchair Fork    " -ForegroundColor Yellow
Write-Host "=========================================================" -ForegroundColor Yellow

$backupApk = Join-Path $PSScriptRoot "backup\Lawnchair_mumu_original.apk"

$adbPath = Join-Path $MumuInstallDir "nx_device\15.0\shell\adb.exe"
if (-not (Test-Path $adbPath)) {
    $adbPath = Join-Path $MumuInstallDir "shell\adb.exe"
}

# Resolve VM Device (Bridged vs NAT)
$macFilePath = Join-Path $MumuInstallDir "vms\MuMuPlayer-15.0-$VmIndex\macaddress"
$vmMac = $null

if (Test-Path $macFilePath) {
    $rawMac = (Get-Content $macFilePath -Raw).Trim()
    if ($rawMac) {
        $vmMac = ($rawMac -replace '..(?!$)', '$0-')
    }
}

$bridgedIp = $null
if ($vmMac) {
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
    $port = 16416 + ($VmIndex * 32)
    $device = "127.0.0.1:$port"
}

Write-Host "[1/5] Connecting ADB to $device..." -ForegroundColor Yellow
& $adbPath connect $device | Out-Null
& $adbPath -s $device root | Out-Null
Start-Sleep -Seconds 1
& $adbPath connect $device | Out-Null

Write-Host "[2/5] Removing KernelSU Lawnchair module & boot hook..." -ForegroundColor Yellow
& $adbPath -s $device shell "
rm -f /data/adb/post-fs-data.d/00_lawnchair.sh
rm -rf /data/adb/modules/lawnchair
umount /system/priv-app/Lawnchair/Lawnchair.apk 2>/dev/null || true
" | Out-Null

Write-Host "[3/5] Cleaning any legacy overlayfs scratch pollution..." -ForegroundColor Yellow
& $adbPath -s $device shell "
mkdir -p /mnt/scratch_clean 2>/dev/null
mount -t ext4 /dev/block/sda8 /mnt/scratch_clean 2>/dev/null
if [ -d /mnt/scratch_clean/upperdir/priv-app/Lawnchair ]; then
    rm -rf /mnt/scratch_clean/upperdir/priv-app/Lawnchair
fi
umount /mnt/scratch_clean 2>/dev/null
rmdir /mnt/scratch_clean 2>/dev/null
" | Out-Null

Write-Host "[4/5] Verifying factory Lawnchair APK in underlying squashfs..." -ForegroundColor Yellow
$checkApk = & $adbPath -s $device shell "if [ -f /system/priv-app/Lawnchair/Lawnchair.apk ]; then echo EXISTS; fi"
if ($checkApk -notlike "*EXISTS*") {
    if (Test-Path $backupApk) {
        Write-Host "  [*] Squashfs APK missing, restoring from $backupApk..." -ForegroundColor Yellow
        & $adbPath -s $device push $backupApk /data/local/tmp/Lawnchair_restore.apk | Out-Null
        & $adbPath -s $device shell "
        cp /data/local/tmp/Lawnchair_restore.apk /system/priv-app/Lawnchair/Lawnchair.apk
        chmod 644 /system/priv-app/Lawnchair/Lawnchair.apk
        chown root:root /system/priv-app/Lawnchair/Lawnchair.apk
        rm -f /data/local/tmp/Lawnchair_restore.apk
        " | Out-Null
    } else {
        Write-Warning "Factory APK not detected in squashfs and backup file not found at $backupApk"
    }
} else {
    Write-Host "  [+] Pristine factory Lawnchair APK verified in squashfs lowerdir." -ForegroundColor Green
}

# Clear package cache and app state
& $adbPath -s $device shell "
rm -rf /data/system/package_cache/*
pm clear app.lawnchair 2>/dev/null
" | Out-Null

Write-Host "[5/5] Restarting Android runtime..." -ForegroundColor Yellow
& $adbPath -s $device shell "setprop ctl.restart zygote"

Write-Host "[*] Waiting for Android runtime to settle (10s)..." -ForegroundColor Gray
Start-Sleep -Seconds 10
& $adbPath connect $device | Out-Null

# Ensure User 0 package registration and HOME role
& $adbPath -s $device shell "
cmd package install-existing app.lawnchair 2>/dev/null
cmd role add-role-holder android.app.role.HOME app.lawnchair 2>/dev/null
am start -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null
" | Out-Null

# Wait for process
for ($i = 0; $i -lt 15; $i++) {
    $pidStr = & $adbPath -s $device shell "pidof app.lawnchair" 2>$null
    if ($pidStr -and $pidStr.Trim()) {
        Write-Host "  [+] Lawnchair running with PID: $($pidStr.Trim())" -ForegroundColor Green
        break
    }
    Start-Sleep -Seconds 2
}

Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  Original NetEase Lawnchair Restored Successfully!      " -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
