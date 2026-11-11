import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:diubangwenjian/core/common/app_exception.dart';
import 'package:diubangwenjian/core/common/key_value_store.dart';
import 'package:diubangwenjian/core/storage/share_writer.dart';
import 'package:diubangwenjian/core/storage/storage_constants.dart';
import 'package:diubangwenjian/core/storage/storage_root.dart';
import 'package:diubangwenjian/core/storage/storage_root_store.dart';

void main() {
  late Directory tempDir;
  late KeyValueStore kv;
  late StorageRootStore store;
  late ShareWriter writer;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    kv = KeyValueStore(sharedPreferences: prefs);
    tempDir = await Directory.systemTemp.createTemp('wenjian_share_');
    store = StorageRootStore(keyValueStore: kv);
    // 注入默认根：绕过平台 Documents 探测。
    await store.setCurrent(
      StorageRoot(
        id: 'test_root',
        kind: StorageRootKind.path,
        uriOrPath: tempDir.path,
        displayName: StorageConstants.displayPathLabel,
        addedAtMs: 1,
      ),
    );
    writer = ShareWriter(rootStore: store);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('writeBytes 写入当前根', () async {
    final result = await writer.writeBytes(
      preferredFileName: 'hello.txt',
      bytes: 'ping'.codeUnits,
    );
    expect(result.fileName, 'hello.txt');
    expect(result.rootId, 'test_root');
    final file = File(result.absolutePath);
    expect(await file.exists(), isTrue);
    expect(await file.readAsString(), 'ping');
  });

  test('重名自动加后缀', () async {
    await writer.writeBytes(
      preferredFileName: 'photo.jpg',
      bytes: [1],
    );
    final second = await writer.writeBytes(
      preferredFileName: 'photo.jpg',
      bytes: [2],
    );
    expect(second.fileName, 'photo (1).jpg');
    expect(await File(p.join(tempDir.path, 'photo.jpg')).exists(), isTrue);
    expect(await File(p.join(tempDir.path, 'photo (1).jpg')).exists(), isTrue);
  });

  test('setCurrent 切换写根且旧根进历史', () async {
    final alt = await Directory.systemTemp.createTemp('wenjian_alt_');
    addTearDown(() async {
      if (await alt.exists()) await alt.delete(recursive: true);
    });

    await store.setCurrent(
      StorageRoot(
        id: 'alt',
        kind: StorageRootKind.path,
        uriOrPath: alt.path,
        displayName: '备用根',
        addedAtMs: 2,
      ),
    );
    final current = await store.current;
    expect(current?.id, 'alt');
    final history = await store.historyRoots();
    expect(history.any((r) => r.id == 'test_root'), isTrue);

    final result = await writer.writeBytes(
      preferredFileName: 'only_alt.bin',
      bytes: [9],
    );
    expect(result.absolutePath.startsWith(alt.path), isTrue);
  });

  test('空间不足预检抛 storage_no_space', () async {
    final tight = ShareWriter(
      rootStore: store,
      freeBytesReader: (_) async => 0,
    );
    await expectLater(
      tight.writeBytes(preferredFileName: 'big.bin', bytes: [1, 2, 3]),
      throwsA(
        predicate(
          (e) =>
              e.toString().contains('storage_no_space') ||
              e.toString().contains('存储空间不足'),
        ),
      ),
    );
  });

  test('resolveDefaultShareDirectory 公共目录不可用时抛错且不回退私有', () async {
    await expectLater(
      resolveDefaultShareDirectory(tryPublicDownload: () async => null),
      throwsA(
        predicate(
          (e) =>
              e is AppException && e.code == 'storage_public_unavailable',
        ),
      ),
    );
  });

  test('resolveDefaultShareDirectory 仅使用公共探测目录', () async {
    final public = await Directory.systemTemp.createTemp('wenjian_public_');
    addTearDown(() async {
      if (await public.exists()) await public.delete(recursive: true);
    });
    final target = Directory(p.join(public.path, StorageConstants.folderName));

    final dir = await resolveDefaultShareDirectory(
      tryPublicDownload: () async => target,
    );
    expect(dir.path, target.path);
    expect(await dir.exists(), isTrue);
  });

  test('resolveDefaultShareDirectory 并发探测不因同名 probe 失败', () async {
    final public = await Directory.systemTemp.createTemp('wenjian_public_race_');
    addTearDown(() async {
      if (await public.exists()) await public.delete(recursive: true);
    });
    final target = Directory(p.join(public.path, StorageConstants.folderName));

    final results = await Future.wait(
      List.generate(
        12,
        (_) => resolveDefaultShareDirectory(
          tryPublicDownload: () async => target,
        ),
      ),
    );
    expect(results.every((d) => d.path == target.path), isTrue);
    expect(await target.exists(), isTrue);
  });

  test('ensureCurrent 并发返回同一可用根', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final emptyKv = KeyValueStore(sharedPreferences: prefs);
    final emptyStore = StorageRootStore(keyValueStore: emptyKv);
    final public = await Directory.systemTemp.createTemp('wenjian_ensure_');
    addTearDown(() async {
      if (await public.exists()) await public.delete(recursive: true);
    });
    final target = Directory(p.join(public.path, StorageConstants.folderName));

    await emptyStore.setCurrent(
      StorageRoot(
        id: 'shared',
        kind: StorageRootKind.path,
        uriOrPath: target.path,
        displayName: 't',
        addedAtMs: 1,
      ),
    );
    final roots = await Future.wait(
      List.generate(8, (_) => emptyStore.ensureCurrent()),
    );
    expect(roots.every((r) => r.id == 'shared'), isTrue);
  });

  test('isAppPrivateStoragePath 识别沙箱路径', () {
    expect(
      isAppPrivateStoragePath(
        '/data/user/0/com.example/app_flutter/diubangfiles',
      ),
      isTrue,
    );
    expect(
      isAppPrivateStoragePath(
        '/storage/emulated/0/Android/data/com.example/files/diubangfiles',
      ),
      isTrue,
    );
    expect(
      isAppPrivateStoragePath('/storage/emulated/0/Download/diubangfiles'),
      isFalse,
    );
  });
}
