import 'dart:io';

/// 平台能力（本仓库为 Windows 桌面目标）。
class AppPlatform {
  AppPlatform._();

  static bool get isWindows => Platform.isWindows;

  static String get identifier => 'windows';

  static bool get supportsDesktopTray => isWindows;

  static bool get supportsLaunchAtStartup => isWindows;
}
