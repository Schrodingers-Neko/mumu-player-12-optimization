# MuMu Player 12 (Android 15) Complete Debloating, Optimization & Setup Guide

This guide provides a comprehensive, step-by-step technical blueprint for transforming **MuMu Player 12** running **Android 15** into a clean, telemetry-free, high-performance workstation environment. 

It is designed to be fully reproducible by any user or AI agent on another instance of MuMu Player 12.

---

## 1. System Architecture & Prerequisites

### Architecture Overview
* **Emulator**: MuMu Player 12 (Core 6.8.1.0 / MuMu 6.0 client).
* **Guest OS**: Android 15 (`vanillaicecream`, SDK 35, 64-bit).
* **Virtualization Backend**: NetEase custom VirtualBox build (`nemu-vbox7`).
* **Storage Structure**: System partition mounted read-write via overlayfs (`/mnt/scratch/upperdir`).
* **Root Solution**: Native KernelSU (`me.weishu.kernelsu`).

### Script requirements and failure behavior

Use Windows PowerShell 5.1 or PowerShell 7 and keep `mumu_common.ps1` beside the four entry-point scripts. Set `-MumuInstallDir` explicitly if your installation differs from the scripts' default `D:\Program Files\Netease\MuMu Player 12`. Every script validates the selected Android 15 VM, queries its assigned NAT port, and verifies ADB connectivity. Bridge mode uses only the configured adapter's neighbor table and bounded asynchronous .NET subnet probes (30 seconds); unresolved or ambiguous bridge targets are errors, never NAT fallbacks.

Only the debloater may start a stopped VM, with a 75-second startup deadline. The installer and launcher scripts require a running instance. Privileged operations require verified root access. Necessary command failures stop subsequent steps and return exit `1`; earlier changes are not automatically rolled back. APK installation requires ADB exit `0` and a `Success` line. Cancelling its file picker returns `0`, and the batch wrapper preserves exit status and filenames with spaces, `&` and `!`.

Install HeliBoard before debloating. The script must confirm, enable and select `helium314.keyboard/.latin.LatinIME` before package, hosts or Windows cleanup changes. If that fails, it leaves Sogou enabled and stops. It does not download a replacement keyboard.

### Locating the MuMu Installation Directory (`<MUMU_DIR>`)
MuMu Player is typically installed at `C:\Program Files\Netease\MuMu Player 12\` by default, or at a custom drive/directory chosen during installation.

You can set this path manually in PowerShell, or auto-detect it from the Windows Registry:
```powershell
# Auto-detect from Windows Registry
$mumuDir = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like "*MuMu*" }).InstallLocation

# Or define manually if installed elsewhere:
# $mumuDir = "C:\Program Files\Netease\MuMu Player 12"

