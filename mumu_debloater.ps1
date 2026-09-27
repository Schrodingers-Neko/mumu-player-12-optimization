# Disable MuMu adware only after verifying a working replacement keyboard.
param(
    [ValidateRange(0,2147483647)][int]$VmIndex = 1,
    [string]$MumuInstallDir = 'D:\Program Files\Netease\MuMu Player 12'
)
$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $PSScriptRoot 'mumu_common.ps1')
    $connection = New-MumuConnection -MumuInstallDir $MumuInstallDir -VmIndex $VmIndex -Launch -Root
    Enable-MumuHeliBoard $connection
    $googleInstaller = 'com.nemu.googleinstaller'
    if (Test-MumuPackage $connection $googleInstaller) {
        # Uninstall for user 0, keeping the system APK recoverable.
        $uninstall = Invoke-MumuShell $connection "pm uninstall -k --user 0 $googleInstaller"
        if ($uninstall.StdOut -ne 'Success' -or (Test-MumuPackage $connection $googleInstaller)) { throw "Could not uninstall $googleInstaller." }
    }
    $packagesToDisable = @(
        'com.mumu.store', 'com.mumu.shared.sdk', 'com.mumu.acc',
        'com.nemu.oaidmanager', 'com.nemu.nlp', 'com.sohu.inputmethod.sogou.chuizi',
        'com.android.chromium', 'com.android.camera2'
    )
    foreach ($package in $packagesToDisable) {
        if (-not (Test-MumuPackage $connection $package) -or (Test-MumuPackage $connection $package -Disabled)) { continue }
        Invoke-MumuShell $connection "am force-stop $package" | Out-Null
        Invoke-MumuShell $connection "pm disable-user --user 0 $package" | Out-Null
        if (-not (Test-MumuPackage $connection $package -Disabled)) { throw "Could not verify that $package is disabled." }
    }
    $tmpHosts = [IO.Path]::GetTempFileName()
    $remoteHosts = '/data/local/tmp/mumu_hosts_' + [guid]::NewGuid().ToString('N')
    try {
        $hostsText = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hosts') -Raw) -replace "`r`n", "`n"
        [IO.File]::WriteAllText($tmpHosts, $hostsText, (New-Object Text.UTF8Encoding($false)))
        Send-MumuVerifiedFile $connection $tmpHosts $remoteHosts
        Invoke-MumuShell $connection "cp '$remoteHosts' /system/etc/hosts" | Out-Null
        Invoke-MumuShell $connection 'chmod 644 /system/etc/hosts' | Out-Null
        $hostsHash = Invoke-MumuShell $connection 'sha256sum /system/etc/hosts'
        if (($hostsHash.StdOut -split '\s+')[0] -ne (Get-FileHash -LiteralPath $tmpHosts -Algorithm SHA256).Hash) { throw 'Could not verify the installed hosts blocklist.' }
    } finally {
        Remove-Item -LiteralPath $tmpHosts -Force
        Invoke-MumuShell $connection "rm -f '$remoteHosts'" -AllowFailure | Out-Null
    }
    $adsDir = Join-Path $env:APPDATA 'Netease\MuMuPlayer\data\ProgramAds'
    $advertisementDir = Join-Path $adsDir 'advertisement'
    if (Test-Path -LiteralPath $advertisementDir -PathType Container) {
        $resolvedAds = [IO.Path]::GetFullPath($advertisementDir).TrimEnd('\') + '\'
        Get-ChildItem -LiteralPath $advertisementDir -Force | ForEach-Object {
            $resolvedChild = [IO.Path]::GetFullPath($_.FullName)
            if (-not $resolvedChild.StartsWith($resolvedAds, [StringComparison]::OrdinalIgnoreCase) -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Unsafe ad cache entry: $resolvedChild" }
            Remove-Item -LiteralPath $resolvedChild -Recurse -Force
        }
    }
    $reportConfig = Join-Path $env:APPDATA 'Netease\MuMuPlayer\configs\report_app_data_config.json'
    foreach ($path in @((Join-Path $adsDir 'programAds.json'), $reportConfig)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Set-ItemProperty -LiteralPath $path -Name IsReadOnly -Value $false
            [IO.File]::WriteAllText($path, '{}', (New-Object Text.UTF8Encoding($false)))
            Set-ItemProperty -LiteralPath $path -Name IsReadOnly -Value $true
        }
    }
    Write-Host 'Debloating completed; keyboard, package state and blocklist verified.' -ForegroundColor Green
    exit 0
} catch {
    [Console]::Error.WriteLine("Debloating failed: $($_.Exception.Message)")
    exit 1
}
