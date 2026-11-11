import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:diubangwenjian/core/storage/incomplete_file.dart';

void main() {
  test('discardIncompleteFile 删除存在的文件', () async {
    final dir = await Directory.systemTemp.createTemp('incomplete_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final f = File('${dir.path}/half.bin');
    await f.writeAsBytes([1, 2, 3]);
    expect(await f.exists(), isTrue);
    await discardIncompleteFile(f.path);
    expect(await f.exists(), isFalse);
  });

  test('discardIncompleteFile 空路径 / 不存在不抛错', () async {
    await discardIncompleteFile(null);
    await discardIncompleteFile('');
    await discardIncompleteFile('/no/such/file_${DateTime.now().microsecondsSinceEpoch}');
  });
}
