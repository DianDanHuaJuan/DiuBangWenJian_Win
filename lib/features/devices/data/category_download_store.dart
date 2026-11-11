import 'package:sqflite/sqflite.dart';

import '../../../core/database/migration_registry.dart';
import '../domain/category_download_run.dart';

const categoryDownloadMigrations = <SchemaMigration>[
  SchemaMigration(
    version: 9,
    feature: 'category_download',
    up: _createCategoryDownloadTables,
  ),
];

Future<void> _createCategoryDownloadTables(Database db) async {
  await db.execute('''
CREATE TABLE IF NOT EXISTS category_download_runs (
  id TEXT PRIMARY KEY NOT NULL,
  peer_fingerprint TEXT NOT NULL,
  peer_name TEXT NOT NULL DEFAULT '',
  category TEXT NOT NULL,
  scope_path TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL,
  list_offset INTEGER NOT NULL DEFAULT 0,
  list_done INTEGER NOT NULL DEFAULT 0,
  total_count INTEGER NOT NULL DEFAULT 0,
  success_count INTEGER NOT NULL DEFAULT 0,
  skipped_count INTEGER NOT NULL DEFAULT 0,
  failed_count INTEGER NOT NULL DEFAULT 0,
  error_message TEXT,
  started_at_ms INTEGER NOT NULL,
  ended_at_ms INTEGER
)
''');
  await db.execute('''
CREATE TABLE IF NOT EXISTS category_download_items (
  id TEXT PRIMARY KEY NOT NULL,
  run_id TEXT NOT NULL,
  task_id TEXT NOT NULL,
  remote_key TEXT NOT NULL,
  status TEXT NOT NULL
)
''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_cat_dl_items_run ON category_download_items(run_id)',
  );
}

class CategoryDownloadStore {
  CategoryDownloadStore({required Future<Database> Function() db}) : _db = db;

  final Future<Database> Function() _db;

  Future<void> upsertRun(CategoryDownloadRun run) async {
    final db = await _db();
    final existing = await db.query(
      'category_download_runs',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [run.id],
      limit: 1,
    );
    if (existing.isEmpty) {
      await db.insert('category_download_runs', run.toMap());
    } else {
      await db.update(
        'category_download_runs',
        run.toMap(),
        where: 'id = ?',
        whereArgs: [run.id],
      );
    }
  }

  Future<CategoryDownloadRun?> findRun(String id) async {
    final db = await _db();
    final rows = await db.query(
      'category_download_runs',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return CategoryDownloadRun.fromMap(rows.first);
  }

  Future<CategoryDownloadRun?> findActive() async {
    final db = await _db();
    final rows = await db.query(
      'category_download_runs',
      where: 'status = ? OR status = ?',
      whereArgs: [
        CategoryDownloadStatus.running.name,
        CategoryDownloadStatus.paused.name,
      ],
      orderBy: 'started_at_ms DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return CategoryDownloadRun.fromMap(rows.first);
  }

  Future<void> demoteRunningToPaused() async {
    final db = await _db();
    await db.update(
      'category_download_runs',
      {
        'status': CategoryDownloadStatus.paused.name,
        'error_message': '已中断',
      },
      where: 'status = ?',
      whereArgs: [CategoryDownloadStatus.running.name],
    );
  }

  Future<void> insertItem(CategoryDownloadItem item) async {
    final db = await _db();
    await db.insert('category_download_items', item.toMap());
  }

  Future<List<CategoryDownloadItem>> listItems(String runId) async {
    final db = await _db();
    final rows = await db.query(
      'category_download_items',
      where: 'run_id = ?',
      whereArgs: [runId],
    );
    return rows.map(CategoryDownloadItem.fromMap).toList();
  }

  Future<void> updateItemStatus(String id, String status) async {
    final db = await _db();
    await db.update(
      'category_download_items',
      {'status': status},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
