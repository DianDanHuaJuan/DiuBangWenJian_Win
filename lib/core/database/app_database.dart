import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../common/app_logger.dart';
import '../storage/platform_sqlite.dart';
import 'migration_registry.dart';

/// Single SQLite database (app.db) backing all features
/// (doc/01 §五: one database, one source of truth).
///
/// 各 feature 的建表/升级脚本在 DI 装配时传入 [migrations]，
/// AppDatabase 按 version 顺序执行（集中 schema_version）。
class AppDatabase {
  static const String _dbName = 'app.db';

  AppDatabase({List<SchemaMigration> migrations = const []}) {
    for (final migration in migrations) {
      MigrationRegistry.register(migration);
    }
  }

  Database? _database;

  Future<Database> get database async {
    return _database ??= await _initDatabase();
  }

  Future<Database> _initDatabase() async {
    PlatformSqlite.ensureInitialized();
    final dbPath = await _resolveDbDirectory();
    final version = MigrationRegistry.currentVersion;

    return openDatabase(
      p.join(dbPath, _dbName),
      version: version,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onConfigure: _onConfigure,
    );
  }

  Future<String> _resolveDbDirectory() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final support = await getApplicationSupportDirectory();
      final dir = Directory(support.path);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir.path;
    }
    return getDatabasesPath();
  }

  Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  Future<void> _onCreate(Database db, int version) async {
    for (final migration in MigrationRegistry.migrations) {
      await _run(db, migration);
    }
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    for (final migration in MigrationRegistry.migrations) {
      if (migration.version > oldVersion) {
        await _run(db, migration);
      }
    }
  }

  Future<void> _run(Database db, SchemaMigration migration) async {
    AppLogger.log(
      'Applying schema v${migration.version}',
      scope: 'database',
      details: {'feature': migration.feature},
    );
    await migration.up(db);
  }

  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }
}
