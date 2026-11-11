import 'storage_volume_info.dart';
import 'storage_volume_lister.dart';

export 'storage_volume_info.dart';

/// 本机卷列表门面（实现按平台注入）。
class StorageVolumes {
  StorageVolumes({StorageVolumeLister? lister})
      : _lister = lister ?? StorageVolumeLister.create();

  final StorageVolumeLister _lister;

  Future<List<StorageVolumeInfo>> list() => _lister.list();
}
