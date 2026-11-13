/// HTTP Content-Disposition（RFC 6266 / RFC 8187）。
///
/// dart:io [HttpHeaders] 拒绝非 ASCII 头值；中文/日文文件名必须百分号编码进
/// `filename*`，不可直接写入 `filename="…"`.
abstract final class ContentDisposition {
  /// 在线预览 / Range 播流：不带 filename（播放不依赖保存名）。
  static const String inline = 'inline';

  /// 强制下载：仅 `filename*=UTF-8''…`（业界常用，头值全程 ASCII）。
  static String attachment(String fileName) {
    final base = _basename(fileName);
    final name = base.isEmpty ? 'download' : base;
    return "attachment; filename*=UTF-8''${Uri.encodeComponent(name)}";
  }

  static String _basename(String fileName) {
    final n = fileName.trim().replaceAll('\\', '/');
    if (n.isEmpty) return '';
    final i = n.lastIndexOf('/');
    return i < 0 ? n : n.substring(i + 1);
  }
}
