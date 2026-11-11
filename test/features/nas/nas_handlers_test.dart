import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf.dart';

import 'package:diubangwenjian/core/auth/peer_fingerprint_middleware.dart';
import 'package:diubangwenjian/core/common/key_value_store.dart';
import 'package:diubangwenjian/core/identity/peer.dart';
import 'package:diubangwenjian/core/storage/media_library_service.dart';
import 'package:diubangwenjian/core/storage/media_scanner.dart';
import 'package:diubangwenjian/core/storage/share_reader.dart';
import 'package:diubangwenjian/core/storage/share_writer.dart';
import 'package:diubangwenjian/core/storage/storage_constants.dart';
import 'package:diubangwenjian/core/storage/storage_root.dart';
import 'package:diubangwenjian/core/storage/storage_root_store.dart';
import 'package:diubangwenjian/core/storage/inbox_catalog_service.dart';
import 'package:diubangwenjian/features/nas/data/api/handlers/media_and_mgmt_handlers.dart';
import 'package:diubangwenjian/features/nas/data/api/services/thumbnail_service.dart';
import 'package:diubangwenjian/features/nas/data/share_path_resolver.dart';
import 'package:diubangwenjian/features/nas/data/webdav/handlers/propfind_handler.dart';

void main() {
  late Directory tempDir;
  late KeyValueStore store;
  late StorageRootStore roots;
  late SharePathResolver resolver;
  late ShareWriter writer;
  late ThumbnailService thumbs;

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
    tempDir = await Directory.systemTemp.createTemp('nas_phase3_');
    roots = StorageRootStore(keyValueStore: store);
    await roots.setCurrent(
      StorageRoot(
        id: 'test_root',
        kind: StorageRootKind.path,
        uriOrPath: tempDir.path,
        displayName: StorageConstants.displayPathLabel,
        addedAtMs: 1,
      ),
    );
    resolver = SharePathResolver(rootStore: roots);
    writer = ShareWriter(
      rootStore: roots,
      freeBytesReader: (_) async => 10 * 1024 * 1024 * 1024,
    );
    thumbs = ThumbnailService();
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Request authed(String method, String path, {List<int>? body}) {
    return Request(
      method,
      Uri.parse('http://localhost$path'),
      headers: body == null
          ? const {}
          : {'content-type': 'application/octet-stream'},
      body: body,
      context: {peerKey: peer},
    );
  }

  test('thumbnail 图片可生成 jpeg', () async {
    final image = img.Image(width: 40, height: 30);
    img.fill(image, color: img.ColorRgb8(10, 200, 30));
    final png = img.encodePng(image);
    final file = File(p.join(tempDir.path, 'a.png'));
    await file.writeAsBytes(png);
    final bytes = await thumbs.thumbnailFor(file, maxPx: 16);
    expect(bytes, isNotNull);
    expect(bytes!.length, greaterThan(10));
  });

  test('batch-delete 删除共享文件', () async {
    final f = File(p.join(tempDir.path, 'kill.txt'));
    await f.writeAsString('x');
    final reader = ShareReader(rootStore: roots);
    final handler = BatchDeleteHandler(
      shareReader: reader,
      mediaLibrary: MediaLibraryService(),
    ).handler;
    final response = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost${BatchDeleteHandler.path}'),
        context: {peerKey: peer},
        body: jsonEncode({
          'items': [
            {'rootId': 'test_root', 'relativePath': 'kill.txt'},
          ],
        }),
      ),
    );
    expect(response.statusCode, 200);
    expect(await f.exists(), isFalse);
  });

  test('WebDAV PUT 写入共享根四分类', () async {
    final inbox = InboxCatalogService(
      rootStore: roots,
      shareWriter: writer,
      mediaScanner: MediaScanner(),
    );
    final handler = DavPutHandler(
      receiveFile: ({
        required preferredFileName,
        required bytes,
        required peerFingerprint,
      }) async {
        final r = await inbox.receiveFile(
          preferredFileName: preferredFileName,
          bytes: bytes,
        );
        return (fileName: r.fileName, rootId: r.rootId);
      },
    ).handler;
    final response = await handler(
      authed('PUT', '/dav/hello.bin', body: [1, 2, 3, 4]),
    );
    expect(response.statusCode, 201);
    // .bin → 其他
    final dest = File(p.join(tempDir.path, '其他', 'hello.bin'));
    expect(await dest.exists(), isTrue);
  });

  test('MKCOL 创建子目录', () async {
    final handler = DavMkcolHandler(resolver: resolver).handler;
    final response = await handler(authed('MKCOL', '/dav/album'));
    expect(response.statusCode, 201);
    expect(await Directory(p.join(tempDir.path, 'album')).exists(), isTrue);
  });
}
