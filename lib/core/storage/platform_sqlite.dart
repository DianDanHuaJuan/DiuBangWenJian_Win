import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Windows 桌面：sqflite FFI。
class PlatformSqlite {
  PlatformSqlite._();

  static bool _initialized = false;

  static void ensureInitialized() {
    if (_initialized) return;
    sqfliteFfiInit();
    sqflite.databaseFactory = databaseFactoryFfi;
    _initialized = true;
  }

  static sqflite.DatabaseFactory resolveDatabaseFactory() {
    ensureInitialized();
    return databaseFactoryFfi;
  }
}
