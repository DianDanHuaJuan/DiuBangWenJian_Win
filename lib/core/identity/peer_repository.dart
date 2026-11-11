import 'package:sqflite/sqflite.dart';

import '../common/app_logger.dart';
import '../pairing/pairing_services.dart' show PeerWriter;
import 'peer.dart';

/// 与 chat / transfer 表名对齐（避免 core→features 反向依赖）。
const _chatMessagesTable = 'chat_messages';
const _transferTasksTable = 'transfer_tasks';

/// peers 表 CRUD + 指纹查询（doc/02 core/identity：peer_repository，
/// 接口+实现同文件——feature 小时允许合并）。
///
/// 信任模型核心（决策 #2/#9）：指纹在表内 → 信任；删行 → 吊销。
/// 同物理设备重装：按 [Peer.stableIdHash] 合并，吊销旧指纹并迁移附属表。
class PeerRepository implements PeerWriter {
  static const table = 'peers';

  final Database Function() db;

  /// 指纹被稳定 ID 合并替换时回调（清在线视图 / 拨号缓存）。
  final void Function(String fromFingerprint, String toFingerprint)?
      onFingerprintSuperseded;

  PeerRepository({
    required this.db,
    this.onFingerprintSuperseded,
  });

  Future<void> createTable(Database database) async {
    // v1 原始结构（不含 secret；v2 迁移加列——迁移演进保持历史原样）
    await database.execute('''
      CREATE TABLE $table (
        fingerprint TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        model TEXT NOT NULL,
        paired_at INTEGER NOT NULL,
        last_seen_address TEXT
      )
    ''');
  }

  /// v2：加 secret 列（Bearer 共享密钥，hex 存储）。
  Future<void> addSecretColumn(Database database) async {
    await database.execute(
      "ALTER TABLE $table ADD COLUMN secret TEXT NOT NULL DEFAULT ''",
    );
  }

  /// v5：稳定物理线索哈希（重装认旧合并键）。
  Future<void> addStableIdHashColumn(Database database) async {
    await database.execute(
      'ALTER TABLE $table ADD COLUMN stable_id_hash TEXT',
    );
    await database.execute(
      'CREATE INDEX IF NOT EXISTS idx_peers_stable_id '
      'ON $table(stable_id_hash)',
    );
  }

  /// v7：品牌（announce / enroll / WS 首帧；持久 Static）。
  Future<void> addBrandColumn(Database database) async {
    await database.execute(
      "ALTER TABLE $table ADD COLUMN brand TEXT NOT NULL DEFAULT ''",
    );
  }

  /// v8：展示 emoji（announce / WS static；可随对端更换而更新）。
  Future<void> addEmojiColumn(Database database) async {
    await database.execute(
      "ALTER TABLE $table ADD COLUMN emoji TEXT NOT NULL DEFAULT ''",
    );
  }