$adb = Join-Path $mumuDir "nx_device\15.0\shell\adb.exe"
if (-not (Test-Path $adb)) { $adb = Join-Path $mumuDir "shell\adb.exe" }
$mumuCli = Join-Path $mumuDir "nx_main\mumu-cli.exe"
$vmDir = Join-Path $mumuDir "vms\MuMuPlayer-15.0-1"
```

* **ADB Executable**: `<MUMU_DIR>\nx_device\15.0\shell\adb.exe` (or `<MUMU_DIR>\shell\adb.exe`)
* **MuMu CLI Tool**: `<MUMU_DIR>\nx_main\mumu-cli.exe`
* **VM Data & Configurations**: `<MUMU_DIR>\vms\MuMuPlayer-15.0-1\`

---

## 2. High-Performance Network Bridging (1 Gbps Line-Rate Setup)

By default, MuMu Player runs in **NAT Mode**, which routes traffic through VirtualBox *Slirp* user-space software sockets. This imposes severe CPU context-switching overhead and throttles network throughput to **30–80 Mbps**. 

Configuring **Network Bridge Mode** binds the VM directly to your physical host Ethernet or Wi-Fi adapter at Layer 2 (Data Link layer), providing full line-rate **1 Gbps (1,000 Mbps)** throughput with ultra-low **~3.7 ms** latency.

### Step-by-Step Configuration

1. **Enable Network Bridge in MuMu Settings**:
   - Open MuMu Player Settings ➔ **Basic** / **Network Settings**.
   - Set Network Mode to **Bridge Mode**.
   - Select your physical network adapter (e.g., your primary Intel/Realtek Gigabit Ethernet or Wi-Fi adapter).
   - Set IP assignment to **DHCP** and click Save / Restart.

2. **Locate the VM's Bridged IP Address**:
   - The VM acts as an independent physical device on your LAN, obtaining an IP directly from your local router.
   - You can retrieve the VM's hardware MAC address from:
     ```powershell
     $vmMac = (Get-Content (Join-Path $vmDir "macaddress") -Raw).Trim()
     ```
   - Query your Windows host ARP neighbor table to find the corresponding IP:
     ```powershell
     $formattedMac = ($vmMac -replace '..(?!$)', '$0-')
     (Get-NetNeighbor -LinkLayerAddress $formattedMac).IPAddress
     ```

3. **Connect via ADB Directly to the Bridged IP**:
   ```powershell
   $vmIp = "<VM_IP>"  # Replace with the resolved bridged LAN IP (e.g. 192.168.1.x / 10.0.0.x)
   
   & $adb connect "$($vmIp):5555"
   & $adb -s "$($vmIp):5555" root
   & $adb connect "$($vmIp):5555"
   ```
   *(Note: In Bridged Mode, VirtualBox disables the loopback NAT port `127.0.0.1:16416`. Always connect directly to the VM's LAN IP).*

---

## 3. Bloatware, Adware & Telemetry Neutralization

### A. Disable NetEase Adware & Telemetry Packages
Inside Android 15, NetEase runs several background services that push game ads, record device telemetry, and consume background CPU cycles. Install HeliBoard first (see section 5). The automated debloater enforces this prerequisite. For manual shell commands, verify the replacement before disabling any package:

```bash
# Connect to ADB shell as root
adb -s <VM_IP>:5555 shell

# Stop before disabling packages if HeliBoard is missing or cannot be selected.
ime list -a -s | grep -Fxq 'helium314.keyboard/.latin.LatinIME' || exit 1
ime enable helium314.keyboard/.latin.LatinIME || exit 1
ime set helium314.keyboard/.latin.LatinIME || exit 1
[ "$(settings get secure default_input_method)" = 'helium314.keyboard/.latin.LatinIME' ] || exit 1

# 1. Disable NetEase App Store (pushes ads and promotional carousels)
pm disable-user --user 0 com.mumu.store

# 2. Disable NetEase SensorsData Analytics & Tracking SDK
pm disable-user --user 0 com.mumu.shared.sdk

# 3. Disable MuMu Accelerator (background VPN daemon sending telemetry)
pm disable-user --user 0 com.mumu.acc

# 4. Disable Open Anonymous Device Identifier (OAID) tracking framework
pm disable-user --user 0 com.nemu.oaidmanager

# 5. Disable NetEase Network Location Provider tracker
pm disable-user --user 0 com.nemu.nlp

# 6. Disable bundled Sogou IME (adware keyboard with Chinese query logging)
pm disable-user --user 0 com.sohu.inputmethod.sogou.chuizi

# 7. Disable redundant AOSP system shells
pm disable-user --user 0 com.android.chromium
pm disable-user --user 0 com.android.camera2

# 8. Uninstall leftover Google installer wizard
pm uninstall -k --user 0 com.nemu.googleinstaller
```

*(Note: If you use MuMu's multi-account cloner, keep `com.netease.mumu.cloner` intact).*

### B. In-Guest DNS Sinkhole (`/system/etc/hosts`)
MuMu's system partition overlayfs is mounted read-write. You can block NetEase tracking domains directly inside Android's `/system/etc/hosts`:

```bash
# Append tracking endpoints to /system/etc/hosts
cat << 'EOF' >> /system/etc/hosts

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
EOF
```

### C. Windows Host-Side Protections
NetEase's Windows client downloads ad banners and scans running processes on the host. Neutralize these behaviors in PowerShell on Windows:

```powershell
# 1. Clear cached banner ads and lock folder permissions
$adDir = "$env:APPDATA\Netease\MuMuPlayer\data\ProgramAds"
if (Test-Path $adDir) {
    Remove-Item -Recurse -Force "$adDir\*"
    icacls $adDir /deny Everyone:(OI)(CI)(W,D)
}

