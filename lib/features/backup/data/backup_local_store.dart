import 'package:sqflite/sqflite.dart';

import '../domain/backup_models.dart';

/// 备份 Run / 明细本地持久化。
class BackupLocalStore {
  BackupLocalStore({required Future<Database> Function() db}) : _db = db;

  final Future<Database> Function() _db;

  /// 更新 Run 时必须用 UPDATE，禁止 INSERT OR REPLACE：
  /// REPLACE 会先删行，触发 items 表 ON DELETE CASCADE，把明细全部清掉。
  Future<void> upsertRun(BackupRun run) async {
    final db = await _db();
    final existing = await db.query(
      'backup_runs',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [run.id],
      limit: 1,
    );
    if (existing.isEmpty) {
      await db.insert('backup_runs', run.toMap());
    } else {
      await db.update(
        'backup_runs',
        run.toMap(),
        where: 'id = ?',
        whereArgs: [run.id],
      );
    }
  }

  Future<void> insertItems(List<BackupRunItem> items) async {
    if (items.isEmpty) return;
    final db = await _db();
    final batch = db.batch();
    for (final item in items) {
      batch.insert(
        'backup_run_items',
        item.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
    final count = Sqflite.firstIntValue(
      await db.rawQuery(
        'SELECT COUNT(*) FROM backup_run_items WHERE run_id = ?',
        [items.first.runId],
      ),
    );
    if ((count ?? 0) != items.length) {
      throw StateError(
        '备份明细写入不完整：期望 ${items.length}，实际 ${count ?? 0}',
      );
    }
  }

  Future<void> updateItem(BackupRunItem item) async {
    final db = await _db();
    await db.update(
      'backup_run_items',
      item.toMap(),
      where: 'id = ?',
      whereArgs: [item.id],
    );
  }

  Future<BackupRun?> findRun(String id) async {
    final db = await _db();
    final rows = await db.query(
      'backup_runs',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return BackupRun.fromMap(rows.first);
  }

  /// 非终态 Run（最多应一条）。
  Future<BackupRun?> findActiveRun() async {
    final db = await _db();
    final rows = await db.query(
      'backup_runs',
      where: 'status IN (?, ?)',
      whereArgs: [
        BackupRunStatus.running.name,
        BackupRunStatus.paused.name,
      ],
      orderBy: 'started_at_ms DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return BackupRun.fromMap(rows.first);
  }

  Future<List<BackupRun>> listHistory({int limit = 50}) async {
    final db = await _db();
    final rows = await db.query(
      'backup_runs',
      where: 'status IN (?, ?, ?)',
      whereArgs: [
        BackupRunStatus.success.name,
        BackupRunStatus.failed.name,
        BackupRunStatus.cancelled.name,
      ],
      orderBy: 'ended_at_ms DESC, started_at_ms DESC',
      limit: limit,
    );
    return rows.map(BackupRun.fromMap).toList(growable: false);
  }

  Future<List<BackupRunItem>> listItems(String runId) async {
    final db = await _db();
    final rows = await db.query(
      'backup_run_items',
      where: 'run_id = ?',
      whereArgs: [runId],
      orderBy: 'sort_index ASC',
    );
    return rows.map(BackupRunItem.fromMap).toList(growable: false);
  }

  Future<List<BackupRunItem>> listPendingItems(String runId) async {
    final db = await _db();
    final rows = await db.query(
      'backup_run_items',
      where: 'run_id = ? AND status IN (?, ?, ?)',
      whereArgs: [
        runId,
        BackupItemStatus.pending.name,
        BackupItemStatus.uploading.name,
        BackupItemStatus.failed.name,
      ],
      orderBy: 'sort_index ASC',
    );
    return rows.map(BackupRunItem.fromMap).toList(growable: false);
  }

  /// 启动降级：所有 running → paused（反影子）。
  Future<int> demoteRunningToPaused() async {
    final db = await _db();
    return db.update(
      'backup_runs',
      {'status': BackupRunStatus.paused.name},
      where: 'status = ?',
      whereArgs: [BackupRunStatus.running.name],
    );
  }

  Future<void> cancelPendingItems(String runId) async {
    final db = await _db();
    await db.update(
      'backup_run_items',
      {
        'status': BackupItemStatus.cancelled.name,
        'error_message': '用户放弃',
      },
      where: 'run_id = ? AND status IN (?, ?, ?)',
      whereArgs: [
        runId,
        BackupItemStatus.pending.name,
        BackupItemStatus.uploading.name,
        BackupItemStatus.failed.name,
      ],
    );
  }
}
