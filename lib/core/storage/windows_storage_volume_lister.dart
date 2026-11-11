import 'dart:io';

import '../common/app_logger.dart';
import 'storage_volume_info.dart';
import 'storage_volume_lister.dart';

/// Windows 盘符枚举。
///
/// 卷一律 [StorageVolumeInfo.isPrimary]=false，以便现有安卓客户端（过滤主卷）仍能看见全盘。
class WindowsStorageVolumeLister implements StorageVolumeLister {
  @override
  Future<List<StorageVolumeInfo>> list() async {
    final out = <StorageVolumeInfo>[];
    for (var code = 65; code <= 90; code++) {
      final letter = String.fromCharCode(code);
      final root = '$letter:\\';
      try {
        final dir = Directory(root);
        if (!await dir.exists()) continue;
        var writable = true;
        try {
          await dir.list(followLinks: false).take(1).toList();
        } catch (_) {
          writable = false;
        }
        out.add(
          StorageVolumeInfo(
            path: root,
            description: '本地磁盘 ($letter:)',
            isPrimary: false,
            isRemovable: false,
            writable: writable,
            state: 'mounted',
          ),
        );
      } catch (_) {}
    }
    AppLogger.log(
      'StorageVolumes.list windows',
      scope: 'extvol',
      details: {
        'count': out.length,
        'paths': [for (final v in out) v.path],
      },
    );
    return out;
  }
}