# 2. Neutralize host process scanner configuration
$reportConfig = "$env:APPDATA\Netease\MuMuPlayer\configs\report_app_data_config.json"
if (Test-Path $reportConfig) {
    Set-Content -Path $reportConfig -Value "{}"
    Set-ItemProperty -Path $reportConfig -Name IsReadOnly -Value $true
}
```

---

## 4. Replacing MuMu's Custom Lawnchair with Official Lawnchair 15 (Material 3 Pixel Desktop)

### The Problem
MuMu Player ships with a proprietary, closed-source fork of Lawnchair 15 located at `/system/priv-app/Lawnchair/Lawnchair.apk`. 
NetEase modified the root layout to inject `app:id/mumu_search_bar`. Once `com.mumu.store` is disabled, this element becomes an unresponsive, dead `"Search games & apps"` banner at the top of the desktop.

### The Android 15 Quickstep Crash & Boot Hang ("Phone is starting...")
If you attempt to replace this APK with the official upstream release from GitHub (`Lawnchair 15 Beta 3`):
1. **The Symptom**: On cold boot, the emulator gets permanently stuck at `"Phone is starting..."` (`com.android.settings.FallbackHome`), with Lawnchair failing to load or repeatedly crashing.
2. **The Dual Root Causes**: 
   - **Root Cause A (Signature & Settings Privilege)**:
     - Lawnchair 15's Quickstep gesture navigation queries `@hide` system settings (`swipe_bottom_to_notification_enabled`) and requires `signature|recents` (`android.permission.MANAGE_ACTIVITY_TASKS`).
     - In Android 15, hidden settings keys and recents management are restricted strictly to **Platform-Signed System Applications**.
     - NetEase built MuMu's Android 15 ROM with the standard **AOSP Platform Test Key** (`SHA256: C8:A2:E9:BC:CF:59:7C:2F:B6:DC:66:BE:E2:93:FC:13:F2:FC:47:EC:77:BC:6B:2B:0D:52:C1:1F:51:19:2A:B8`).
     - An APK signed with Lawnchair's developer release key will throw `java.lang.SecurityException: Settings key: <swipe_bottom_to_notification_enabled> is not readable`.
   - **Root Cause B (Overlayfs Inode Corruption & Vold Teardown)**:
     - MuMu mounts `/system` as an overlayfs backed by a persistent scratch partition (`/mnt/scratch/upperdir/` on `sda8`).
     - Directly copying files into `/system/priv-app` or running `rm -rf /system/priv-app/Lawnchair/oat` creates overlayfs whiteout character devices (`c 0 0 oat`) and tags the directory with `trusted.overlay.impure="y"`.
     - During early boot, Android's `vold` daemon unmounts `/mnt/scratch`. Because the kernel's overlayfs driver cannot verify dirty upperdir whiteout metadata once the underlying mount point changes, non-root processes (`system_server`, `uid=1000`) encounter kernel-level `EPERM` (Operation not permitted) on `stat()` calls to `/system/priv-app/Lawnchair`.
     - Consequently, `PackageManagerService` skips Lawnchair, wipes its state, and defaults to `com.android.settings.FallbackHome`.
   - **Root Cause C (`pm uninstall` Strips Home Role)**:
     - Running `pm uninstall app.lawnchair` sets `installed=false` for User 0 and unbinds `android.app.role.HOME`.

---

### The Complete Solution: Platform Resigning + KernelSU Early Bind-Mount

To achieve 100% stability across cold reboots with zero crashes:
1. Resign the official Lawnchair 15 APK with the AOSP platform key.
2. Inject the APK using **KernelSU's `post-fs-data.d` early bind-mount** before `PackageManagerService` starts, leaving the underlying squashfs and overlayfs scratch partition untouched.

#### Step 1: Obtain the AOSP Platform Keypair
Download the standard open-source AOSP platform keypair:
```powershell
curl.exe -L -o "platform.pk8" "https://raw.githubusercontent.com/aosp-mirror/platform_build/master/target/product/security/platform.pk8"
curl.exe -L -o "platform.x509.pem" "https://raw.githubusercontent.com/aosp-mirror/platform_build/master/target/product/security/platform.x509.pem"
```

#### Step 2: Convert to PKCS12 Keystore
Using OpenSSL (included with Git for Windows):
```powershell
$openssl = "C:\Program Files\Git\usr\bin\openssl.exe"
& $openssl pkcs8 -inform DER -nocrypt -in "platform.pk8" -out "platform.key"
& $openssl pkcs12 -export -in "platform.x509.pem" -inkey "platform.key" -out "platform.p12" -name platform -password pass:android
```

#### Step 3: Resign Official Lawnchair 15 Beta 3
```powershell
# Download uber-apk-signer
curl.exe -L -o "uber-apk-signer.jar" "https://github.com/patrickfav/uber-apk-signer/releases/download/v1.3.0/uber-apk-signer-1.3.0.jar"

