import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../storage/mime_types.dart';
import 'device_file_service.dart';
import 'local_media_picker.dart';

/// 统一本地选取结果（聊天互传 / NAS 上传共用）。
class LocalPickFacadeResult {
  const LocalPickFacadeResult({
    required this.items,
    this.unavailableCount = 0,
  });

  final List<PickedLocalMediaItem> items;
  final int unavailableCount;

  bool get isEmpty => items.isEmpty;
}

/// 本地选文件门面：系统媒体筛选 + 任意文件（file_picker / file_selector）。
///
/// 禁止 `withData: true`；调用方按 [PickedLocalMediaItem.localPath] 流式读取。
class LocalPickFacade {
  LocalPickFacade({
    DeviceFileService? deviceFiles,
    LocalMediaPicker? mediaPicker,
  })  : _deviceFiles = deviceFiles ?? DeviceFileService(),
        _mediaPicker = mediaPicker ?? const LocalMediaPicker();

  final DeviceFileService _deviceFiles;
  final LocalMediaPicker _mediaPicker;

  /// 相册多选（图+视频）。
  Future<LocalPickFacadeResult> pickMedia(
    BuildContext context, {
    int maxAssets = 500,
  }) async {
    final result = await _mediaPicker.pickMedia(context, maxAssets: maxAssets);
    return LocalPickFacadeResult(
      items: result.items,
      unavailableCount: result.unavailableCount,
    );
  }

  /// 系统文件选择器多选（任意类型，仅 path）。
  Future<LocalPickFacadeResult> pickFiles() async {
    final paths = await _deviceFiles.pickUploadFiles();
    if (paths.isEmpty) {
      return const LocalPickFacadeResult(items: []);
    }

    final items = <PickedLocalMediaItem>[];
    var unavailable = 0;
    for (final path in paths) {
      final file = File(path);
      if (!await file.exists()) {
        unavailable += 1;
        continue;
      }
      final name = p.basename(path);
      items.add(
        PickedLocalMediaItem(
          // 非相册选取：无 MediaStore id（勿把 path 冒充 id）。
          id: '',
          localPath: path,
          displayName: name,
          size: await file.length(),
          mimeType: MimeTypes.fromFileName(name),
        ),
      );
    }
    return LocalPickFacadeResult(
      items: List.unmodifiable(items),
      unavailableCount: unavailable,
    );
  }
}
