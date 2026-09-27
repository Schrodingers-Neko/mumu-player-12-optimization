# MuMu 模拟器 12 (Android 15) 深度优化、去广告与官方 Lawnchair 15 替换指南

[简体中文](README.md) | [English](README_EN.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/平台-Windows%20%7C%20Android%2015-success.svg)](README.md)
[![MuMu Player](https://img.shields.io/badge/MuMu%20模拟器-12%20(Android%2015)-orange.svg)](https://mumu.163.com/)
[![Launcher](https://img.shields.io/badge/桌面-官方%20Lawnchair%2015-brightgreen.svg)](https://github.com/LawnchairLauncher/lawnchair)
[![Root](https://img.shields.io/badge/Root-KernelSU-red.svg)](https://github.com/tiann/KernelSU)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207%2B-blue.svg)](README.md)

## 项目概述

本项目深入剖析网易 **MuMu 模拟器 12** 的 **Android 15** 引擎底层架构，系统性记录了预装臃肿软件、后台广告组件、宿主机扫描与网络遥测行为，并提供了一整套全自动化的去广告、千兆网桥调优及官方 **Lawnchair 15** 桌面替换方案。

彻底解决替换桌面后开机卡在“正在启动手机...”的冷启动死循环问题。

### 脚本前置条件与结果校验

所有脚本兼容 Windows PowerShell 5.1 和 PowerShell 7。请将 `mumu_common.ps1` 与脚本放在同一目录；安装位置不是默认的 `D:\Program Files\Netease\MuMu Player 12` 时，请传入 `-MumuInstallDir`。`-VmIndex` 指定 Android 15 实例。脚本会检查实例身份及连接，不猜测 ADB 端口，也不会将网桥实例回退到 NAT。

运行去广告脚本**之前**，请先安装 HeliBoard（`helium314.keyboard/.latin.LatinIME`）。脚本会先检查、启用并设为默认输入法，再停用软件包。如果激活失败，Sogou 保持启用，并停止软件包、hosts 和 Windows 清理操作。只有去广告脚本会自动启动尚未运行的实例，启动超过 75 秒即报错；安装 APK、替换或还原桌面前，请自行启动实例。需要特权的脚本还会校验 root 权限。

替换桌面要求 PATH 中有 Java、本地存在 `uber-apk-signer.jar`，以及**已完成平台重签名**的 `Lawnchair.15.0.0.Beta.3.0-aligned-signed.apk`。请按照[优化指南](MUMU_OPTIMIZATION_GUIDE.md)下载并重签名。脚本会在连接模拟器之前，对照 `platform.x509.pem` 校验证书，不会自动重签名，也不会使用原始上游 APK 作为备用文件。

```powershell
.\replace_lawnchair.ps1 -VmIndex 1 -MumuInstallDir "C:\Program Files\Netease\MuMu Player 12" `
    -SignedApkPath ".\Lawnchair.15.0.0.Beta.3.0-aligned-signed.apk" -SignerJarPath ".\uber-apk-signer.jar"
.\mumu_debloater.ps1 -VmIndex 1 -MumuInstallDir "C:\Program Files\Netease\MuMu Player 12"
.\restore_lawnchair.ps1 -VmIndex 1 -MumuInstallDir "C:\Program Files\Netease\MuMu Player 12"
```

原桌面按实例备份到 `backup/vm-<index>/Lawnchair_mumu_original.apk`；旧的共享备份仅允许用于实例 1 的还原。上传的 APK 和 hosts 文件都会校验哈希。还原脚本会在卸载之前确认原厂 APK 或备份可用，先解除挂载再移除模块，并在还原后清除桌面设置和布局。脚本不会自动修复旧的 scratch 分区损坏。桌面操作最多等待 90 秒确认 Android/PackageManager 就绪，再等待 30 秒确认 HOME 角色及桌面进程。任何必要步骤失败都会停止后续操作并返回退出码 `1`；已完成的步骤不会自动回滚。APK 安装同时要求 ADB 退出码为 `0` 且输出 `Success`。取消文件选择返回 `0`；批处理入口保留安装脚本的退出码，并支持含空格、`&` 和 `!` 的文件名。

运行不接触真实模拟器、无需额外测试框架的隔离回归检查：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run.ps1
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run.ps1
```

---

## 1. 运行环境与系统架构

| 参数项 | 参数值 | 说明 |
| :--- | :--- | :--- |
| **MuMu 内核版本** | `6.8.1.0` (MuMu 6.0 体系) | 基于 Qt5 + Chromium Embedded Framework (CEF) 构建的 Windows 客户端 |
| **Android 版本** | **Android 15** (`vanillaicecream`, API 级别 35) | 6.1.90-perf+ 内核，x86_64 纯 64 位原生架构 |
| **底层虚拟化引擎** | VirtualBox 7.2.4 (网易定制版: `nemu-vbox7`) | 由 `nemu-vboxmanager.dll` 管理的无头（Headless）虚拟机后端 |
| **模拟器安装路径** | `<MUMU_DIR>`（默认为 `C:\Program Files\Netease\MuMu Player 12\`） | Android 15 相关运行时组件位于 `nx_device\15.0\` |
| **虚拟机镜像目录** | `<MUMU_DIR>\vms\MuMuPlayer-15.0-<VM_INDEX>\` | 包含 `data.vdi` (用户数据), `system.vdi` (系统只读底包), `system-diff.vdi` |
| **Root 方案** | 原生 KernelSU (`me.weishu.kernelsu`) & Magisk | 系统分区通过 overlayfs 挂载实现可写 (`/mnt/scratch/upperdir`) |

---

## 2. MuMu CLI 与 ADB 连接机制

MuMu 模拟器 12 自带功能完备的命令行工具：
```text
<MUMU_DIR>\nx_main\mumu-cli.exe
# 默认路径：C:\Program Files\Netease\MuMu Player 12\nx_main\mumu-cli.exe
```

### 常用 CLI 命令
```powershell
# 列出所有虚拟机实例、安卓版本、运行状态及分配的 ADB 端口
.\mumu-cli.exe info -v all

# 启动或重启指定虚拟机（如实例 1 = Android 15）
.\mumu-cli.exe control -v 1 launch
.\mumu-cli.exe control -v 1 restart

# 导出指定实例的所有硬件、渲染器与网络配置
.\mumu-cli.exe setting -v 1 -a

# 从 Windows 主机向模拟器静默安装 APK
.\mumu-cli.exe control -v 1 app install -apk "C:\Path\To\file.apk"
```

### 动态 ADB 端口分配与网络模式 (NAT vs. 网桥)

#### 模式 1：NAT 模式（默认）
* **端口映射**：VirtualBox 在用户态创建本地端口转发规则（`127.0.0.1:<分配的端口>` -> 虚拟机 `5555` 端口）。请查询所选实例，`16416` 仅为示例。
* **性能瓶颈**：由于依赖用户态 *Slirp* 软件套接字转发，存在极高的 CPU 上下文切换开销与较小的固定 TCP 窗口，网络吞吐量通常被限制在 **30–80 Mbps**。
* **ADB 连接命令**：
  ```powershell
  $vmInfo = & "<MUMU_DIR>\nx_main\mumu-cli.exe" info -v 1 | ConvertFrom-Json
  & "<MUMU_DIR>\nx_device\15.0\shell\adb.exe" connect "127.0.0.1:$($vmInfo.adb_port)"
  ```

#### 模式 2：网桥直连模式（推荐：跑满千兆 1 Gbps）
* **实现原理**：通过网易定制的 NDIS 过滤驱动（`nemu_net_bridge`），使虚拟机直接绑定到宿主机的物理网卡（二层数据链路层）。
* **网络接口**：物理宿主机网卡（如 Gigabit Ethernet 或 Wi-Fi）。
* **DHCP 与独立 IP**：
  * 虚拟机作为局域网内的独立物理设备存在，直接向家庭路由器申请独立内网 IP。
  * **内网租约**：由路由器动态分配（如 `192.168.1.x` / `10.0.0.x`）。
  * **MAC 地址**：每个实例生成固定硬件 MAC（记录在 `<MUMU_DIR>\vms\MuMuPlayer-15.0-<VM_INDEX>\macaddress` 中）。
* **吞吐与延迟**：彻底消除用户态 NAT 内存拷贝，跑满内网千兆（高达 1,000 Mbps），外网延迟低至 ~3.7 ms。
* **网桥模式下的 ADB 连接**：
  ```powershell
  & "<MUMU_DIR>\nx_device\15.0\shell\adb.exe" connect <VM_LAN_IP>:5555
  & "<MUMU_DIR>\nx_device\15.0\shell\adb.exe" -s <VM_LAN_IP>:5555 root
  ```
  *(注：开启网桥模式后，VirtualBox 会停用 `127.0.0.1:16416` 的 NAT 映射，请始终直连虚拟机的内网 IP)。*

#### 本仓库脚本中的动态自动探测
仓库中的 PowerShell 自动化脚本已集成双模式自适应逻辑：
1. 自动解析 `customer_config.json` 检查 `network_bridge_opened` 是否开启。
2. 自动读取 `vms\MuMuPlayer-15.0-<VM_INDEX>\macaddress` 提取目标 MAC 地址。
3. 根据 `network_current_bridge_card` 精确匹配 Windows 网卡，检查该网卡的邻居表，并用异步 .NET ping 探测其 IPv4 子网，最多 30 秒；兼容 PowerShell 5.1 和 7。
4. NAT 模式仅使用 `mumu-cli info -v <index>` 返回的 `adb_port`。缺少端口、网卡或 MAC 匹配不唯一、网桥 IP 未找到均报错，不会从网桥回退到 NAT。四个脚本共用此逻辑。

---

## 3. 预装应用、遥测与广告行为审计目录

### Android 15 系统内部组件

| 软件包名 | 软件类型 | 行为分析与系统影响 | 处理策略 |
| :--- | :--- | :--- | :--- |
| `advertising.id.ccpa.gdpr` | 系统工具 | 广告 ID 查询工具 | **保留** |
| `com.netease.mumu.cloner` | 系统工具 | MuMu 多开应用分身助手 | **保留** |
| `com.mumu.store` | 应用商店 / 广告 | MuMu 应用中心。后台推送推广应用、保持长连接并频繁请求推广接口 (`api.mumu.netease.com`) | **停用** (`pm disable-user --user 0`) |
| `com.mumu.shared.sdk` | 埋点 SDK | 网易神策 (SensorsData) 行为分析统计框架，拥有高系统权限 | **停用** (`pm disable-user --user 0`) |
| `com.mumu.acc` | 遥测 / VPN | “MuMu 加速器”后台服务，持续向网易服务器发送数据包 | **停用** (`pm disable-user --user 0`) |
| `com.nemu.oaidmanager` | 跟踪框架 | 中国移动安全联盟 OAID 设备唯一标识服务，用于跨应用广告追踪 | **停用** (`pm disable-user --user 0`) |
| `com.nemu.nlp` | 遥测 | Nemu 网络位置提供器定位服务 | **停用** (`pm disable-user --user 0`) |
| `com.nemu.googleinstaller` | 安装残留 | 谷歌服务框架初始安装引导器 | **卸载** (`pm uninstall`) |
| `com.sohu.inputmethod.sogou.chuizi` | 预装输入法 | 锤子定制版搜狗输入法，内置联网词库推荐与联想词数据回传 | **停用** (替换为 HeliBoard) |
| `com.android.chromium` | 冗余组件 | AOSP 基础内置浏览器壳 | **停用** (`pm disable-user --user 0`) |
| `com.android.camera2` | 冗余组件 | AOSP 原生相机应用 | **停用** (`pm disable-user --user 0`) |

### Windows 宿主机驻留行为

1. **宿主机运行进程扫描器 (`report_app_data_config.json`)**：
   * 路径：`%APPDATA%\Netease\MuMuPlayer\configs\report_app_data_config.json`。
   * MuMu 客户端会监控并记录宿主机上运行的软件列表（包括 TeamViewer、AnyDesk、Tailscale、ZeroTier、同类竞品模拟器以及游戏插件等）并上报。
   * *处置方案*：清空并替换为 `{}`，并设置 Windows **只读属性**。
2. **横幅广告图片缓存 (`ProgramAds`)**：
   * 路径：`%APPDATA%\Netease\MuMuPlayer\data\ProgramAds\`。
   * 客户端每次启动时自动从网易 CDN 拉取游戏营销图片（`image_*.png`）。
   * *处置方案*：删除缓存图片，清空 `programAds.json`，并设置 Windows **只读属性**。
3. **后台远程服务 (`MuMuRemoteService`)**：
   * Windows 系统服务，运行 `"<MUMU_DIR>\nx_main\MuMuRemoteService.exe" --service`。
   * 为“GameViewer 远程串流”提供后台服务端支持，模拟器完全关闭后仍默认常驻。
   * *处置方案*：若无需远程串流，可在管理员 PowerShell 中彻底禁用：
     ```powershell
     Stop-Service -Name "MuMuRemoteService" -Force
     Set-Service -Name "MuMuRemoteService" -StartupType Disabled
     ```

---

## 4. 极速 ADB 安装流水线

在停用 `com.mumu.store` 之后，APK 可以完全通过 ADB 原生管道高速安装：

### ADB 安装的底层优势
* `adb install -r -d -g <file.apk>` 直连 Android 内核的 `adbd`（Root 权限运行），直接驱动 AOSP 原生 `PackageManagerService`。
* 彻底摆脱模拟器应用商店的干扰与弹窗拦截，100% 成功率。
* 配合千兆网桥直连，大型游戏安装包（数 GB）秒级传输。

### 便捷安装方式

1. **Windows 右键菜单一键安装**：
   * 在 Windows 资源管理器中右键任意 `.apk` 文件，点击 **“Install in MuMu Player (ADB)”**。
   * 双击导入 [`register_context_menu.reg`](register_context_menu.reg) 即可注册（写入 `HKCU`，无需管理员权限）。
2. **拖拽到脚本一键安装**：
   * 将任意 `.apk` 文件拖拽放到 [`install_apk.bat`](install_apk.bat) 上即可静默安装。
3. **图形化文件选择器**：
   * 直接双击运行 [`install_apk.bat`](install_apk.bat)，若未附带参数会自动弹出 Windows 文件浏览窗口供选择。
4. **命令行 / PowerShell 批处理**：
   ```powershell
   .\install_apk.ps1 "C:\Path\To\app.apk"
   ```

---

## 5. 输入法替换方案：HeliBoard

由于搜狗输入法是唯一的内置输入法，若直接停用会导致系统缺失虚拟键盘输入法而无法打字。

* **推荐替换**：[HeliBoard](https://github.com/HeliBorg/HeliBoard) (`helium314.keyboard`)，一款完全开源、Material You 风格、彻底离线且无网络权限的隐私级输入法。
* **激活与切换命令**：
  ```bash
  adb shell ime enable helium314.keyboard/.latin.LatinIME
  adb shell ime set helium314.keyboard/.latin.LatinIME
  ```
* **停用原装搜狗输入法**：
  ```bash
  adb shell am force-stop com.sohu.inputmethod.sogou.chuizi
  adb shell pm disable-user --user 0 com.sohu.inputmethod.sogou.chuizi
  ```

---

## 6. DNS / Hosts 域名级黑名单

将以下规则写入 Android 系统的 `/system/etc/hosts`，实现对所有网易广告与遥测域名的空路由屏蔽（`0.0.0.0`）：

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

## 7. 桌面架构与官方 Lawnchair 15 替换方案

### 原装桌面分析
* **基础包**：**Lawnchair 15** (v15.0.0.6, 包名 `app.lawnchair`, 安装在 `/system/priv-app/Lawnchair/Lawnchair.apk`)。
* **上游来源**：Lawnchair 是基于谷歌 AOSP Launcher3 (Pixel 启动器) 的知名开源桌面。
* **网易定制修改**：网易在原版基础上反编译注入了自家的广告模块 (`com.mumu.core.ad.*`, `com.mumu.core.search.*`)，并在主布局顶部硬编码了不可移除的搜索栏 (`res/layout/mumu_search_bar_view.xml`, View ID: `app:id/mumu_search_bar`)。
* **为什么顶部搜索栏会失效假死**：
  搜索栏点击后会向 `com.mumu.store` 发送搜索 Intent。在停用应用商店后，点击搜索栏无任何响应，成为桌面上挥之不去的牛皮癣。

### 冷启动卡死在“正在启动手机...”的成因与修复

若直接将官方发布的 `Lawnchair 15 Beta 3` APK 覆盖进 `/system/priv-app/`，冷启动时系统会发生死循环并报 `"Lawnchair keeps stopping"`。

经过底层逆向诊断，真正原因包含两个独立层面：

1. **系统权限与签名校验机制**：
   * Lawnchair 15 的 Quickstep 多任务手势组件在初始化时，必须读取 `@hide` 隐藏系统设置（`swipe_bottom_to_notification_enabled`）并持有 `MANAGE_ACTIVITY_TASKS` 权限。
   * Android 15 强制要求此类 API 必须具备 **平台系统签名 (Platform Signature)**。
   * MuMu 的系统镜像采用了公开的标准 **AOSP Platform Test Key**。官方 GitHub 下载的 APK 采用开发者私钥签名，导致系统抛出 `SecurityException` 崩溃。
   * **解决方案**：使用 AOSP 平台测试证书对官方 Lawnchair 15 进行**二次重签名**。
2. **底层 Overlayfs 索引节点损坏与 Vold 卸载机制**：
   * MuMu 的系统分区采用 overlayfs 机制（可写层位于 `sda8` 的 `/mnt/scratch/upperdir/`）。
   * 直接向 `/system/priv-app/` 写入文件或使用 `rm -rf .../oat` 删除目录，会在底层产生 whiteout 白化设备节点 (`c 0 0`) 并打上 `trusted.overlay.impure="y"` 扩展属性。
   * Android 开机早期，`vold` 守护进程会卸载 `/mnt/scratch`。此时非 root 进程（`system_server`, `uid=1000`）在 `stat()` 查询 `/system/priv-app/Lawnchair` 时会触发内核级 `EPERM`（无权限），导致 `PackageManagerService` 忽略该桌面并无限回退到系统的 `FallbackHome`。
   * **解决方案**：采用 **KernelSU `post-fs-data.d` 早期挂载** (`mount -o bind`)。在 PID 1 初始化阶段、PMS 扫描之前完成无损注入，完全不污染 `sda8` scratch 分区，冷启动 100% 稳定秒开。

### 自动化替换步骤

按照优化指南完成平台重签名后，再运行替换脚本。请使用签名工具生成的 `-aligned-signed.apk` 文件：
```powershell
.\replace_lawnchair.ps1 -VmIndex 1 -SignedApkPath ".\Lawnchair.15.0.0.Beta.3.0-aligned-signed.apk"
```

**替换后的效果**：
- 顶部的网易广告搜索栏及后台追踪 SDK **100% 彻底清除**。
- 应用抽屉中的用户所有应用完整保留，按字母智能排序。
- 获得原生纯净的 Material 3 Pixel 风格桌面与全功能桌面设置（图标包、手势、底栏配置等）。
- 冷启动时间缩短至 **~6 秒**，无任何卡顿与闪退。

---

## 8. 开源工具推荐 (FOSS)

推荐搭配以下经过兼容性验证的优质开源工具，打造纯净的 Android 15 工作环境：

| 应用名称 | 软件包名 | 推荐版本 | 源码与下载地址 | 核心特性说明 |
| :--- | :--- | :--- | :--- | :--- |
| **Material Files** | `me.zhanghai.android.files` | `v1.7.5` | [GitHub Releases](https://github.com/zhanghai/MaterialFiles/releases) | 桌面级**双栏文件管理器**、KernelSU 原生 Root 浏览、内置解压缩 (`.zip`, `.7z`)、支持 Windows SMB 局域网共享。 |
| **Image 2 Wallpaper** | `com.shirobakama.wallpaper` | `v2.1.3` | [Google Play / F-Droid](https://github.com/shirobakama/Image2Wallpaper) | 壁纸精准对齐工具，支持 1:1 像素缩放、适应屏幕、无滚动锁定、横向铺满，彻底解决安卓桌面强制裁剪壁纸的问题。 |
| **Droid-ify** | `com.looker.droidify` | `v0.7.8` | [GitHub Releases](https://github.com/Droid-ify/client/releases) | 基于 Material You 设计的 F-Droid 第三方开源应用商店客户端，支持自动静默更新开源软件。 |
| **Termux** | `com.termux` | `v0.118.3` (x86_64) | [GitHub Releases](https://github.com/termux/termux-app/releases) | 原生 x86_64 架构 Linux 终端环境与 `pkg` 包管理器（内置 `python`, `git`, `curl` 等工具）。 |
| **VLC for Android** | `org.videolan.vlc` | `v3.7.1` (x86_64) | [VideoLAN / F-Droid](https://get.videolan.org/vlc-android/) | 原生 x86_64 硬件加速全能影音播放器，支持全格式音视频解码与局域网流媒体播放。 |

---

## 9. 仓库文件结构与使用指南

* [`README.md`](README.md)：简体中文使用说明与系统架构分析文档。
* [`README_EN.md`](README_EN.md)：English Documentation.
* [`MUMU_OPTIMIZATION_GUIDE.md`](MUMU_OPTIMIZATION_GUIDE.md)：技术深度指南，完整记录从零重签名、底层排错到去广告的全部步骤。
* [`replace_lawnchair.ps1`](replace_lawnchair.ps1)：全自动脚本，基于 KernelSU `post-fs-data.d` 挂载官方签名版 Lawnchair 15 Beta 3。
* [`restore_lawnchair.ps1`](restore_lawnchair.ps1)：验证原厂 APK 或备份后解除挂载并移除模块，恢复出厂桌面；会清除桌面设置和布局。
* [`mumu_debloater.ps1`](mumu_debloater.ps1)：一键去广告脚本，停用网易内置遥测、应用中心、加速器及宿主机扫描器。
* [`mumu_common.ps1`](mumu_common.ps1)：共享的实例解析、外部命令检查、哈希/签名验证及输入法/桌面就绪检查。
* [`tests/run.ps1`](tests/run.ps1)：使用假的 CLI、ADB 和 Java 进程，在两种 PowerShell 环境下运行隔离回归检查。
* [`install_apk.ps1`](install_apk.ps1)：极速 ADB 应用安装脚本，支持图形化选择器与网桥智能路由。
* [`install_apk.bat`](install_apk.bat)：Windows 批处理拖拽安装入口。
* [`register_context_menu.reg`](register_context_menu.reg)：向 Windows 资源管理器添加“右键安装到 MuMu”上下文菜单。
* [`unregister_context_menu.reg`](unregister_context_menu.reg)：移除 Windows 右键安装菜单。
* [`hosts`](hosts)：内置去广告与遥测域名的 Android Hosts 屏蔽清单。
* [`LICENSE`](LICENSE)：MIT 开源许可证。
* [`.gitignore`](.gitignore)：排除安装包二进制文件（`*.apk`, `*.jar`, `*.key`）、本地备份及日志。

---

## 许可证 (License)

本项目采用 [MIT License](LICENSE) 开源许可证。
