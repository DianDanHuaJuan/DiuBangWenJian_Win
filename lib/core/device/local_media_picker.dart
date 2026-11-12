import 'package:flutter/material.dart';

import 'local_media_models.dart';
import 'windows_local_media_picker.dart';

export 'local_media_models.dart';

/// 本地媒体多选门面（Windows：系统文件选择器 / 文件夹扫描）。
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

  /// 递归扫描文件夹内图片 / 视频（定案 Q16：备份源为用户自选文件夹）。
  Future<LocalMediaPickResult> loadMediaFromDirectory(
    String directoryPath, {
    required bool includeImages,
    required bool includeVideos,
    bool Function()? shouldCancel,
    void Function(LocalMediaScanProgress progress)? onProgress,
  }) {
    return const WindowsLocalMediaPicker().scanDirectory(
      directoryPath,
      includeImages: includeImages,
      includeVideos: includeVideos,
      shouldCancel: shouldCancel,
      onProgress: onProgress,
    );
  }
}
