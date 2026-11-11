import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'media_library_models.dart';
import 'media_library_source.dart';
import 'mime_types.dart';

/// Windows：扫描指定共享根下的图片/视频/音频（定案：落盘根 = 墙根）。
class WindowsFolderMediaLibrarySource implements MediaLibrarySource {
  WindowsFolderMediaLibrarySource({this.resolveScanRoot});

  final Future<Directory?> Function()? resolveScanRoot;

  static const _imageExt = {
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.gif',
    '.bmp',
    '.heic',
    '.heif',
  };
  static const _videoExt = {
    '.mp4',
    '.mkv',
    '.webm',
    '.mov',
    '.3gp',
    '.avi',
  };
  static const _audioExt = {
    '.mp3',
    '.m4a',
    '.aac',
    '.wav',
    '.ogg',
    '.flac',
  };

  @override
  Future<List<MediaLibraryAsset>> listAll() async {
    final root = await resolveScanRoot?.call();
    if (root == null || !await root.exists()) return const [];
    final rootPath = p.normalize(root.path);
    final out = <MediaLibraryAsset>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue;
      final ext = p.extension(name).toLowerCase();
      final kind = _mediaKindForExt(ext);
      if (kind == null) continue;
      try {
        final st = await entity.stat();
        if (st.size <= 0) continue;
        out.add(
          MediaLibraryAsset(
            id: p.normalize(entity.path),
            contentUri: 'file://${entity.path}',
            displayName: name,
            sizeBytes: st.size,
            modifiedAtMs: st.modified.millisecondsSinceEpoch,
            mediaKind: kind,
            absolutePath: entity.path,
            mimeType: MimeTypes.fromFileNameOrOctet(name),
            bucketDisplayName: p.basename(rootPath),
          ),
        );
      } catch (_) {}
    }
    out.sort((a, b) => b.modifiedAtMs.compareTo(a.modifiedAtMs));
    return out;
  }

  @override
  Future<Uint8List?> readBytes(
    MediaLibraryAsset asset, {
    int? rangeStart,
    int? rangeEnd,
  }) async {
    final path = asset.absolutePath;
    if (path == null || path.isEmpty) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    if (rangeStart != null && rangeEnd != null) {
      final raf = await file.open();
      try {
        await raf.setPosition(rangeStart);
        final len = (rangeEnd - rangeStart + 1).clamp(0, 1 << 30);
        return await raf.read(len);
      } finally {
        await raf.close();
      }
    }
    return file.readAsBytes();
  }

  @override
  Future<Uint8List?> thumbnailFor(
    MediaLibraryAsset asset, {
    int maxPx = 256,
  }) async {
    // 媒体墙缩略图由 NAS ThumbnailService 经文件路径生成。
    return null;
  }

  @override
  Future<bool> deleteAsset(MediaLibraryAsset asset) async {
    final path = asset.absolutePath?.trim();
    if (path == null || path.isEmpty) return false;
    try {
      final file = File(path);
      if (!await file.exists()) return false;
      await file.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  String? _mediaKindForExt(String ext) {
    if (_imageExt.contains(ext)) return 'image';
    if (_videoExt.contains(ext)) return 'video';
    if (_audioExt.contains(ext)) return 'audio';
    return null;
  }
}
