import 'storage_volume_info.dart';
import 'windows_storage_volume_lister.dart';

/// 枚举本机可浏览卷（Windows：盘符）。
abstract class StorageVolumeLister {
  Future<List<StorageVolumeInfo>> list();

  static StorageVolumeLister create() => WindowsStorageVolumeLister();
}
