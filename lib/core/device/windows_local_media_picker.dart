import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;

import '../storage/mime_types.dart';
import 'local_media_models.dart';

/// Windows 系统文件多选 / 文件夹媒体扫描。
class WindowsLocalMediaPicker {
  const WindowsLocalMediaPicker();

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
    '.avi',
    '.3gp',
  };

  Future<LocalMediaPickResult> pickMediaFiltered({
    int maxAssets = 500,
    required bool includeImages,
    required bool includeVideos,
  }) async {
    final typeGroups = <XTypeGroup>[
      if (includeImages)
        const XTypeGroup(
          label: 'images',
          extensions: <String>['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'],
        ),
      if (includeVideos)
        const XTypeGroup(
          label: 'videos',
          extensions: <String>['mp4', 'mkv', 'webm', 'mov', 'avi', '3gp'],
        ),
    ];
    final files = typeGroups.isEmpty
        ? await openFiles()
        : await openFiles(acceptedTypeGroups: typeGroups);
    if (files.isEmpty) {
      return const LocalMediaPickResult(items: <PickedLocalMediaItem>[]);
    }
    final items = <PickedLocalMediaItem>[];
    var unavailable = 0;
    for (final x in files.take(maxAssets)) {
      final file = File(x.path);
      if (!await file.exists()) {
        unavailable += 1;
        continue;
      }
      final name = p.basename(x.path);
      items.add(
        PickedLocalMediaItem(
          id: '',
          localPath: x.path,
          displayName: name,
          size: await file.length(),
          mimeType: MimeTypes.fromFileName(name),
        ),
      );
    }
    return LocalMediaPickResult(
      items: List.unmodifiable(items),
      unavailableCount: unavailable,
    );
  }

  /// 递归扫描目录，收集图片 / 视频。
  Future<LocalMediaPickResult> scanDirectory(
    String directoryPath, {
    required bool includeImages,
    required bool includeVideos,
    bool Function()? shouldCancel,
    void Function(LocalMediaScanProgress progress)? onProgress,
  }) async {
    if (!includeImages && !includeVideos) {
      return const LocalMediaPickResult(items: <PickedLocalMediaItem>[]);
    }
    final root = Directory(directoryPath);
    if (!await root.exists()) {
      return const LocalMediaPickResult(items: <PickedLocalMediaItem>[]);
    }

    final items = <PickedLocalMediaItem>[];
    var scanned = 0;
    var unavailable = 0;

    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (!mediaScanShouldContinue(shouldCancel: shouldCancel)) break;
      if (entity is! File) continue;
      scanned += 1;
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue;
      final ext = p.extension(name).toLowerCase();
      final isImage = _imageExt.contains(ext);
      final isVideo = _videoExt.contains(ext);
      if ((includeImages && isImage) || (includeVideos && isVideo)) {
        try {
          final st = await entity.stat();
          if (st.size <= 0) {
            unavailable += 1;
            continue;
          }
          items.add(
            PickedLocalMediaItem(
              id: p.normalize(entity.path),
              localPath: entity.path,
              displayName: name,
              size: st.size,
              mimeType: MimeTypes.fromFileName(name),
              modifiedAt: st.modified,
            ),
          );
        } catch (_) {
          unavailable += 1;
        }
      }
      onProgress?.call(
        LocalMediaScanProgress(
          scannedAssets: scanned,
          totalAssets: scanned,
          discoveredItems: items.length,
          unavailableCount: unavailable,
        ),
      );
    }

    items.sort(
      (a, b) => (b.modifiedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(a.modifiedAt ?? DateTime.fromMillisecondsSinceEpoch(0)),
    );
    return LocalMediaPickResult(
      items: List.unmodifiable(items),
      unavailableCount: unavailable,
    );
  }
}
