import 'package:sqflite/sqflite.dart';

import '../database/migration_registry.dart';
import 'peer_repository.dart';

/// identity 表族迁移注册（doc/01 §五：集中版本号，feature 自注册）。
///
/// v1：peers 表（阶段 1）。
/// v2：peers.secret 列（局域网轻量认证：配对时交换的 Bearer 共享密钥，
///     旧记录空串 = 需重新配对，零兼容原则）。
/// v5：见 [identityStableIdMigration]（须排在 task v3 / chat v4 之后注册）。
const identityMigrations = <SchemaMigration>[
  SchemaMigration(
    version: 1,
    feature: 'identity',
    up: _createPeers,
  ),
  SchemaMigration(
    version: 2,
    feature: 'identity',
    up: _addPeerSecret,
  ),
];

/// peers.stable_id_hash（重装认旧）；schema v5，注册顺序在 chat v4 之后。
const identityStableIdMigration = SchemaMigration(
  version: 5,
  feature: 'identity',
  up: _addPeerStableIdHash,
);

/// peers.brand；schema v7（backup v6 之后）。
const identityBrandMigration = SchemaMigration(
  version: 7,
  feature: 'identity',
  up: _addPeerBrand,
);

/// peers.emoji；schema v8。
const identityEmojiMigration = SchemaMigration(
  version: 8,
  feature: 'identity',
  up: _addPeerEmoji,
);

Future<void> _createPeers(Database db) async {
  final repository = PeerRepository(db: () => db);
  await repository.createTable(db);
}

Future<void> _addPeerSecret(Database db) async {
  final repository = PeerRepository(db: () => db);
  await repository.addSecretColumn(db);
}

Future<void> _addPeerStableIdHash(Database db) async {
  final repository = PeerRepository(db: () => db);
  await repository.addStableIdHashColumn(db);
}

Future<void> _addPeerBrand(Database db) async {
  final repository = PeerRepository(db: () => db);
  await repository.addBrandColumn(db);
}

Future<void> _addPeerEmoji(Database db) async {
  final repository = PeerRepository(db: () => db);
  await repository.addEmojiColumn(db);
}
