import 'dart:io';
import 'dart:typed_data';

import 'windows_file_thumbnail_backend.dart';

/// 文件路径缩略图后端（Windows：Dart 解码 + ffmpeg）。
abstract class FileThumbnailBackend {
  Future<Uint8List?> imageThumb(File file, int maxPx);

  Future<Uint8List?> videoThumb(File file, int maxPx);

  static FileThumbnailBackend create() => WindowsFileThumbnailBackend();
}
