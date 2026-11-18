import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../common/app_logger.dart';
import '../protocol/thumb_image_tier.dart';
import '../../features/nas/data/api/services/thumbnail_service.dart';
import 'app_paths.dart';
import 'media_library_models.dart';
import 'media_library_source.dart';
import 'mime_types.dart';
import 'thumb_cache_store.dart';
import 'thumb_generation_gate.dart';
import 'thumb_pipeline.dart';

/// Windows：扫描指定共享根下的图片/视频/音频（定案：落盘根 = 墙根）。
class WindowsFolderMediaLibrarySource implements MediaLibrarySource {
  WindowsFolderMediaLibrarySource({
    this.resolveScanRoot,
    this.resolveThumbPipeline,
    ThumbnailService? thumbnails,
  }) : _thumbnails = thumbnails;

  final Future<Directory?> Function()? resolveScanRoot;

  /// 惰性取统一流水线（本机墙 / Handler 共用落盘与闸）。
  final ThumbPipeline? Function()? resolveThumbPipeline;

  final ThumbnailService? _thumbnails;

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
      if (ThumbCacheStore.isUnderThumbsDir(entity.path)) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue;
      final ext = p.extension(name).toLowerCase();
      final kind = _mediaKindForExt(ext);
      if (kind == null) continue;
      try {
        final st = await entity.stat();
        if (st.size <= 0) continue;
        // 对外 id 必须是 Portable 相对路径（永远 `/`）。
        final rel = AppPaths.relativePortable(rootPath, entity.path);
        if (rel.isEmpty || rel.startsWith('..')) continue;
        out.add(
          MediaLibraryAsset(
            id: rel,
            contentUri: '',
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
    final path = asset.absolutePath?.trim() ?? '';
    if (path.isEmpty) return null;
    final file = File(path);
    if (!await file.exists()) return null;

    final tier = maxPx >= ThumbImageTier.previewMaxPx
        ? ThumbImageTier.preview
        : ThumbImageTier.grid;
    final pipeline = resolveThumbPipeline?.call();
    if (pipeline != null) {
      final bytes = await pipeline.getOrGenerate(
        file: file,
        tier: tier,
        rootId: MediaLibraryIds.rootId,
        name: asset.relativePath,
        mtimeMs: asset.modifiedAtMs,
        sizeBytes: asset.sizeBytes,
        priority: ThumbGenPriority.remote,
      );
      AppLogger.log(
        'library thumbnailFor pipeline',
        scope: 'thumb_diag',
        details: {
          'rel': asset.relativePath,
          'tier': tier.wireName,
          'bytes': bytes?.length ?? 0,
        },
      );
      return bytes;
    }

    final svc = _thumbnails ?? ThumbnailService();
    final raw = await svc.thumbnailFor(file, maxPx: maxPx);
    AppLogger.log(
      'library thumbnailFor direct',
      scope: 'thumb_diag',
      details: {
        'rel': asset.relativePath,
        'abs': path,
        'maxPx': maxPx,
        'bytes': raw?.length ?? 0,
      },
    );
    return raw;
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
