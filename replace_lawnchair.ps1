# Deploy an already platform-signed Lawnchair APK using an early bind mount.
param(
    [ValidateRange(0,2147483647)][int]$VmIndex = 1,
    [string]$MumuInstallDir = 'D:\Program Files\Netease\MuMu Player 12',
    [string]$SignedApkPath = (Join-Path $PSScriptRoot 'Lawnchair.15.0.0.Beta.3.0-aligned-signed.apk'),
    [string]$SignerJarPath = (Join-Path $PSScriptRoot 'uber-apk-signer.jar')
)
$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $PSScriptRoot 'mumu_common.ps1')
    Assert-MumuSignedApk $SignedApkPath $SignerJarPath
    $connection = New-MumuConnection -MumuInstallDir $MumuInstallDir -VmIndex $VmIndex -Root
    $target = '/system/priv-app/Lawnchair/Lawnchair.apk'
    $module = '/data/adb/modules/lawnchair'
    $moduleApk = "$module/system/priv-app/Lawnchair/Lawnchair.apk"
    $backupDir = Join-Path $PSScriptRoot "backup\vm-$VmIndex"
    $backupApk = Join-Path $backupDir 'Lawnchair_mumu_original.apk'
    if (-not (Test-Path -LiteralPath $backupApk -PathType Leaf)) {
        if (Test-MumuLauncherMount $connection) { throw 'Launcher is already mounted, but this VM has no original backup. Restore the factory launcher before creating a backup.' }
        if (-not (Test-MumuFile $connection $target)) { throw 'Factory Lawnchair APK is missing.' }
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        $partialBackup = "$backupApk.partial"
        try {
            Invoke-MumuNative $connection.AdbPath @('-s', $connection.Device, 'pull', $target, $partialBackup) -TimeoutSeconds 300 | Out-Null
            if ((Get-Item -LiteralPath $partialBackup).Length -eq 0) { throw 'Original launcher backup is empty.' }
            $remoteHash = Invoke-MumuShell $connection "sha256sum '$target'"
            if (($remoteHash.StdOut -split '\s+')[0] -ne (Get-FileHash -LiteralPath $partialBackup -Algorithm SHA256).Hash) { throw 'Original launcher backup checksum mismatch.' }
            Move-Item -LiteralPath $partialBackup -Destination $backupApk
        } finally {
            if (Test-Path -LiteralPath $partialBackup) { Remove-Item -LiteralPath $partialBackup -Force }
        }
    }
    if ((Get-Item -LiteralPath $backupApk).Length -eq 0) { throw 'Original launcher backup is empty.' }
    $staging = '/data/local/tmp/mumu_lawnchair_' + [guid]::NewGuid().ToString('N') + '.apk'
    try {
        Send-MumuVerifiedFile $connection $SignedApkPath $staging
        Invoke-MumuShell $connection "mkdir -p '$module/system/priv-app/Lawnchair' /data/adb/post-fs-data.d" | Out-Null
        # Own the mount explicitly; avoid a second KernelSU automatic mount.
        Invoke-MumuShell $connection "touch '$module/skip_mount'" | Out-Null
        if (Test-MumuLauncherMount $connection) {
            Invoke-MumuShell $connection "umount '$target'" | Out-Null
            if (Test-MumuLauncherMount $connection) { throw 'Previous launcher mount is still active.' }
        }
        Invoke-MumuShell $connection "cp '$staging' '$moduleApk'" | Out-Null
        Invoke-MumuShell $connection "chmod 644 '$moduleApk'" | Out-Null
        Invoke-MumuShell $connection "chown -R root:root '$module'" | Out-Null
        $properties = @'
id=lawnchair
name=Official Lawnchair 15
version=15.0.0-beta.3
versionCode=1500020300
author=Lawnchair
description=Platform-signed launcher using an explicit boot bind mount
'@
        Invoke-MumuShell $connection "cat > '$module/module.prop' <<'MUMU_EOF'`n$properties`nMUMU_EOF" | Out-Null
        Invoke-MumuShell $connection "mount -o bind '$moduleApk' '$target'" | Out-Null
        if (-not (Test-MumuLauncherMount $connection)) { throw 'Launcher bind mount was not registered.' }
        $expectedHash = (Get-FileHash -LiteralPath $SignedApkPath -Algorithm SHA256).Hash
        $mountedHash = Invoke-MumuShell $connection "sha256sum '$target'"
        if (($mountedHash.StdOut -split '\s+')[0] -ne $expectedHash) { throw 'Mounted launcher checksum mismatch.' }
        # Persist only a mount that has passed verification.
        $hook = "#!/system/bin/sh`nmount -o bind '$moduleApk' '$target'"
        Invoke-MumuShell $connection "cat > /data/adb/post-fs-data.d/00_lawnchair.sh <<'MUMU_EOF'`n$hook`nMUMU_EOF" | Out-Null
        Invoke-MumuShell $connection 'chmod 755 /data/adb/post-fs-data.d/00_lawnchair.sh' | Out-Null
    } finally {
        Invoke-MumuShell $connection "rm -f '$staging'" -AllowFailure | Out-Null
    }
    Invoke-MumuShell $connection 'rm -rf /data/system/package_cache/*' | Out-Null
    Complete-MumuLauncherRestart $connection
    Write-Host 'Official Lawnchair installed and HOME role verified.' -ForegroundColor Green
    exit 0
} catch {
    [Console]::Error.WriteLine("Launcher installation failed: $($_.Exception.Message)")
    exit 1
}
