import 'package:sqflite/sqflite.dart';

import '../../../../core/database/migration_registry.dart';
import '../../domain/entities/chat_message.dart';

/// 聊天消息本地存储。
class ChatLocalDataSource {
  static const table = 'chat_messages';

  ChatLocalDataSource({required Database Function() db}) : _db = db;

  final Database Function() _db;

  Future<void> createTable(Database database) async {
    await database.execute('''
      CREATE TABLE $table (
        id TEXT PRIMARY KEY,
        peer_fingerprint TEXT NOT NULL,
        direction TEXT NOT NULL,
        kind TEXT NOT NULL,
        body TEXT NOT NULL,
        created_at_ms INTEGER NOT NULL
      )
    ''');
    await database.execute(
      'CREATE INDEX idx_chat_peer ON $table(peer_fingerprint, created_at_ms)',
    );
  }

  Future<void> upsert(ChatMessage message) async {
    await _db().insert(
      table,
      message.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<ChatMessage>> listForPeer(String fingerprint) async {
    final rows = await _db().query(
      table,
      where: 'peer_fingerprint = ?',
      whereArgs: [fingerprint],
      orderBy: 'created_at_ms ASC',
    );
    return rows.map(ChatMessage.fromMap).toList();
  }

  Future<ChatMessage?> findById(String id) async {
    final rows = await _db().query(
      table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ChatMessage.fromMap(rows.first);
  }
}

/// chat 表迁移 v4。
const chatMigrations = <SchemaMigration>[
  SchemaMigration(
    version: 4,
    feature: 'chat',
    up: _createChat,
  ),
];

Future<void> _createChat(Database db) async {
  await ChatLocalDataSource(db: () => db).createTable(db);
}
