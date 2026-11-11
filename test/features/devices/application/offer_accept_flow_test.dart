import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:diubangwenjian/core/common/key_value_store.dart';
import 'package:diubangwenjian/core/identity/migrations.dart' as identity;
import 'package:diubangwenjian/core/network/peer_api_client.dart';
import 'package:diubangwenjian/core/realtime/realtime_connection_registry.dart';
import 'package:diubangwenjian/core/realtime/realtime_event.dart';
import 'package:diubangwenjian/core/realtime/realtime_session_service.dart';
import 'package:diubangwenjian/core/storage/share_writer.dart';
import 'package:diubangwenjian/core/storage/storage_constants.dart';
import 'package:diubangwenjian/core/storage/storage_root.dart';
import 'package:diubangwenjian/core/storage/storage_root_store.dart';
import 'package:diubangwenjian/core/task/transfer_task.dart';
import 'package:diubangwenjian/core/task/transfer_task_store.dart';
import 'package:diubangwenjian/features/devices/application/offer_accept_service.dart';
import 'package:diubangwenjian/features/devices/data/datasources/chat_local_data_source.dart';
import 'package:diubangwenjian/features/devices/data/repositories/chat_repository.dart';

class _StubPeerApi extends PeerApiClient {
  _StubPeerApi()
      : super(
          peerRepository: () async => throw UnimplementedError(),
          selfFingerprint: 'self',
        );

  @override
  Future<PeerApiResponse?> get(
    String fingerprint,
    String path, {
    Map<String, dynamic>? query,
    Duration? connectTimeout,
    Duration? receiveTimeout,
  }) async =>
      null;

  @override
  Future<PeerApiResponse?> post(
    String fingerprint,
    String path, {
    Object? body,
  }) async =>
      const PeerApiResponse(statusCode: 200, data: {'ok': true});

  @override
  Future<List<int>?> downloadBytes(
    String fingerprint,
    String path, {
    Map<String, dynamic>? query,
  }) async =>
      null;

  @override
  Future<int?> downloadToFile(
    String fingerprint,
    String path, {
    required File destFile,
    Map<String, dynamic>? query,
    void Function(int cumulativeBytes)? onBytes,
    void Function(List<int> chunk)? onChunk,
    CancelToken? cancelToken,
  }) async =>
      null;
}

class _NoopSession extends RealtimeSessionService {
  _NoopSession()
      : super(
          peerRepository: () async => throw UnimplementedError(),
          selfFingerprint: 'self',
        );

  @override
  Future<bool> connect(String fingerprint) async => false;

  @override
  Future<bool> send(RealtimeEvent event) async => false;

  @override
  Future<void> disconnect() async {}
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late TransferTaskStore tasks;
  late ChatRepository chat;
  late ShareWriter writer;
  late Directory tempDir;
  late OfferAcceptService offers;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final kv = KeyValueStore(sharedPreferences: prefs);
    tempDir = await Directory.systemTemp.createTemp('offer_flow_');
    final roots = StorageRootStore(keyValueStore: kv);
    await roots.setCurrent(
      StorageRoot(
        id: 't',
        kind: StorageRootKind.path,
        uriOrPath: tempDir.path,
        displayName: StorageConstants.displayPathLabel,
        addedAtMs: 1,
      ),
    );
    writer = ShareWriter(rootStore: roots);

    db = await openDatabase(
      inMemoryDatabasePath,
      version: 1,
      singleInstance: false,
    );
    for (final m in identity.identityMigrations) {
      await m.up(db);
    }
    for (final m in taskMigrations) {
      await m.up(db);
    }
    for (final m in chatMigrations) {
      await m.up(db);
    }
    tasks = TransferTaskStore(db: () => db);
    chat = ChatRepository(local: ChatLocalDataSource(db: () => db));
    offers = OfferAcceptService(
      taskStore: tasks,
      chatRepository: chat,
      peerApiClient: _StubPeerApi(),
      shareWriter: writer,
      session: _NoopSession(),
      hubRegistry: RealtimeConnectionRegistry(),
      ensurePeerWs: (_) async => false,
    );
  });

  tearDown(() async {
    await offers.dispose();
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('入站 offer 事件写入 p2p_download + chat', () async {
    await offers.handleInboundEvent(
      'peerA',
      RealtimeEvent.create(
        type: RealtimeEventType.offer,
        payload: {
          'taskId': 'offer_1',
          'fileName': 'a.txt',
          'sizeBytes': 4,
          'sha256': 'abcd',
        },
      ),
    );
    final task = await tasks.findById('offer_1');
    expect(task?.type, TransferTaskType.p2pDownload);
    expect(task?.state, TransferTaskState.offered);
    expect(task?.fileName, 'a.txt');
    final msgs = await chat.messagesFor('peerA');
    expect(msgs.length, 1);
    expect(msgs.first.body, 'offer_1');
    final inbound = await tasks.listInboundOffered(peerFingerprint: 'peerA');
    expect(inbound.length, 1);
  });

  test('TTL 过期 offered → expired', () async {
    final past = DateTime.now().millisecondsSinceEpoch - 1000;
    await tasks.upsert(
      TransferTask(
        id: 'old',
        type: TransferTaskType.p2pOffer,
        state: TransferTaskState.offered,
        peerFingerprint: 'peerB',
        fileName: 'x',
        sizeBytes: 1,
        createdAtMs: past,
        ttlExpireAtMs: past,
      ),
    );
    final n = await offers.expireOffers();
    expect(n, 1);
    expect((await tasks.findById('old'))?.state, TransferTaskState.expired);
  });

  test('发送方 receipt HTTP → done', () async {
    await tasks.upsert(
      TransferTask(
        id: 'out1',
        type: TransferTaskType.p2pOffer,
        state: TransferTaskState.offered,
        peerFingerprint: 'peerC',
        fileName: 'y',
        sizeBytes: 1,
        createdAtMs: 1,
      ),
    );
    await offers.onReceiptHttp(
      fromPeer: 'peerC',
      taskId: 'out1',
      ok: true,
    );
    expect((await tasks.findById('out1'))?.state, TransferTaskState.done);
  });
}