# Resign official Lawnchair 15 Beta 3 APK
java -jar "uber-apk-signer.jar" -a "Lawnchair.15.0.0.Beta.3.0.apk" --ks "platform.p12" --ksAlias platform --ksPass android --ksKeyPass android --allowResign -o "."
```

Without `--overwrite`, the signer creates **`Lawnchair.15.0.0.Beta.3.0-aligned-signed.apk`** and leaves the input APK unchanged. Deploy that output. Do not accidentally deploy the original upstream-signed input. APKs, signer JARs and private keys remain local and ignored by Git.

#### Step 4: Automated Deployment via KernelSU (`replace_lawnchair.ps1`)
Require Java on PATH and a local `uber-apk-signer.jar`. The installer verifies the APK's signature against the SHA-256 fingerprint of the tracked `platform.x509.pem` before connecting to MuMu. Missing verification tools or a certificate mismatch are fatal; it never signs automatically or falls back to the original APK. With the target instance running, deploy:
```powershell
.\replace_lawnchair.ps1 -VmIndex 1 -MumuInstallDir $mumuDir `
    -SignedApkPath ".\Lawnchair.15.0.0.Beta.3.0-aligned-signed.apk" -SignerJarPath ".\uber-apk-signer.jar"
```

The script first pulls and checksum-verifies a nonempty original backup at `backup/vm-<index>/Lawnchair_mumu_original.apk`. It uploads to a temporary device path, verifies SHA-256, deploys the module APK, verifies the live bind mount and its checksum, and only then writes the boot hook and restarts Android. It stops on any necessary failure, and never edits the raw scratch partition to repair legacy corruption. Preserve the per-instance backup. If a replacement is already mounted but no backup exists, restore the factory launcher before attempting a new backup.

**How the KernelSU Hook Works Under the Hood**:
1. Creates a KernelSU module directory:
   `/data/adb/modules/lawnchair/system/priv-app/Lawnchair/Lawnchair.apk`
   The module includes `skip_mount` so KernelSU does not add a second automatic mount.
2. Creates an early boot hook in `/data/adb/post-fs-data.d/00_lawnchair.sh`:
   ```bash
   #!/system/bin/sh
   mount -o bind /data/adb/modules/lawnchair/system/priv-app/Lawnchair/Lawnchair.apk /system/priv-app/Lawnchair/Lawnchair.apk
   ```
3. Because `post-fs-data.d` runs from PID 1 before Zygote and `PackageManagerService` initialize, the bind mount propagates cleanly to all Android mount namespaces (`MS_SHARED`).
4. Re-registers the home role without destructive uninstalls:
   ```bash
   cmd role add-role-holder android.app.role.HOME app.lawnchair
   ```

#### Step 5: Verification
The scripts allow up to 90 seconds for Android and PackageManager readiness, then up to 30 seconds for a verified HOME role and running Lawnchair process. They return failure on timeout. For additional manual inspection:
```powershell
# Check package version and privileges
& $adb shell "dumpsys package app.lawnchair | grep -E 'versionName|flags|seinfo'"
# Output should show: versionName=15.Beta 3, flags=...[SYSTEM], privateFlags=...[PRIVILEGED]

# Check active window focus
& $adb shell "dumpsys window | grep -E 'mCurrentFocus|mFocusedApp'"
# Output should show: app.lawnchair/app.lawnchair.LawnchairLauncher
```

