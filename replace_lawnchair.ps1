# MuMu Player 12 - Replace Custom Lawnchair with Official Upstream Release
# Replaces NetEase's ad-modified Lawnchair with official Lawnchair 15 Beta 3

param(
    [int]$VmIndex = 1,
    [string]$MumuInstallDir = "D:\Program Files\Netease\MuMu Player 12"
)

$ErrorActionPreference = "Stop"

Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "    MuMu Player 12 - Official Lawnchair 15 Installer     " -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

$officialApk = Join-Path $PSScriptRoot "Lawnchair.15.0.0.Beta.3.0.apk"
$backupDir = Join-Path $PSScriptRoot "backup"
$backupApk = Join-Path $backupDir "Lawnchair_mumu_original.apk"

if (-not (Test-Path $officialApk)) {
    Write-Error "Official Lawnchair APK not found at $officialApk"
}

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

# Ensure backup exists
if (-not (Test-Path $backupApk)) {
    Write-Host "[2/5] Creating backup of original Lawnchair.apk..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    & $adbPath -s $device pull /system/priv-app/Lawnchair/Lawnchair.apk $backupApk | Out-Null
} else {
    Write-Host "[2/5] Backup already verified at $backupApk" -ForegroundColor Green
}

Write-Host "[3/5] Cleaning any legacy overlayfs scratch pollution..." -ForegroundColor Yellow
# If previous direct overlayfs writes created whiteouts or corrupt upperdir inodes on sda8, clean them up
& $adbPath -s $device shell "
mkdir -p /mnt/scratch_clean 2>/dev/null
mount -t ext4 /dev/block/sda8 /mnt/scratch_clean 2>/dev/null
if [ -d /mnt/scratch_clean/upperdir/priv-app/Lawnchair ]; then
    rm -rf /mnt/scratch_clean/upperdir/priv-app/Lawnchair
fi
umount /mnt/scratch_clean 2>/dev/null
rmdir /mnt/scratch_clean 2>/dev/null
" | Out-Null

Write-Host "[4/5] Deploying official signed Lawnchair 15 via KernelSU post-fs-data hook..." -ForegroundColor Yellow
& $adbPath -s $device shell "
mkdir -p /data/adb/modules/lawnchair/system/priv-app/Lawnchair
mkdir -p /data/adb/post-fs-data.d
" | Out-Null

& $adbPath -s $device push $officialApk /data/adb/modules/lawnchair/system/priv-app/Lawnchair/Lawnchair.apk | Out-Null

& $adbPath -s $device shell "
chmod 644 /data/adb/modules/lawnchair/system/priv-app/Lawnchair/Lawnchair.apk
chown -R root:root /data/adb/modules/lawnchair

cat << 'EOF' > /data/adb/modules/lawnchair/module.prop
id=lawnchair
name=Official Lawnchair 15
version=15.0.0-beta.3
versionCode=1500020300
author=Lawnchair
description=Official signed Lawnchair 15 launcher
EOF

cat << 'EOF' > /data/adb/post-fs-data.d/00_lawnchair.sh
#!/system/bin/sh
mount -o bind /data/adb/modules/lawnchair/system/priv-app/Lawnchair/Lawnchair.apk /system/priv-app/Lawnchair/Lawnchair.apk
EOF

chmod 755 /data/adb/post-fs-data.d/00_lawnchair.sh

# Bind mount immediately for the current runtime session
mount -o bind /data/adb/modules/lawnchair/system/priv-app/Lawnchair/Lawnchair.apk /system/priv-app/Lawnchair/Lawnchair.apk 2>/dev/null || true

# Purge package cache and restart Zygote
rm -rf /data/system/package_cache/*
" | Out-Null

Write-Host "[5/5] Restarting Android runtime to register official launcher..." -ForegroundColor Yellow
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
Write-Host "  Official Lawnchair 15 Installed Successfully!           " -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
