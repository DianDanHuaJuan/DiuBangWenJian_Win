import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:diubangwenjian/core/common/app_exception.dart';
import 'package:diubangwenjian/core/common/key_value_store.dart';
import 'package:diubangwenjian/core/storage/storage_path_policy.dart';
import 'package:diubangwenjian/core/storage/storage_root.dart';
import 'package:diubangwenjian/core/storage/storage_root_store.dart';
import 'package:diubangwenjian/core/storage/switch_share_root.dart';

void main() {
  late Directory tempDir;
  late StorageRootStore store;
  late SwitchShareRoot switcher;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final kv = KeyValueStore(sharedPreferences: prefs);
    tempDir = await Directory.systemTemp.createTemp('wenjian_switch_');
    store = StorageRootStore(keyValueStore: kv);
    await store.setCurrent(
      StorageRoot(
        id: 'default',
        kind: StorageRootKind.path,
        uriOrPath: tempDir.path,
        displayName: 'default',
        addedAtMs: 1,
      ),
    );
    switcher = SwitchShareRoot(rootStore: store);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('toDirectory 直接以所选目录为写根，不套 diubangfiles', () async {
    final vol = await Directory.systemTemp.createTemp('wenjian_vol_');
    addTearDown(() async {
      if (await vol.exists()) await vol.delete(recursive: true);
    });

    final root = await switcher.toDirectory(vol.path);
    expect(p.normalize(root.uriOrPath), p.normalize(vol.path));
    expect(await Directory(root.uriOrPath).exists(), isTrue);
    expect((await store.ensureCurrent()).id, root.id);
    expect(await store.historyRoots(), isNotEmpty);
  });

  test('同一路径再次切换复用根 id', () async {
    final vol = await Directory.systemTemp.createTemp('wenjian_vol2_');
    addTearDown(() async {
      if (await vol.exists()) await vol.delete(recursive: true);
    });

    final first = await switcher.toDirectory(vol.path);
    final second = await switcher.toDirectory(vol.path);
    expect(second.id, first.id);
  });

  test('toExisting 把历史根设回当前', () async {
    final alt = await Directory.systemTemp.createTemp('wenjian_alt2_');
    addTearDown(() async {
      if (await alt.exists()) await alt.delete(recursive: true);
    });
    final moved = await switcher.toDirectory(alt.path);
    await switcher.toExisting(
      StorageRoot(
        id: 'default',
        kind: StorageRootKind.path,
        uriOrPath: tempDir.path,
        displayName: 'default',
        addedAtMs: 1,
      ),
    );
    expect((await store.ensureCurrent()).id, 'default');
    expect(
      (await store.historyRoots()).any((r) => r.id == moved.id),
      isTrue,
    );
  });

  test('resolveWritableShareDir 使用原路径', () async {
    final nested = Directory(p.join(tempDir.path, 'photos'));
    await nested.create(recursive: true);
    final dir = await resolveWritableShareDir(nested.path);
    expect(
      p.normalize(dir.path),
      p.normalize(nested.path),
    );
  });

  test('toDirectory 拒绝应用私有目录', () async {
    await expectLater(
      switcher.toDirectory(
        '/data/user/0/com.example/app_flutter/diubangfiles',
      ),
      throwsA(
        predicate(
          (e) =>
              e is AppException && e.code == 'storage_private_forbidden',
        ),
      ),
    );
  });

  test('toDirectory 拒绝内置盘根目录', () async {
    await expectLater(
      switcher.toDirectory('/storage/emulated/0'),
      throwsA(
        predicate(
          (e) => e is AppException && e.code == 'storage_volume_root',
        ),
      ),
    );
  });

  test('isStorageVolumeRoot 识别常见卷根', () async {
    expect(await isStorageVolumeRoot('/storage/emulated/0'), isTrue);
    expect(await isStorageVolumeRoot('/storage/emulated/0/'), isTrue);
    expect(await isStorageVolumeRoot('/sdcard'), isTrue);
    expect(await isStorageVolumeRoot('/storage/ABCD-EF01'), isTrue);
    expect(
      await isStorageVolumeRoot('/storage/emulated/0/Download'),
      isFalse,
    );
    expect(
      await isStorageVolumeRoot('/storage/ABCD-EF01/DCIM'),
      isFalse,
    );
  });
}
