import 'package:sqflite/sqflite.dart';

import '../../../core/database/migration_registry.dart';

/// 备份 Run / 明细表（schema v6）。
const backupMigrations = <SchemaMigration>[
  SchemaMigration(
    version: 6,
    feature: 'backup',
    up: _createBackupTables,
  ),
];

Future<void> _createBackupTables(Database db) async {
  await db.execute('''
CREATE TABLE IF NOT EXISTS backup_runs (
  id TEXT PRIMARY KEY NOT NULL,
  peer_fingerprint TEXT NOT NULL,
  peer_name TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL,
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
CREATE TABLE IF NOT EXISTS backup_run_items (
  id TEXT PRIMARY KEY NOT NULL,
  run_id TEXT NOT NULL,
  source_id TEXT NOT NULL,
  local_path TEXT NOT NULL,
  display_name TEXT NOT NULL,
  category TEXT NOT NULL,
  size_bytes INTEGER NOT NULL DEFAULT 0,
  mime_type TEXT,
  status TEXT NOT NULL,
  error_message TEXT,
  sort_index INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY (run_id) REFERENCES backup_runs (id) ON DELETE CASCADE
)
''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_backup_items_run ON backup_run_items(run_id)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_backup_runs_status ON backup_runs(status)',
  );
}
