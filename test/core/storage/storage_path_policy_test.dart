import 'package:flutter_test/flutter_test.dart';

import 'package:diubangwenjian/core/storage/storage_path_policy.dart';
import 'package:diubangwenjian/core/storage/storage_volumes.dart';

class _FakeVolumes extends StorageVolumes {
  _FakeVolumes(this.vols);
  final List<StorageVolumeInfo> vols;

  @override
  Future<List<StorageVolumeInfo>> list() async => vols;
}

void main() {
  test('内置 emulated 路径允许扫进媒体库', () async {
    final vols = _FakeVolumes([
      const StorageVolumeInfo(
        path: '/storage/emulated/0',
        description: '内部',
        isPrimary: true,
        isRemovable: false,
        writable: true,
      ),
      const StorageVolumeInfo(
        path: '/storage/XXXX-YYYY',
        description: 'U盘',
        isPrimary: false,
        isRemovable: true,
        writable: true,
      ),
    ]);
    final path = '/storage/emulated/0/Download/diubangfiles/inbox/a/b.jpg';
    expect(await isRemovableStoragePath(path, volumes: vols), isFalse);
    expect(await shouldScanIntoMediaStore(path, volumes: vols), isTrue);
  });

  test('OTG 卷路径禁止扫进媒体库', () async {
    final vols = _FakeVolumes([
      const StorageVolumeInfo(
        path: '/storage/XXXX-YYYY',
        description: 'U盘',
        isPrimary: false,
        isRemovable: true,
        writable: true,
      ),
    ]);
    final path = '/storage/XXXX-YYYY/diubangfiles/inbox/a/b.jpg';
    expect(await isRemovableStoragePath(path, volumes: vols), isTrue);
    expect(await shouldScanIntoMediaStore(path, volumes: vols), isFalse);
  });
}
