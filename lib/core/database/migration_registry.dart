import 'package:sqflite/sqflite.dart';

/// A single schema change owned by a feature.
///
/// Versioning: [version] is the schema version this migration produces.
/// Versions must be strictly increasing across all registered
/// migrations (doc/01 §五: centralized schema_version, per-feature
/// registration, executed by AppDatabase).
class SchemaMigration {
  final int version;
  final String feature;
  final Future<void> Function(Database db) up;

  const SchemaMigration({
    required this.version,
    required this.feature,
    required this.up,
  });
}

/// Registration point for per-feature create/upgrade scripts.
///
/// Features register their migrations at DI time (before the first
/// database access); AppDatabase executes them in order.
abstract final class MigrationRegistry {
  static const int baseVersion = 1;
  static final List<SchemaMigration> _migrations = [];

  static List<SchemaMigration> get migrations =>
      List.unmodifiable(_migrations);

  static int get currentVersion =>
      _migrations.isEmpty ? baseVersion : _migrations.last.version;

  static void register(SchemaMigration migration) {
    if (_migrations.any((m) => m.version >= migration.version)) {
      throw StateError(
        'Schema version ${migration.version} of "${migration.feature}" must '
        'be greater than the last registered version '
        '(${_migrations.isEmpty ? baseVersion : _migrations.last.version}).',
      );
    }
    _migrations.add(migration);
  }

  static void clear() => _migrations.clear();
}
