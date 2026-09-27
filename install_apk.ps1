# Install a single APK into the selected running Android 15 instance.
param(
    [Parameter(Position=0)][string]$ApkPath,
    [ValidateRange(0,2147483647)][int]$VmIndex = 1,
    [string]$MumuInstallDir = 'D:\Program Files\Netease\MuMu Player 12'
)
$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $PSScriptRoot 'mumu_common.ps1')
    if (-not $ApkPath) {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        try {
            $dialog.Filter = 'Android Package (*.apk)|*.apk'
            $dialog.Title = 'Select APK to Install in MuMu Player'
            $dialog.InitialDirectory = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'
            if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
                Write-Host 'Installation cancelled.'
                exit 0
            }
            $ApkPath = $dialog.FileName
        } finally { $dialog.Dispose() }
    }
    $apk = Get-Item -LiteralPath $ApkPath -ErrorAction Stop
    if ($apk.PSIsContainer -or $apk.Length -eq 0 -or $apk.Extension -ne '.apk') { throw 'Select a nonempty .apk file.' }
    $connection = New-MumuConnection -MumuInstallDir $MumuInstallDir -VmIndex $VmIndex
    $result = Invoke-MumuNative $connection.AdbPath @('-s', $connection.Device, 'install', '-r', '-d', '-g', $apk.FullName) -TimeoutSeconds 300
    if (($result.StdOut -split '\r?\n') -notcontains 'Success') { throw "ADB did not confirm installation: $($result.Output)" }
    Write-Host 'SUCCESS: APK installed successfully into MuMu Player.' -ForegroundColor Green
    exit 0
} catch {
    [Console]::Error.WriteLine("APK installation failed: $($_.Exception.Message)")
    exit 1
}
