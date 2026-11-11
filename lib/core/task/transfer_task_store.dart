import 'dart:io';

import 'package:sqflite/sqflite.dart';

import '../database/migration_registry.dart';
import 'transfer_task.dart';

/// transfer_tasks 表读写唯一入口（doc/02 transfer_task_store）。
class TransferTaskStore {
  static const table = 'transfer_tasks';

  TransferTaskStore({required Database Function() db}) : _db = db;

  final Database Function() _db;

  Future<void> createTable(Database database) async {
    await database.execute('''
      CREATE TABLE $table (
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        state TEXT NOT NULL,
        peer_fingerprint TEXT NOT NULL,
        file_name TEXT NOT NULL,
        size_bytes INTEGER NOT NULL,
        created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER,
        sha256_hex TEXT,
        local_path TEXT,
        remote_path TEXT,
        error_message TEXT,
        ttl_expire_at_ms INTEGER,
        bytes_transferred INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await database.execute(
      'CREATE INDEX idx_transfer_tasks_peer ON $table(peer_fingerprint)',
    );
    await database.execute(
      'CREATE INDEX idx_transfer_tasks_state ON $table(state)',
    );
  }

  Future<void> upsert(TransferTask task) async {
    await _db().insert(
      table,
      task.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<TransferTask?> findById(String id) async {
    final rows = await _db().query(
      table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return TransferTask.fromMap(rows.first);
  }

  Future<List<TransferTask>> listByPeer(String fingerprint) async {
    final rows = await _db().query(
      table,
      where: 'peer_fingerprint = ?',
      whereArgs: [fingerprint],
      orderBy: 'created_at_ms DESC',
    );
    return rows.map(TransferTask.fromMap).toList();
  }

  /// outbox 视图：本机作为发送方的 p2p_offer。
  Future<List<TransferTask>> listOffers({
    TransferTaskState? state,
  }) async {
    if (state == null) {
      final rows = await _db().query(
        table,
        where: 'type = ?',
        whereArgs: [TransferTaskType.p2pOffer.name],
        orderBy: 'created_at_ms DESC',
      );
      return rows.map(TransferTask.fromMap).toList();
    }
    final rows = await _db().query(
      table,
      where: 'type = ? AND state = ?',
      whereArgs: [TransferTaskType.p2pOffer.name, state.name],
      orderBy: 'created_at_ms DESC',
    );
    return rows.map(TransferTask.fromMap).toList();
  }

  Future<List<TransferTask>> listPendingForPeer(String fingerprint) async {
    final rows = await _db().query(
      table,
      where: 'peer_fingerprint = ? AND state = ? AND type = ?',
      whereArgs: [
        fingerprint,
        TransferTaskState.offered.name,
        TransferTaskType.p2pOffer.name,
      ],
      orderBy: 'created_at_ms ASC',
    );
    return rows.map(TransferTask.fromMap).toList();
  }

  /// 本机待接收（入站 p2p_download + offered）。
  Future<List<TransferTask>> listInboundOffered({String? peerFingerprint}) async {
    if (peerFingerprint == null) {
      final rows = await _db().query(
        table,
        where: 'type = ? AND state = ?',
        whereArgs: [
          TransferTaskType.p2pDownload.name,
          TransferTaskState.offered.name,
        ],
        orderBy: 'created_at_ms DESC',
      );
      return rows.map(TransferTask.fromMap).toList();
    }
    final rows = await _db().query(
      table,
      where: 'peer_fingerprint = ? AND type = ? AND state = ?',
      whereArgs: [
        peerFingerprint,
        TransferTaskType.p2pDownload.name,
        TransferTaskState.offered.name,
      ],
      orderBy: 'created_at_ms DESC',
    );
    return rows.map(TransferTask.fromMap).toList();
  }

  /// 本机 outbox 仍 offered 的数量（announce pend）。
  Future<int> countOutboundOffered() async {
    final rows = await _db().rawQuery(
      'SELECT COUNT(*) AS c FROM $table WHERE type = ? AND state = ?',
      [TransferTaskType.p2pOffer.name, TransferTaskState.offered.name],
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<void> updateState(
    String id,
    TransferTaskState state, {
    String? errorMessage,
    int? bytesTransferred,
    String? localPath,
    String? sha256Hex,
  }) async {
    final prev = await findById(id);
    final nextTerminal = state == TransferTaskState.done ||
        state == TransferTaskState.failed ||
        state == TransferTaskState.cancelled ||
        state == TransferTaskState.expired;
    // 禁止终态被进度回写改回 transferring。
    if (prev != null && prev.isTerminal && !nextTerminal) {
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    await _db().update(
      table,
      {
        'state': state.name,
        'updated_at_ms': now,
        if (errorMessage != null) 'error_message': errorMessage,
        if (bytesTransferred != null) 'bytes_transferred': bytesTransferred,
        if (localPath != null) 'local_path': localPath,
        if (sha256Hex != null) 'sha256_hex': sha256Hex,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 冷启动收尾：NAS 上下载仍处于 accepted/transferring 的任务全部标失败。
  ///
  /// 下载半成品删除；上传不删本地源文件。
  Future<int> abandonInFlightNasTransfers({
    String errorMessage = '应用退出时未完成',
  }) async {
    final inflight = await _db().query(
      table,
      columns: ['id', 'type', 'local_path'],
      where: 'state IN (?, ?) AND type IN (?, ?)',
      whereArgs: [
        TransferTaskState.accepted.name,
        TransferTaskState.transferring.name,
        TransferTaskType.nasDownload.name,
        TransferTaskType.nasUpload.name,
      ],
    );
    for (final row in inflight) {
      if (row['type'] != TransferTaskType.nasDownload.name) continue;
      final path = row['local_path'] as String?;
      if (path == null || path.isEmpty) continue;
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    return _db().rawUpdate(
      '''
      UPDATE $table
      SET state = ?, error_message = ?, bytes_transferred = 0,
          local_path = CASE WHEN type = ? THEN '' ELSE local_path END,
          updated_at_ms = ?
      WHERE state IN (?, ?) AND type IN (?, ?)
      ''',
      [
        TransferTaskState.failed.name,
        errorMessage,
        TransferTaskType.nasDownload.name,
        now,
        TransferTaskState.accepted.name,
        TransferTaskState.transferring.name,
        TransferTaskType.nasDownload.name,
        TransferTaskType.nasUpload.name,
      ],
    );
  }

  Future<void> updateSha256Hex(String id, String sha256Hex) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db().update(
      table,
      {
        'sha256_hex': sha256Hex,
        'updated_at_ms': now,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> delete(String id) async {
    await _db().delete(table, where: 'id = ?', whereArgs: [id]);
  }

  /// 最近任务（传输列表页）。
  Future<List<TransferTask>> listRecent({int limit = 100}) async {
    final rows = await _db().query(
      table,
      orderBy: 'created_at_ms DESC',
      limit: limit,
    );
    return rows.map(TransferTask.fromMap).toList();
  }
}

/// task 表族迁移（v3：transfer_tasks）。
const taskMigrations = <SchemaMigration>[
  SchemaMigration(
    version: 3,
    feature: 'task',
    up: _createTransferTasks,
  ),
];

Future<void> _createTransferTasks(Database db) async {
  final store = TransferTaskStore(db: () => db);
  await store.createTable(db);
}
