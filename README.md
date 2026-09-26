# MuMu Player 12 (Android 15) Technical Audit & Debloating Guide

## Overview

This repository documents the architectural analysis, bloatware and adware catalog, network telemetry behaviors, and debloating procedures for **MuMu Player 12** running the **Android 15** engine.

---

## 1. Environment & Architecture

| Parameter | Value | Details |
| :--- | :--- | :--- |
| **MuMu Core Version** | `6.8.1.0` (MuMu 6.0 generation) | Windows client based on Qt5 + Chromium Embedded Framework (CEF) |
| **Android Version** | **Android 15** (`vanillaicecream`, SDK 35) | Kernel 6.1.90-perf+, 64-bit architecture |
| **Hypervisor Engine** | VirtualBox 7.2.4 (custom NetEase build: `nemu-vbox7`) | Headless backend managed by `nemu-vboxmanager.dll` |
| **Installation Path** | `<MUMU_DIR>` (e.g. `C:\Program Files\Netease\MuMu Player 12\`) | Android 15 device files located in `nx_device\15.0\` |
| **VM Storage Location** | `<MUMU_DIR>\vms\MuMuPlayer-15.0-<VM_INDEX>\` | `data.vdi` (User data), `system.vdi` (Base ROM), `system-diff.vdi` |
| **Root Capabilities** | Native KernelSU (`me.weishu.kernelsu`) & Magisk | System partition mounted read-write via overlayfs (`/mnt/scratch/upperdir`) |

---

## 2. MuMu CLI & ADB Connectivity

MuMu Player 12 includes a command-line interface located at:
```text
<MUMU_DIR>\nx_main\mumu-cli.exe
# Default path: C:\Program Files\Netease\MuMu Player 12\nx_main\mumu-cli.exe
```

### Essential CLI Commands
```powershell
# List all instances, Android versions, running status, and allocated ADB ports
.\mumu-cli.exe info -v all

# Launch or restart a specific VM instance (e.g. Instance 1 = Android 15)
.\mumu-cli.exe control -v 1 launch
.\mumu-cli.exe control -v 1 restart

# Dump all hardware, renderer, and network configurations for an instance
.\mumu-cli.exe setting -v 1 -a

# Install an APK from Windows into the emulator
.\mumu-cli.exe control -v 1 app install -apk "C:\Path\To\file.apk"
```

### Dynamic ADB Port Allocation & Network Modes (NAT vs. Bridge)

#### Mode 1: NAT Mode (Default)
* **Port Mapping**: VirtualBox creates a user-space NAT port forwarding rule (`127.0.0.1:16416` -> VM port `5555`).
* **Performance Impact**: Network throughput is bottlenecked (typically 30–80 Mbps) due to user-space *Slirp* software socket translations, high context switching overhead, and small fixed TCP window sizes.
* **ADB Connection**:
  ```powershell
  & "<MUMU_DIR>\nx_device\15.0\shell\adb.exe" connect 127.0.0.1:16416
  ```

#### Mode 2: Network Bridge Mode (High Speed 1 Gbps)
* **Mechanism**: VirtualBox binds directly to a physical host network adapter at Layer 2 (Data Link layer) using the NDIS filter driver (`nemu_net_bridge`).
* **Configured Interface**: Primary physical network adapter (e.g., Gigabit Ethernet or Wi-Fi).
* **DHCP & IP Assignment**:
  * The VM behaves as a physical device on your local LAN, negotiating an independent IP directly with your router via DHCP.
  * **Current Lease**: Dynamic IP assigned by your router (e.g. `192.168.1.x` / `10.0.0.x`).
  * **VM MAC Address**: Unique hardware MAC generated per VM instance (stored in `<MUMU_DIR>\vms\MuMuPlayer-15.0-<VM_INDEX>\macaddress`).
* **Throughput & Latency**: Eliminates all user-space NAT socket copying, enabling full unthrottled line-rate gigabit speeds (up to 1,000 Mbps) with low latency.
* **ADB Connection in Bridged Mode**:
  ```powershell
  & "<MUMU_DIR>\nx_device\15.0\shell\adb.exe" connect <VM_LAN_IP>:5555
  & "<MUMU_DIR>\nx_device\15.0\shell\adb.exe" -s <VM_LAN_IP>:5555 root
  ```
  *(Note: In Bridged mode, VirtualBox disables NAT port `127.0.0.1:16416`. Always connect directly to the VM's LAN IP).*

#### Automated Dynamic Resolution in `mumu_debloater.ps1`
The PowerShell script automatically handles both modes:
1. Reads `customer_config.json` to check if `network_bridge_opened` is enabled.
2. Extracts the VM's hardware MAC address from `vms\MuMuPlayer-15.0-1\macaddress`.
3. Resolves the active IP from Windows's ARP/neighbor cache (`Get-NetNeighbor`).
4. If bridge mode is off or unresolved, it gracefully falls back to NAT `127.0.0.1:$adb_port`.

---

## 3. Bloatware, Adware & Telemetry Catalog

### Inside Android 15

| Package Name | Type | Behavior & Threat Analysis | Action |
| :--- | :--- | :--- | :--- |
| `advertising.id.ccpa.gdpr` | Utility | Easy Advertising ID app (kept per user preference). | **Preserved** |
| `com.netease.mumu.cloner` | Utility | MuMu multi-account app cloner (kept per user preference). | **Preserved** |
| `com.mumu.store` | Store / Adware | MuMu App Store. Pushes promotional apps, opens persistent connections to NetEase ad networks (`23.58.184.62`, `123.58.183.1`), and holds wake locks. | **Disabled** (`pm disable-user --user 0`) |
| `com.mumu.shared.sdk` | Ad Tracking SDK | NetEase SensorsData analytics framework. Holds high privileged permissions. | **Disabled** (`pm disable-user --user 0`) |
| `com.mumu.acc` | Telemetry / VPN | "MuMu Accelerator" service. Maintained continuous active connections to NetEase telemetry servers (`42.186.25.83:443`, `123.6.124.14:443`). | **Disabled** (`pm disable-user --user 0`) |
| `com.nemu.oaidmanager` | Tracking | Open Anonymous Device Identifier framework used in Chinese Android ecosystems for ad targeting and profiling. | **Disabled** (`pm disable-user --user 0`) |
| `com.nemu.nlp` | Telemetry | Nemu Network Location Provider tracking service. | **Disabled** (`pm disable-user --user 0`) |
| `com.nemu.googleinstaller` | Leftover | Installer used to set up Google Play services initially. | **Uninstalled** (`pm uninstall`) |
| `com.sohu.inputmethod.sogou.chuizi` | Adware IME | Sogou Smartisan keyboard bundled in `/system/priv-app`. Sends search telemetry and suggestion queries to Sogou/Tencent servers. | **Disabled** (Replaced with HeliBoard) |
| `com.android.chromium` | Redundant | Duplicate AOSP browser shell (redundant with Chrome/Edge). | **Disabled** (`pm disable-user --user 0`) |
| `com.android.camera2` | Redundant | Stock AOSP camera application (unnecessary in emulator). | **Disabled** (`pm disable-user --user 0`) |

### On Windows Host

1. **Host Process Scanner (`report_app_data_config.json`)**:
   * Located at `%APPDATA%\Netease\MuMuPlayer\configs\report_app_data_config.json`.
   * MuMu monitors and logs running processes on the host Windows machine (including TeamViewer, AnyDesk, Tailscale, ZeroTier, competitive emulators, and gaming utilities) and transmits the list to NetEase.
   * *Mitigation*: Replaced with `{}` and set to Windows **Read-Only**.
2. **Promotional Banner Cache (`ProgramAds`)**:
   * Located at `%APPDATA%\Netease\MuMuPlayer\data\ProgramAds\`.
   * Automatically downloads graphical promo banners (`image_*.png`) from NetEase CDNs.
   * *Mitigation*: Deleted cached images, emptied `programAds.json`, and set to Windows **Read-Only**.
3. **Background Service (`MuMuRemoteService`)**:
   * Windows Service running `"<MUMU_DIR>\nx_main\MuMuRemoteService.exe" --service`.
   * Background server for "GameViewer" remote access. Runs constantly even when the emulator is closed.
   * *Mitigation*: Stop and disable in an Administrator PowerShell prompt if remote play is not used:
     ```powershell
     Stop-Service -Name "MuMuRemoteService" -Force
     Set-Service -Name "MuMuRemoteService" -StartupType Disabled
     ```

---

## 4. The High-Speed ADB APK Installation Pipeline

Because all NetEase adware (`com.mumu.store`, `com.mumu.shared.sdk`) is disabled, APKs are installed cleanly via ADB:

### How ADB Installation Operates
* Direct `adb install -r -d -g <file.apk>` connects directly to `adbd` (running as root) inside the Android kernel layer. `adbd` invokes Android's native AOSP `PackageManagerService` directly.
* Completely independent of MuMu's proprietary apps. **Works 100% of the time, zero bloatware or background store required.**
* Leverages the 1 Gbps Bridged Network interface, streaming multi-gigabyte APKs/OBBs in seconds.

### Quick Ways to Install APKs from Windows

1. **Right-Click Context Menu ("Install in MuMu Player (ADB)")**:
   * Right-click any `.apk` file anywhere in Windows Explorer and select **Install in MuMu Player (ADB)**.
   * Registered in `HKCU` via [`register_context_menu.reg`](register_context_menu.reg).
2. **Drag-and-Drop onto Batch Script**:
   * Drag any `.apk` file and drop it directly onto [`install_apk.bat`](install_apk.bat) (or a desktop shortcut to it).
3. **Interactive File Browser**:
   * Simply double-click [`install_apk.bat`](install_apk.bat). If no argument is provided, a Windows file picker opens automatically.
4. **Command Line / PowerShell**:
   ```powershell
   .\install_apk.ps1 "C:\Path\To\app.apk"
   ```


---

## 5. Keyboard Replacement: HeliBoard

Because Sogou IME was the only pre-installed keyboard, disabling it without a replacement would leave the Android system with no virtual input method.

* **Installed**: [HeliBoard](https://github.com/HeliBorg/HeliBoard) (`helium314.keyboard`), an open-source, offline privacy-focused AOSP keyboard fork with zero network permissions.
* **Configuration**:
  ```bash
  adb shell ime enable helium314.keyboard/.latin.LatinIME
  adb shell ime set helium314.keyboard/.latin.LatinIME
  ```
* **Disable Sogou IME**:
  ```bash
  adb shell am force-stop com.sohu.inputmethod.sogou.chuizi
  adb shell pm disable-user --user 0 com.sohu.inputmethod.sogou.chuizi
  ```

---

## 6. DNS / Hosts Telemetry Blacklist

The following entries are written to `/system/etc/hosts` to null-route (`0.0.0.0`) all known NetEase and MuMu tracking servers:

```text
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
```

---

## 7. Home Screen Launcher Architecture & "Search games & apps" Bar

### What is the Home Screen?
* **Base Package**: **Lawnchair 15** (v15.0.0.6, package `app.lawnchair`, installed in `/system/priv-app/Lawnchair/Lawnchair.apk`).
* **Source Base**: Lawnchair is a popular open-source launcher based on Google's AOSP Launcher3 (Pixel Launcher).
* **NetEase Modifications**: NetEase took Lawnchair 15 and created a proprietary fork by injecting NetEase tracking classes (`com.mumu.core.ad.*`, `com.mumu.core.search.*`, `com.mumu.core.view.MuMuRootView`). In this custom build, NetEase embedded a hardcoded top search bar layout (`res/layout/mumu_search_bar_view.xml`, View ID `app:id/mumu_search_bar`).

### What is the "Search games & apps" Bar?
* **Original Functionality**:
  * Connected directly to the **MuMu App Store (`com.mumu.store`)**.
  * Periodically pulled sponsored game advertisements, trending titles, and animated banners from NetEase ad networks (`api.mumu.netease.com`) into `app:id/searchAdListView`.
  * Tapping the bar launched `com.mumu.store` with pre-filled search intents (`mumu://store/search/`) to download sponsored games.
* **Why it is Blank & Unresponsive Now**:
  * With `com.mumu.store` disabled and NetEase ad domains blocked in `/system/etc/hosts`, the dynamic ad stream cannot load.
  * The search bar reverts to its hardcoded fallback string: `mumu_search_hint_text_oversea` = **"Search games & apps"**.
  * Tapping it tries to launch an intent targeted at `com.mumu.store`, which Android silently ignores because the package is disabled.

### Upstream Replacement Executed
* **Active Version**: **Official Lawnchair 15 Beta 3** (`v15.0.0-beta3.0`, Version Code `1500020300`).
* **Cryptographic Signing**: Resigned with the standard **AOSP Platform Key** (`SHA256: C8:A2:E9:BC:CF...`, matching MuMu's system ROM testkey). This grants Lawnchair authentic system privilege (`FLAG_SYSTEM | FLAG_PRIVILEGED`), enabling Quickstep to read internal settings keys (`swipe_bottom_to_notification_enabled`) without Android 15 `SecurityException` crashes.
* **KernelSU Early Bind-Mount**: Deployed via `/data/adb/post-fs-data.d/00_lawnchair.sh` at PID 1 early boot before `PackageManagerService` starts. This prevents overlayfs scratch corruption on `sda8`, avoids kernel `EPERM` errors on vold unmount, and keeps the factory squashfs base ROM untouched.
* **Result**:
  - The proprietary `app:id/mumu_search_bar` and all NetEase ad tracking libraries are **100% eliminated**.
  - All user apps remain preserved in the App Drawer in alphabetical order.
  - The home screen now features the clean, upstream Material 3 Pixel-style launcher layout.
  - Full official settings menu (Home settings, themes, icon packs, dock settings) is active and functional.

---

## 8. Open-Source Utility Suite (FOSS)

The following vetted open-source utilities are recommended to replace bare-bones or proprietary system components:

| Application | Package | Version | Source / Download | Purpose & Key Features |
| :--- | :--- | :--- | :--- | :--- |
| **Material Files** | `me.zhanghai.android.files` | `v1.7.5` | [GitHub Releases](https://github.com/zhanghai/MaterialFiles/releases) | Desktop-grade **Dual-Pane File Manager**, KernelSU root explorer, built-in archive extraction (`.zip`, `.7z`), SMB Windows shares. |
| **Image 2 Wallpaper** | `com.shirobakama.wallpaper` | `v2.1.3` | [Google Play / F-Droid](https://github.com/shirobakama/Image2Wallpaper) | Wallpaper utility allowing 1:1 pixel scaling, fit to screen, no scrolling, stretch, rotate, and aspect-ratio alignment without forced cropping. |
| **Droid-ify** | `com.looker.droidify` | `v0.7.8` | [GitHub Releases](https://github.com/Droid-ify/client/releases) | Material You client for F-Droid open-source repository; automatic updates for FOSS utilities. |
| **Termux** | `com.termux` | `v0.118.3` (x86_64) | [GitHub Releases](https://github.com/termux/termux-app/releases) | Full native x86_64 Linux terminal environment and `pkg` package manager (`python`, `git`, `curl`, etc.). |
| **VLC for Android** | `org.videolan.vlc` | `v3.7.1` (x86_64) | [VideoLAN / F-Droid](https://get.videolan.org/vlc-android/) | Native x86_64 hardware-accelerated media player supporting all audio/video formats and network streams. |

---

## 9. Repository Structure

* [`README.md`](README.md): Architecture analysis, network bridging instructions, and technical findings.
* [`MUMU_OPTIMIZATION_GUIDE.md`](MUMU_OPTIMIZATION_GUIDE.md): Complete step-by-step technical guide for reproducing the setup from scratch.
* [`replace_lawnchair.ps1`](replace_lawnchair.ps1): Automated script that deploys official platform-signed Lawnchair 15 Beta 3 via KernelSU `post-fs-data.d` bind-mount.
* [`restore_lawnchair.ps1`](restore_lawnchair.ps1): 1-click restore script that safely tears down the KernelSU hook and unmounts the launcher to restore factory NetEase Lawnchair.
* [`mumu_debloater.ps1`](mumu_debloater.ps1): Automated script that disables NetEase tracking, promotional stores, ad engines, and host scanners.
* [`install_apk.ps1`](install_apk.ps1): High-speed ADB installer script with file picker dialog and automatic bridge/NAT routing.
* [`install_apk.bat`](install_apk.bat): Windows batch wrapper for dragging and dropping APKs or double-click to install.
* [`register_context_menu.reg`](register_context_menu.reg): Adds "Install in MuMu Player (ADB)" to Windows Explorer right-click menu for `.apk` files.
* [`unregister_context_menu.reg`](unregister_context_menu.reg): Unregisters the right-click context menu.
* [`hosts`](hosts): Standalone blocklist file for Android's `/system/etc/hosts`.
* [`.gitignore`](.gitignore): Excludes binary blobs (`*.apk`, `*.jar`, `*.key`), local backups, and debug logs from Git.
