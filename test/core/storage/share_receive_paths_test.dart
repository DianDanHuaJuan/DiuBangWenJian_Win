import 'package:flutter_test/flutter_test.dart';
import 'package:diubangwenjian/core/storage/backup_category.dart';
import 'package:diubangwenjian/core/storage/share_receive_paths.dart';
import 'package:diubangwenjian/core/storage/storage_root.dart';

void main() {
  StorageRoot root(String id) => StorageRoot(
        id: id,
        kind: StorageRootKind.path,
        uriOrPath: r'C:\data',
        displayName: 'test',
        addedAtMs: 1,
      );

  test('有 directory 时始终用当前目录', () {
    expect(
      ShareReceivePaths.relativeDirForReceive(
        root: root('default_1'),
        directory: '工作/2024',
        fileName: 'a.jpg',
      ),
      '工作/2024',
    );
    expect(
      ShareReceivePaths.relativeDirForReceive(
        root: root('path_1'),
        directory: '工作/2024',
        fileName: 'a.jpg',
      ),
      '工作/2024',
    );
  });

  test('默认安装根无 directory 时按四分类', () {
    expect(
      ShareReceivePaths.relativeDirForReceive(
        root: root('default_99'),
        fileName: 'a.jpg',
      ),
      '图片',
    );
    expect(
      ShareReceivePaths.relativeDirForReceive(
        root: root('default_99'),
        fileName: 'a.mp4',
      ),
      '视频',
    );
  });

  test('换根后无 directory 时写顶层', () {
    expect(
      ShareReceivePaths.relativeDirForReceive(
        root: root('path_99'),
        fileName: 'a.jpg',
      ),
      '',
    );
    expect(
      ShareReceivePaths.relativeDirForBackup(
        root: root('path_99'),
        category: BackupCategory.image,
      ),
      '',
    );
    expect(
      ShareReceivePaths.relativeDirForBackup(
        root: root('default_1'),
        category: BackupCategory.image,
      ),
      '图片',
    );
  });
}
