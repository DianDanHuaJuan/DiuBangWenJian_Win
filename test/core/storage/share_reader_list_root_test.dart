import 'dart:io';

import 'package:diubangwenjian/core/common/key_value_store.dart';
import 'package:diubangwenjian/core/storage/share_reader.dart';
import 'package:diubangwenjian/core/storage/storage_root.dart';
import 'package:diubangwenjian/core/storage/storage_root_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory temp;
  late ShareReader reader;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = KeyValueStore(sharedPreferences: prefs);
    temp = await Directory.systemTemp.createTemp('share_reader_root_');
    await File(p.join(temp.path, 'hello.txt')).writeAsString('hi');
    await Directory(p.join(temp.path, 'subdir')).create();
    final roots = StorageRootStore(keyValueStore: store);
    await roots.setCurrent(
      StorageRoot(
        id: 'r1',
        kind: StorageRootKind.path,
        uriOrPath: temp.path,
        displayName: '测试共享',
        addedAtMs: 1,
      ),
    );
    reader = ShareReader(rootStore: roots);
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  test('listDirectory empty path lists share root children', () async {
    final entries = await reader.listDirectory(rootId: 'r1', relativePath: '');
    expect(
      entries.map((e) => e.fileName).toSet(),
      containsAll(['hello.txt', 'subdir']),
    );
  });
}
