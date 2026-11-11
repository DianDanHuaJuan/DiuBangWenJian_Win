import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf.dart';

import 'package:diubangwenjian/core/auth/peer_fingerprint_middleware.dart';
import 'package:diubangwenjian/core/common/key_value_store.dart';
import 'package:diubangwenjian/core/identity/peer.dart';
import 'package:diubangwenjian/core/storage/media_library_service.dart';
import 'package:diubangwenjian/core/storage/share_reader.dart';
import 'package:diubangwenjian/core/storage/storage_root.dart';
import 'package:diubangwenjian/core/storage/storage_root_store.dart';
import 'package:diubangwenjian/features/nas/application/nas_service_switch.dart';
import 'package:diubangwenjian/features/nas/data/api/handlers/file_list_handler.dart';
import 'package:diubangwenjian/features/nas/data/nas_share_scope.dart';
import 'package:diubangwenjian/features/nas/data/share_path_resolver.dart';

void main() {
  late Directory tempDir;
  late KeyValueStore store;
  late StorageRootStore roots;
  late ShareReader reader;

  final peer = Peer(
    fingerprint: 'ab' * 32,
    name: 'peer',
    model: 'test',
    pairedAt: 0,
    secret: 'cd' * 32,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    store = KeyValueStore(sharedPreferences: prefs);
    tempDir = await Directory.systemTemp.createTemp('nas_files_');
    roots = StorageRootStore(keyValueStore: store);
    await roots.setCurrent(
      StorageRoot(
        id: 'test_root',
        kind: StorageRootKind.path,
        uriOrPath: tempDir.path,
        displayName: 'Download/diubangfiles',
        addedAtMs: 1,
      ),
    );
    reader = ShareReader(rootStore: roots);
    await File(p.join(tempDir.path, 'hello.txt')).writeAsString('hi');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('NasServiceSwitch 开关持久化', () async {
    final sw = NasServiceSwitch(store: store);
    expect(sw.isEnabled, isFalse);
    await sw.setEnabled(true);
    expect(sw.isEnabled, isTrue);
    expect(store.getBool(NasServiceSwitch.enabledKey), isTrue);
  });

  test('FileListHandler 返回共享根文件', () async {
    final resolver = SharePathResolver(rootStore: roots);
    final handler = FileListHandler(
      shareReader: reader,
      resolver: resolver,
      mediaLibrary: MediaLibraryService(),
    ).handler;
    final response = await handler(
      Request(
        'GET',
        Uri.parse('http://localhost/api/v1/files?rootId=fs'),
        context: {peerKey: peer},
      ),
    );
    expect(response.statusCode, 200);
    final body = await response.readAsString();
    expect(body, contains('hello.txt'));
    expect(body, contains('test_root'));
  });

  test('FileListHandler 支持子目录 path', () async {
    final sub = Directory(p.join(tempDir.path, 'album'));
    await sub.create();
    await File(p.join(sub.path, 'a.jpg')).writeAsString('x');
    final resolver = SharePathResolver(rootStore: roots);
    final handler = FileListHandler(
      shareReader: reader,
      resolver: resolver,
      mediaLibrary: MediaLibraryService(),
    ).handler;
    final response = await handler(
      Request(
        'GET',
        Uri.parse('http://localhost/api/v1/files?rootId=fs&path=album'),
        context: {peerKey: peer},
      ),
    );
    expect(response.statusCode, 200);
    final body = await response.readAsString();
    expect(body, contains('a.jpg'));
    expect(body, contains('"isDirectory":false'));
  });

  test('自定义共享范围只列出已选文件夹', () async {
    final other = await Directory.systemTemp.createTemp('nas_scope_');
    try {
      await File(p.join(other.path, 'secret.pdf')).writeAsString('x');
      final scope = NasShareScope(keyValueStore: store);
      expect(await scope.addFolder(other.path), isTrue);
      expect(scope.isCustom, isTrue);
      expect(scope.coversDirectory(tempDir.path), isFalse);
      expect(scope.allows(p.join(other.path, 'secret.pdf')), isTrue);
      expect(scope.allows(p.join(tempDir.path, 'hello.txt')), isFalse);

      final resolver = SharePathResolver(rootStore: roots);
      final handler = FileListHandler(
        shareReader: reader,
        resolver: resolver,
        mediaLibrary: MediaLibraryService(),
        shareScope: scope,
      ).handler;
      final root = await handler(
        Request(
          'GET',
          Uri.parse('http://localhost/api/v1/files?rootId=fs'),
          context: {peerKey: peer},
        ),
      );
      final rootBody = await root.readAsString();
      expect(rootBody, isNot(contains('hello.txt')));
      expect(rootBody, contains('s0'));

      final nested = await handler(
        Request(
          'GET',
          Uri.parse('http://localhost/api/v1/files?rootId=fs&path=s0'),
          context: {peerKey: peer},
        ),
      );
      expect(await nested.readAsString(), contains('secret.pdf'));

      final content = FileContentHandler(
        resolver: resolver,
        mediaLibrary: MediaLibraryService(),
        shareScope: scope,
      ).handler;
      final blocked = await content(
        Request(
          'GET',
          Uri.parse(
            'http://localhost/api/v1/files/content?rootId=fs&path=hello.txt',
          ),
          context: {peerKey: peer},
        ),
      );
      expect(blocked.statusCode, 404);

      await scope.restoreDefault();
      expect(scope.isCustom, isFalse);
      expect(scope.allows(p.join(tempDir.path, 'hello.txt')), isTrue);
    } finally {
      if (await other.exists()) await other.delete(recursive: true);
    }
  });
}
