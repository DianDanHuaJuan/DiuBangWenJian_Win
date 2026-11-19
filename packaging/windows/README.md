# Windows 安装包构建（分发）

本仓安装包流程对齐旧版 `DiuBangNASServer_Windows/packaging/windows`，但 **FFmpeg 不下载**：使用仓库内自编译裁剪版 `assets/ffmpeg.exe`（约 12 MB，LGPL + OpenH264），由 CMake / Inno 一并打进安装目录。

## 产物链路（ffmpeg 如何进安装包）

```
tool/build_ffmpeg_lgpl_wsl.sh   # 可选：WSL 交叉编译
        ↓
assets/ffmpeg.exe               # 构建机必备本地文件（无外网下载步骤）
        ↓
windows/CMakeLists.txt          # install(FILES ...) → Release 旁路
        ↓
build/windows/x64/runner/Release/ffmpeg.exe
        ↓
diubangwenjian.iss [Files]      # Source: Release\* → {app}\
        ↓
packaging/windows/output/DiuBangWenJian-Setup-<version>.exe
```

安装后用户目录内与主程序同级即有 `ffmpeg.exe`，缩略图抽帧 / HLS 转码直接调用，**不依赖系统 PATH、不联网拉取**。

> 与旧仓差异：旧仓 `tool/bootstrap_windows.ps1` 从 BtbN 拉 ~110 MB 全量 LGPL zip → `assets/ffmpeg.exe`（且 gitignore 该文件）。本仓已手编裁剪版，**禁止再走下载 bootstrap**；缺文件时构建脚本直接失败并提示放置本地 exe。

## 前置条件

| 项 | 说明 |
|----|------|
| Windows 10/11 x64 | 构建机与目标机 |
| Flutter + VS 2022 | `flutter doctor` 无 Windows 红叉；「使用 C++ 的桌面开发」 |
| Inno Setup 6 | [jrsoftware.org/isinfo.php](https://jrsoftware.org/isinfo.php)，需 `ISCC.exe` |
| `assets/ffmpeg.exe` | 自编译裁剪版；可用 `tool/build_ffmpeg_lgpl_wsl.sh` 在 WSL 重生 |
| （可选）`assets/vc_runtime/x64\` | 无 VS 的打机组可预置三枚 CRT DLL |

`media_kit`（libmpv / ANGLE）由 `pubspec` 的 `media_kit_libs_windows_video` 在 `flutter build` 时带入 Release，无需旧仓那套 media_kit bootstrap。

## 一键打安装包

在仓库根目录：

```powershell
.\packaging\windows\build_installer.ps1
```

脚本顺序：

1. 检查 `assets\ffmpeg.exe` 存在（不下载）
2. `flutter build windows --release`（注入版本 / git sha / 构建时间）
3. 同步 `app_icon.ico` 到 Release
4. `collect_vc_runtime.ps1` 部署 `vcruntime140*.dll` / `msvcp140.dll`
5. 校验 Release（含 `diubangwenjian.exe`、`ffmpeg.exe`、`app_icon.ico`、CRT）
6. `ISCC` 编译 `diubangwenjian.iss`

输出：`packaging\windows\output\DiuBangWenJian-Setup-<version>.exe`  
（`output/` 已在 `.gitignore`，勿提交安装包二进制。）

### 常用参数

```powershell
# Release 已有，只重打安装包
.\packaging\windows\build_installer.ps1 -SkipFlutterBuild

# 只出 Release 目录，不编 Setup（未装 Inno 时）
.\packaging\windows\build_installer.ps1 -SkipInstaller

# 仅冒烟校验 Release
.\packaging\windows\verify_bundle.ps1
```

## 手动分步（等价）

```powershell
# 1. 确认自编译 ffmpeg 在位
Test-Path .\assets\ffmpeg.exe   # 应为 True

# 2. Release
flutter build windows --release

# 3. CRT + 图标（也可直接跑 build_installer -SkipFlutterBuild）
.\packaging\windows\collect_vc_runtime.ps1 `
  -ReleaseDir .\build\windows\x64\runner\Release
Copy-Item .\windows\runner\resources\app_icon.ico `
  .\build\windows\x64\runner\Release\app_icon.ico -Force

# 4. Inno
& "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" `
  /DMyAppVersion=0.1.0 `
  /DMyAppVersionFull=0.1.0+1 `
  .\packaging\windows\diubangwenjian.iss
```

## 自编译 FFmpeg（缺文件或要升级时）

```bash
# WSL Ubuntu
bash /mnt/d/tmp/DiuBangWenJian_Windows/tool/build_ffmpeg_lgpl_wsl.sh
```

默认写出到 `assets/ffmpeg.exe`。配置要点：静态、LGPL、`libopenh264`、无 `libx264`、仅 HLS/缩略图所需编解码器（见脚本内 `configure`）。

**不要**用 BtbN/Gyan 的 GPL essentials 覆盖本文件，以免许可与体积策略回退。

## 安装包内容（相对 `{app}`）

| 内容 | 来源 |
|------|------|
| `diubangwenjian.exe` + `data\` | Flutter Release |
| `ffmpeg.exe` | `assets/ffmpeg.exe` → CMake install |
| `app_icon.ico` | `windows/runner/resources/` |
| `libmpv-2.dll` / ANGLE 等 | media_kit 插件 |
| `vcruntime140.dll` 等 | `collect_vc_runtime.ps1` |
| 开始菜单 / 可选桌面快捷方式 | `diubangwenjian.iss` `[Icons]`（绿标） |

卸载会结束 `diubangwenjian.exe` / `ffmpeg.exe`，删除 `{app}`，并清理开机自启注册表项 `铥棒文件`；**不删**用户共享数据目录。

## 分发前检查清单

- [ ] `verify_bundle.ps1` 通过（含 `ffmpeg.exe`）
- [ ] 干净 Win10/11 机安装 Setup，确认安装目录旁有 `ffmpeg.exe`
- [ ] 视频缩略图 / HLS 预览可用
- [ ] 托盘、开机自启、卸载干净
- [ ] 防火墙首次放行说明（若文档需要）

## 图标

| 用途 | 路径 |
|------|------|
| 源 PNG | `assets/icon/app_icon.png` |
| 窗口 / exe / 托盘 / Setup | `windows/runner/resources/app_icon.ico` |

```powershell
dart run flutter_launcher_icons
```
