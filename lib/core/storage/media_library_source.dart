import 'dart:io';
import 'dart:typed_data';

import 'media_library_models.dart';
import 'windows_folder_media_library_source.dart';

/// 媒体墙数据源（Windows：指定根扫描）。
abstract class MediaLibrarySource {
  Future<List<MediaLibraryAsset>> listAll();

  Future<Uint8List?> readBytes(
    MediaLibraryAsset asset, {
    int? rangeStart,
    int? rangeEnd,
  });

  Future<Uint8List?> thumbnailFor(MediaLibraryAsset asset, {int maxPx = 256});

  Future<bool> deleteAsset(MediaLibraryAsset asset);

  static MediaLibrarySource create({
    Future<Directory?> Function()? resolveScanRoot,
  }) {
    return WindowsFolderMediaLibrarySource(resolveScanRoot: resolveScanRoot);
  }
}
