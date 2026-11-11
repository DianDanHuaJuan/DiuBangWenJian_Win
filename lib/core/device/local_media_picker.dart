import 'package:flutter/material.dart';

import 'local_media_models.dart';
import 'windows_local_media_picker.dart';

export 'local_media_models.dart';

/// 本地媒体多选门面（Windows：系统文件选择器）。
class LocalMediaPicker {
  const LocalMediaPicker();

  Future<LocalMediaPickResult> pickMedia(
    BuildContext context, {
    int maxAssets = 500,
  }) {
    return pickMediaFiltered(
      context,
      maxAssets: maxAssets,
      includeImages: true,
      includeVideos: true,
    );
  }

  Future<LocalMediaPickResult> pickMediaFiltered(
    BuildContext context, {
    int maxAssets = 500,
    required bool includeImages,
    required bool includeVideos,
  }) {
    if (!includeImages && !includeVideos) {
      return Future.value(
        const LocalMediaPickResult(items: <PickedLocalMediaItem>[]),
      );
    }
    return const WindowsLocalMediaPicker().pickMediaFiltered(
      maxAssets: maxAssets,
      includeImages: includeImages,
      includeVideos: includeVideos,
    );
  }

  /// 备份等场景：Windows 无 MediaStore 全库枚举，返回空（改用文件夹选择）。
  Future<LocalMediaPickResult> loadAllMedia({
    bool Function()? shouldCancel,
    void Function(LocalMediaScanProgress progress)? onProgress,
  }) async {
    return const LocalMediaPickResult(items: <PickedLocalMediaItem>[]);
  }

  Future<LocalMediaPickResult> loadAllMediaFiltered({
    required bool includeImages,
    required bool includeVideos,
    bool Function()? shouldCancel,
    void Function(LocalMediaScanProgress progress)? onProgress,
  }) async {
    return const LocalMediaPickResult(items: <PickedLocalMediaItem>[]);
  }
}
