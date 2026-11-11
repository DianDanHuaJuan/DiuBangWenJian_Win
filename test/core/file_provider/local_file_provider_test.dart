import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:diubangwenjian/core/common/key_value_store.dart';
import 'package:diubangwenjian/core/file_provider/local_file_provider.dart';
import 'package:diubangwenjian/core/storage/share_reader.dart';
import 'package:diubangwenjian/core/storage/storage_root.dart';
import 'package:diubangwenjian/core/storage/storage_root_store.dart';

void main() {
  late Directory tempDir;
  late StorageRootStore roots;
  late LocalFileProvider provider;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = KeyValueStore(sharedPreferences: prefs);
    tempDir = await Directory.systemTemp.createTemp('local_fp_');
    roots = StorageRootStore(keyValueStore: store);
    await roots.setCurrent(
      StorageRoot(
        id: 'r1',
        kind: StorageRootKind.path,
        uriOrPath: tempDir.path,
        displayName: 'test',
        addedAtMs: 1,
      ),
    );
    provider = LocalFileProvider(
      shareReader: ShareReader(rootStore: roots),
      rootStore: roots,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('list 含目录与文件', () async {
    await Directory(p.join(tempDir.path, 'pics')).create();
    await File(p.join(tempDir.path, 'a.txt')).writeAsString('hi');
    final entries = await provider.list(rootId: 'r1');
    expect(entries.any((e) => e.isDirectory && e.name == 'pics'), isTrue);
    expect(entries.any((e) => !e.isDirectory && e.name == 'a.txt'), isTrue);
  });

  test('delete 删除文件', () async {
    final f = File(p.join(tempDir.path, 'gone.txt'));
    await f.writeAsString('x');
    final ok = await provider.delete(rootId: 'r1', relativePath: 'gone.txt');
    expect(ok, isTrue);
    expect(await f.exists(), isFalse);
  });
}
