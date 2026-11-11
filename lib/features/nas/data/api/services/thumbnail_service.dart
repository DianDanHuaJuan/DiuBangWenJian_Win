import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../../../../core/storage/file_thumbnail_backend.dart';

/// 缩略图门面：按扩展名分发到平台后端。
class ThumbnailService {
  ThumbnailService({FileThumbnailBackend? backend})
      : _backend = backend ?? FileThumbnailBackend.create();

  final FileThumbnailBackend _backend;

  static const _imageExt = {
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.gif',
    '.bmp',
    '.heic',
  };
  static const _videoExt = {
    '.mp4',
    '.mkv',
    '.webm',
    '.mov',
    '.3gp',
    '.avi',
  };

  Future<Uint8List?> thumbnailFor(File file, {int maxPx = 256}) async {
    final ext = p.extension(file.path).toLowerCase();
    if (_imageExt.contains(ext)) {
      return _backend.imageThumb(file, maxPx);
    }
    if (_videoExt.contains(ext)) {
      return _backend.videoThumb(file, maxPx);
    }
    return null;
  }
}
