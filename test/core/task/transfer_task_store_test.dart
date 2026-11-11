import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:diubangwenjian/core/identity/migrations.dart' as identity;
import 'package:diubangwenjian/core/task/transfer_task.dart';
import 'package:diubangwenjian/core/task/transfer_task_store.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late TransferTaskStore store;
  late Database db;

  setUp(() async {
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
    store = TransferTaskStore(db: () => db);
  });

  tearDown(() async {
    await db.close();
  });

  test('upsert + 状态转移 offered→done', () async {
    final task = TransferTask(
      id: 't1',
      type: TransferTaskType.p2pOffer,
      state: TransferTaskState.offered,
      peerFingerprint: 'fp1',
      fileName: 'a.bin',
      sizeBytes: 10,
      createdAtMs: 100,
    );
    await store.upsert(task);
    expect((await store.findById('t1'))?.state, TransferTaskState.offered);

    await store.updateState('t1', TransferTaskState.accepted);
    await store.updateState('t1', TransferTaskState.transferring);
    await store.updateState(
      't1',
      TransferTaskState.done,
      bytesTransferred: 10,
      localPath: '/tmp/a.bin',
    );

    final done = await store.findById('t1');
    expect(done?.state, TransferTaskState.done);
    expect(done?.bytesTransferred, 10);
    expect(done?.localPath, '/tmp/a.bin');
    expect(done?.isTerminal, isTrue);
  });

  test('listPendingForPeer 只返回 offered', () async {
    await store.upsert(
      TransferTask(
        id: 'o1',
        type: TransferTaskType.p2pOffer,
        state: TransferTaskState.offered,
        peerFingerprint: 'fp',
        fileName: 'x',
        sizeBytes: 1,
        createdAtMs: 1,
      ),
    );
    await store.upsert(
      TransferTask(
        id: 'o2',
        type: TransferTaskType.p2pOffer,
        state: TransferTaskState.done,
        peerFingerprint: 'fp',
        fileName: 'y',
        sizeBytes: 1,
        createdAtMs: 2,
      ),
    );
    final pending = await store.listPendingForPeer('fp');
    expect(pending.length, 1);
    expect(pending.first.id, 'o1');
  });

  test('abandonInFlightNasTransfers 只收尾 NAS 非终态', () async {
    await store.upsert(
      TransferTask(
        id: 'dl',
        type: TransferTaskType.nasDownload,
        state: TransferTaskState.transferring,
        peerFingerprint: 'fp',
        fileName: 'a.jpg',
        sizeBytes: 10,
        createdAtMs: 1,
      ),
    );
    await store.upsert(
      TransferTask(
        id: 'ul',
        type: TransferTaskType.nasUpload,
        state: TransferTaskState.accepted,
        peerFingerprint: 'fp',
        fileName: 'b.jpg',
        sizeBytes: 10,
        createdAtMs: 2,
      ),
    );
    await store.upsert(
      TransferTask(
        id: 'offer',
        type: TransferTaskType.p2pOffer,
        state: TransferTaskState.offered,
        peerFingerprint: 'fp',
        fileName: 'c.bin',
        sizeBytes: 10,
        createdAtMs: 3,
      ),
    );
    final n = await store.abandonInFlightNasTransfers();
    expect(n, 2);
    expect((await store.findById('dl'))?.state, TransferTaskState.failed);
    expect((await store.findById('ul'))?.state, TransferTaskState.failed);
    expect((await store.findById('offer'))?.state, TransferTaskState.offered);
  });

  test('updateState 不把终态回写成 transferring', () async {
    await store.upsert(
      TransferTask(
        id: 't-done',
        type: TransferTaskType.nasDownload,
        state: TransferTaskState.done,
        peerFingerprint: 'fp',
        fileName: 'z.jpg',
        sizeBytes: 100,
        createdAtMs: 1,
        bytesTransferred: 100,
      ),
    );
    await store.updateState(
      't-done',
      TransferTaskState.transferring,
      bytesTransferred: 50,
    );
    final again = await store.findById('t-done');
    expect(again?.state, TransferTaskState.done);
    expect(again?.bytesTransferred, 100);
  });
}
