import 'package:path/path.dart' as p;

/// 扩展名 → MIME（扫描 / HTTP Content-Type / 选文件共用）。
abstract final class MimeTypes {
  /// 未知扩展名返回 null。
  static String? fromFileName(String name) {
    final ext = p.extension(name).toLowerCase();
    return switch (ext) {
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.png' => 'image/png',
      '.gif' => 'image/gif',
      '.webp' => 'image/webp',
      '.bmp' => 'image/bmp',
      '.heic' || '.heif' => 'image/heic',
      '.mp4' => 'video/mp4',
      '.mkv' => 'video/x-matroska',
      '.avi' => 'video/x-msvideo',
      '.mov' => 'video/quicktime',
      '.webm' => 'video/webm',
      '.3gp' => 'video/3gpp',
      '.mp3' => 'audio/mpeg',
      '.m4a' => 'audio/mp4',
      '.aac' => 'audio/aac',
      '.wav' => 'audio/wav',
      '.ogg' => 'audio/ogg',
      '.flac' => 'audio/flac',
      _ => null,
    };
  }

  /// HTTP 等需要必定有类型时用。
  static String fromFileNameOrOctet(String name) =>
      fromFileName(name) ?? 'application/octet-stream';
}
