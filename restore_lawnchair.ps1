# Restore the factory launcher only after confirming a usable source exists.
param(
    [ValidateRange(0,2147483647)][int]$VmIndex = 1,
    [string]$MumuInstallDir = 'D:\Program Files\Netease\MuMu Player 12'
)
$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $PSScriptRoot 'mumu_common.ps1')
    $connection = New-MumuConnection -MumuInstallDir $MumuInstallDir -VmIndex $VmIndex -Root
    $target = '/system/priv-app/Lawnchair/Lawnchair.apk'
    $backupApk = Join-Path $PSScriptRoot "backup\vm-$VmIndex\Lawnchair_mumu_original.apk"
    # Allow the legacy shared backup only for the original default VM.
    if ($VmIndex -eq 1 -and -not (Test-Path -LiteralPath $backupApk)) {
        $backupApk = Join-Path $PSScriptRoot 'backup\Lawnchair_mumu_original.apk'
    }
    $backupUsable = (Test-Path -LiteralPath $backupApk -PathType Leaf) -and (Get-Item -LiteralPath $backupApk).Length -gt 0
    $wasMounted = Test-MumuLauncherMount $connection
    # A nonrecursive directory bind exposes the underlying APK without copying
    # the nested file bind. Do not mistake the replacement for the factory APK.
    $view = '/data/local/tmp/mumu_lawnchair_factory_' + [guid]::NewGuid().ToString('N')
    $factoryAvailable = $false
    if ($wasMounted) {
        Invoke-MumuShell $connection "mkdir -p '$view'" | Out-Null
        $viewMounted = $false
        try {
            Invoke-MumuShell $connection "mount -o bind /system/priv-app/Lawnchair '$view'" | Out-Null
            $viewMounted = $true
            $factoryAvailable = Test-MumuFile $connection "$view/Lawnchair.apk"
        } finally {
            if ($viewMounted) { Invoke-MumuShell $connection "umount '$view'" | Out-Null }
            Invoke-MumuShell $connection "rmdir '$view'" | Out-Null
        }
    } else { $factoryAvailable = Test-MumuFile $connection $target }
    if (-not $factoryAvailable -and -not $backupUsable) { throw 'No factory launcher or nonempty backup is available. Module and boot hook were left intact.' }
    $staging = '/data/local/tmp/mumu_lawnchair_restore_' + [guid]::NewGuid().ToString('N') + '.apk'
    try {
        if (-not $factoryAvailable) { Send-MumuVerifiedFile $connection $backupApk $staging }
        if ($wasMounted) {
            Invoke-MumuShell $connection "umount '$target'" | Out-Null
            if (Test-MumuLauncherMount $connection) { throw 'Launcher remains mounted. Module and boot hook were left intact.' }
        }
        if (-not $factoryAvailable) {
            Invoke-MumuShell $connection "cp '$staging' '$target'" | Out-Null
            Invoke-MumuShell $connection "chmod 644 '$target'" | Out-Null
            Invoke-MumuShell $connection "chown root:root '$target'" | Out-Null
            $restoredHash = Invoke-MumuShell $connection "sha256sum '$target'"
            if (($restoredHash.StdOut -split '\s+')[0] -ne (Get-FileHash -LiteralPath $backupApk -Algorithm SHA256).Hash) { throw 'Restored launcher checksum mismatch.' }
        }
        if (-not (Test-MumuFile $connection $target)) { throw 'Factory launcher is not accessible after unmounting.' }
        Invoke-MumuShell $connection 'rm -f /data/adb/post-fs-data.d/00_lawnchair.sh' | Out-Null
        Invoke-MumuShell $connection 'rm -rf /data/adb/modules/lawnchair' | Out-Null
    } finally { Invoke-MumuShell $connection "rm -f '$staging'" -AllowFailure | Out-Null }
    Invoke-MumuShell $connection 'rm -rf /data/system/package_cache/*' | Out-Null
    $clear = Invoke-MumuShell $connection 'pm clear app.lawnchair'
    if ($clear.StdOut -ne 'Success') { throw "Could not clear launcher state: $($clear.Output)" }
    Complete-MumuLauncherRestart $connection
    Write-Host 'Factory Lawnchair restored and HOME role verified.' -ForegroundColor Green
    exit 0
} catch {
    [Console]::Error.WriteLine("Launcher restoration failed: $($_.Exception.Message)")
    exit 1
}