  /// upsert：enroll 成功后写入；若 [Peer.stableIdHash] 命中旧行则合并。
  @override
  Future<void> upsert(Peer peer) async {
    final sid = peer.stableIdHash?.trim();
    String? superseded;
    var toWrite = peer;

    if (sid != null && sid.isNotEmpty) {
      final existing = await findByStableIdHash(sid);
      if (existing != null && existing.fingerprint != peer.fingerprint) {
        superseded = existing.fingerprint;
        toWrite = peer.copyWith(
          pairedAt: existing.pairedAt,
          brand: peer.brand.trim().isNotEmpty ? peer.brand : existing.brand,
          model: peer.model.trim().isNotEmpty ? peer.model : existing.model,
          emoji: peer.emoji.trim().isNotEmpty ? peer.emoji : existing.emoji,
        );
        await revoke(existing.fingerprint);
        await _remapRelatedTables(
          fromFingerprint: existing.fingerprint,
          toFingerprint: peer.fingerprint,
        );
        AppLogger.log(
          'peer merged by stable_id',
          scope: 'identity',
          details: {
            'from': existing.fingerprint.substring(0, 8),
            'to': peer.fingerprint.substring(0, 8),
          },
        );
      }
    }

    final previous = await findByFingerprint(toWrite.fingerprint);
    if (previous != null) {
      if (toWrite.brand.trim().isEmpty && previous.brand.trim().isNotEmpty) {
        toWrite = toWrite.copyWith(brand: previous.brand);
      }
      if (toWrite.emoji.trim().isEmpty && previous.emoji.trim().isNotEmpty) {
        toWrite = toWrite.copyWith(emoji: previous.emoji);
      }
    }

    await db().insert(
      table,
      toWrite.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    if (superseded != null) {
      onFingerprintSuperseded?.call(superseded, toWrite.fingerprint);
    }
  }

  /// 指纹查询（认证中间件热路径）。
  Future<Peer?> findByFingerprint(String fingerprint) async {
    final rows = await db().query(
      table,
      where: 'fingerprint = ?',
      whereArgs: [fingerprint],
      limit: 1,
    );
    return rows.isEmpty ? null : Peer.fromMap(rows.first);
  }

  /// 按稳定 ID 哈希查找（重装合并）。
  Future<Peer?> findByStableIdHash(String stableIdHash) async {
    final sid = stableIdHash.trim();
    if (sid.isEmpty) return null;
    final rows = await db().query(
      table,
      where: 'stable_id_hash = ?',
      whereArgs: [sid],
      limit: 1,
    );
    return rows.isEmpty ? null : Peer.fromMap(rows.first);
  }

  Future<List<Peer>> getAll() async {
    final rows = await db().query(table, orderBy: 'paired_at DESC');
    return rows.map(Peer.fromMap).toList();
  }

  Future<void> rename(String fingerprint, String newName) async {
    await db().update(
      table,
      {'name': newName},
      where: 'fingerprint = ?',
      whereArgs: [fingerprint],
    );
  }

  /// 仅当库内 brand 为空时写入（announce / WS 首帧补全）。返回是否写入。
  Future<bool> fillBrandIfEmpty(String fingerprint, String brand) async {
    final b = brand.trim();
    if (b.isEmpty) return false;
    final existing = await findByFingerprint(fingerprint);
    if (existing == null || existing.brand.trim().isNotEmpty) return false;
    await db().update(
      table,
      {'brand': b},
      where: 'fingerprint = ?',
      whereArgs: [fingerprint],
    );
    return true;
  }

  /// 仅当库内 model 为空时写入。返回是否写入。
  Future<bool> fillModelIfEmpty(String fingerprint, String model) async {
    final m = model.trim();
    if (m.isEmpty) return false;
    final existing = await findByFingerprint(fingerprint);
    if (existing == null || existing.model.trim().isNotEmpty) return false;
    await db().update(
      table,
      {'model': m},
      where: 'fingerprint = ?',
      whereArgs: [fingerprint],
    );
    return true;
  }

  /// 对端展示 emoji：非空且与库内不同则更新（允许更换）。返回是否写入。
  Future<bool> updateEmoji(String fingerprint, String emoji) async {
    final e = emoji.trim();
    if (e.isEmpty) return false;
    final existing = await findByFingerprint(fingerprint);
    if (existing == null || existing.emoji == e) return false;
    await db().update(
      table,
      {'emoji': e},
      where: 'fingerprint = ?',
      whereArgs: [fingerprint],
    );
    return true;
  }

  /// 更新最近地址（announce / enroll 回写）。
  Future<void> updateLastSeenAddress(
    String fingerprint,
    String address,
  ) async {
    await db().update(
      table,
      {'last_seen_address': address},
      where: 'fingerprint = ?',
      whereArgs: [fingerprint],
    );
  }

  /// 删除 = 吊销（doc/01 §六：删行即断）。
  Future<void> revoke(String fingerprint) async {
    await db().delete(
      table,
      where: 'fingerprint = ?',
      whereArgs: [fingerprint],
    );
  }

  Future<void> _remapRelatedTables({
    required String fromFingerprint,
    required String toFingerprint,
  }) async {
    final database = db();
    // 表可能尚未迁移（极早期库）；忽略缺失表错误
    try {
      await database.update(
        _chatMessagesTable,
        {'peer_fingerprint': toFingerprint},
        where: 'peer_fingerprint = ?',
        whereArgs: [fromFingerprint],
      );
    } catch (_) {}
    try {
      await database.update(
        _transferTasksTable,
        {'peer_fingerprint': toFingerprint},
        where: 'peer_fingerprint = ?',
        whereArgs: [fromFingerprint],
      );
    } catch (_) {}
  }
}
