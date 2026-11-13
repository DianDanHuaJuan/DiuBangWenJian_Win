import 'app_paths.dart';

/// Windows 系统保护目录：列表可显示，进入前由目录树拦截并弹窗。
bool isWindowsSensitiveDirectory({
  required String name,
  String? absolutePath,
}) {
  final trimmed = name.trim();
  if (_classicSensitiveNames.contains(trimmed)) {
    if (absolutePath == null || absolutePath.trim().isEmpty) {
      // 卷根列表无绝对路径时，按经典名拦截。
      return true;
    }
    return _isDirectlyUnderDriveRoot(absolutePath);
  }
  return _isUnderUsersAppData(absolutePath);
}

const _classicSensitiveNames = <String>{
  'Windows',
  'Program Files',
  'Program Files (x86)',
  'ProgramData',
  r'$Recycle.Bin',
  'System Volume Information',
};

/// `C:/Windows`、`D:\Program Files` 等「盘符根下一级」。
bool _isDirectlyUnderDriveRoot(String absolutePath) {
  final portable = AppPaths.portable(absolutePath);
  if (portable.length < 3) return false;
  final drive = portable.substring(0, 2);
  if (!RegExp(r'^[A-Za-z]:$').hasMatch(drive)) return false;
  final rest = portable.length > 2 && portable[2] == '/'
      ? portable.substring(3)
      : portable.substring(2);
  if (rest.isEmpty) return false;
  // 仅盘符根下一级目录名匹配才拦；深层同名不拦。
  final slash = rest.indexOf('/');
  final segment = slash < 0 ? rest : rest.substring(0, slash);
  if (slash >= 0 && slash < rest.length - 1) {
    // 已进入子路径（如 C:/Windows/System32）——仍视为敏感树内。
    return _classicSensitiveNames.contains(segment);
  }
  return _classicSensitiveNames.contains(segment);
}

/// `X:/Users/<name>/AppData` 及其子路径。
bool _isUnderUsersAppData(String? absolutePath) {
  if (absolutePath == null || absolutePath.trim().isEmpty) return false;
  final portable = AppPaths.portable(absolutePath);
  final match = RegExp(
    r'^[A-Za-z]:/Users/[^/]+/AppData(?:/|$)',
    caseSensitive: false,
  );
  return match.hasMatch(portable);
}
