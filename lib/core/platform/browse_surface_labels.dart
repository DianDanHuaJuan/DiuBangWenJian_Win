import 'app_platform.dart';

/// 文件页拨码文案（Android：系统/外置；Windows：当前目录/全盘）。
abstract final class BrowseSurfaceLabels {
  static String get local => AppPlatform.isWindows ? '当前目录' : '系统';

  static String get external => AppPlatform.isWindows ? '全盘' : '外置';
}