#### Step 6: Restoring Factory NetEase Lawnchair
If you ever want to revert back to MuMu's stock launcher, run:
```powershell
.\restore_lawnchair.ps1 -VmIndex 1 -MumuInstallDir $mumuDir
```
Restoration checks for an underlying factory APK or nonempty per-instance backup before teardown. It unmounts successfully before removing the module, verifies any restored backup bytes, and stops before cache clearing or restart if restoration fails. The old shared `backup/Lawnchair_mumu_original.apk` is accepted only for VM 1. Restoration clears Lawnchair settings and home-screen layout. Legacy scratch corruption is not repaired automatically; if a required recovery copy cannot be written, the script reports failure.

---

## 5. Modern System Utilities (FOSS)

Install the following vetted open-source utilities to replace proprietary components:

### 1. Material Files (`me.zhanghai.android.files`)
* **Purpose**: Desktop-grade root file manager.
* **Key Features**: Dual-pane navigation (ideal for landscape/tablet displays), built-in archive management (`.zip`, `.7z`, `.tar`), KernelSU root explorer, and Windows SMB file sharing support.
* **Installation & Permissions**:
  ```powershell
  & $adb -s "<VM_IP>:5555" install -r "MaterialFiles.apk"
  & $adb -s "<VM_IP>:5555" shell "appops set me.zhanghai.android.files MANAGE_EXTERNAL_STORAGE allow"
  ```

### 2. Image 2 Wallpaper (`com.shirobakama.wallpaper`)
* **Purpose**: Precise wallpaper scaling and positioning tool.
* **Key Features**: Allows setting high-resolution and 4K wallpapers with 1:1 pixel rendering, "Fit to screen", and "No scroll" modes. Bypasses Android's default behavior of forcing square crops or stretching images across multiple virtual screens.
* **Installation & Permissions**:
  ```powershell
  & $adb -s "<VM_IP>:5555" install -r "Image_2_Wallpaper.apk"
  & $adb -s "<VM_IP>:5555" shell "pm grant com.shirobakama.wallpaper android.permission.READ_MEDIA_IMAGES"
  ```

### 3. HeliBoard (`helium314.keyboard`)
* **Purpose**: Privacy-focused, offline AOSP keyboard.
* **Key Features**: Replaces the ad-supported Sogou IME. Fully offline with zero network permissions, custom themes, clipboard history, and multilingual support.
* **Installation & Activation**:
  ```powershell
  & $adb -s "<VM_IP>:5555" install -r "HeliBoard.apk"
  & $adb -s "<VM_IP>:5555" shell "ime enable helium314.keyboard/.latin.LatinIME"
  & $adb -s "<VM_IP>:5555" shell "ime set helium314.keyboard/.latin.LatinIME"
  ```

---

## 6. Shared Folder & Automatic Media Indexing

### Directory Mapping
* **Windows Host Path**: `C:\Users\<Username>\Documents\MuMu共享文件夹\Pictures\`
* **Android Mount Path**: `/sdcard/Pictures/` (mapped via `/mnt/shared/MuMuShared/Pictures/`)

### Resolving Missing Media Files in Gallery
When dropping images (such as 4K screenshots or wallpapers) into the Windows shared folder, Android's gallery or wallpaper picker may not display them immediately.

* **Cause**: VirtualBox's `vboxsf` shared folder driver does not generate Linux kernel `inotify` file-creation events, meaning Android's `MediaStore` database is not notified of new files added from Windows.
* **Solution**: Trigger the Android media scanner manually via ADB broadcast without needing to reboot the emulator:
  ```powershell
  & $adb -s "<VM_IP>:5555" shell "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d 'file:///sdcard/Pictures/<filename.png>'"
  ```
   Once the broadcast completes (`result=0`), the image is immediately accessible to Image 2 Wallpaper and all Android file pickers.

---

## 7. Isolated Regression Checks

These checks compile fake Windows CLI, ADB and Java processes using Windows PowerShell's bundled .NET Framework compiler. They need no additional testing framework and never connect to a real emulator. Run both supported hosts:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run.ps1
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run.ps1
```

The suite exercises queried NAT ports, bridge discovery, identity/connection errors, native stderr and timeouts, signature prerequisites, backup/upload/mount failures, safe restoration, Android/launcher timeouts, keyboard prerequisites, repeated debloating, and APK/batch argument and exit-code handling. Any live verification should use a disposable instance separately.
