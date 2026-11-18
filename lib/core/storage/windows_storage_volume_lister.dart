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
      // 对外统一 `C:/`，避免 `C:\` 在 URL/rootId 与比较时踩坑。
      final root = '$letter:/';
      try {
        final dir = Directory('$letter:\\');
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
            // 对安卓客户端：isPrimary=false 且 isRemovable=true 才会当「外置」展示/进入。
            isPrimary: false,
            isRemovable: true,
            writable: writable,
            state: 'mounted',
          ),
        );
      } catch (_) {}
    }
    AppLogger.logVerbose(
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
