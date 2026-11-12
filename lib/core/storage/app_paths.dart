import 'package:path/path.dart' as p;

/// 路径铁律：协议用 Portable（永远 `/`），磁盘 I/O 用 Native；只在边界转换。
///
/// - **PortablePath**：JSON / Map key / `relativePath` / URL query / `rootId` 后缀
/// - **NativePath**：仅 `File` / `Directory` / Win32
///
/// 禁止把 `D:\foo\bar.jpg` 当作协议 `relativePath` 下发或查表。
abstract final class AppPaths {
  static final p.Context _posix = p.Context(style: p.Style.posix);

  /// 协议层归一：统一 `/`，盘符大写，盘符根为 `C:/`。
  ///
  /// 兼容输入：`C:\a\b`、`C:/a/b`、`C:`、`C`、`/C:/a`、`photos\x.jpg`。
  static String portable(String path) {
    var n = path.trim();
    if (n.isEmpty) return n;
    n = n.replaceAll('\\', '/');

    // Android Uri 可能把 opaque id 变成 `/C:/...`。
    final leadingDrive = RegExp(r'^/+([A-Za-z])(:.*)?$').firstMatch(n);
    if (leadingDrive != null) {
      n = '${leadingDrive.group(1)!.toUpperCase()}${leadingDrive.group(2) ?? ':'}';
    }

    if (RegExp(r'^[A-Za-z]$').hasMatch(n)) {
      n = '${n.toUpperCase()}:';
    }

    final drive = RegExp(r'^([A-Za-z]):(.*)$').firstMatch(n);
    if (drive != null) {
      final letter = drive.group(1)!.toUpperCase();
      var rest = drive.group(2) ?? '';
      if (rest.isEmpty || rest == '/') {
        return '$letter:/';
      }
      if (!rest.startsWith('/')) {
        rest = '/$rest';
      }
      rest = _posix.normalize(rest);
      if (rest == '.' || rest == '/') {
        return '$letter:/';
      }
      if (!rest.startsWith('/')) {
        rest = '/$rest';
      }
      return '$letter:$rest';
    }

    // UNC：保留 `//server/share/...`
    if (n.startsWith('//')) {
      final body = n.replaceFirst(RegExp(r'^/+'), '');
      final normalizedBody = _posix.normalize(body);
      if (normalizedBody == '.' || normalizedBody.isEmpty) {
        return '//';
      }
      return '//$normalizedBody';
    }

    final normalized = _posix.normalize(n);
    if (normalized == '.') return '';
    return normalized;
  }

  /// 仅用于 File / Directory：本机分隔符；盘符根为 `C:\`（Windows）。
  static String native(String path) {
    final port = portable(path);
    if (port.isEmpty) return port;
    if (RegExp(r'^[A-Z]:/$').hasMatch(port)) {
      return '${port[0]}:\\';
    }
    if (port.startsWith('//')) {
      // UNC → \\server\share\...
      return r'\\' + port.substring(2).replaceAll('/', r'\');
    }
    return port.replaceAll('/', p.separator);
  }

  /// 协议层 join（结果仍是 `/`）。
  static String joinPortable(String part1, [String? part2, String? part3]) {
    final a = portable(part1);
    if (part2 == null) return a;
    final b = portable(part2);
    if (b.isEmpty) return a;
    if (a.isEmpty) return b;
    // 盘符根 `C:/` + `Users` → `C:/Users`
    if (RegExp(r'^[A-Z]:/$').hasMatch(a)) {
      final child = b.startsWith('/') ? b.substring(1) : b;
      return portable('$a$child');
    }
    if (part3 != null) {
      return portable(_posix.join(a, b, portable(part3)));
    }
    return portable(_posix.join(a, b));
  }

  /// 相对路径（POSIX 风格）。
  static String relativePortable(String from, String to) {
    final rel = _posix.relative(portable(to), from: portable(from));
    return portable(rel);
  }

  /// 比较（协议相等）：斜杠归一 + 大小写不敏感（Windows 盘符/路径）。
  static bool equals(String a, String b) =>
      portable(a).toLowerCase() == portable(b).toLowerCase();

  /// 是否 Windows 盘符根（`C:` / `C:/` / `C:\`）。
  static bool isWindowsDriveRoot(String path) {
    final n = portable(path);
    return RegExp(r'^[A-Z]:/$').hasMatch(n);
  }

  /// [child] 是否落在 [root] 下（含相等）。两端先 portable。
  static bool isWithinPortable(String root, String child) {
    final r = portable(root);
    final c = portable(child);
    if (r.isEmpty || c.isEmpty) return false;
    if (equals(r, c)) return true;
    final prefix = r.endsWith('/') ? r : '$r/';
    return c.toLowerCase().startsWith(prefix.toLowerCase());
  }

  /// 查表用的一组等价键（旧客户端可能仍带 `\` 或绝对路径）。
  static Set<String> lookupKeys(String path) {
    final raw = path.trim();
    if (raw.isEmpty) return const {};
    final port = portable(raw);
    return {
      raw,
      port,
      raw.replaceAll('\\', '/'),
      raw.replaceAll('/', '\\'),
      port.replaceAll('/', '\\'),
    };
  }
}
