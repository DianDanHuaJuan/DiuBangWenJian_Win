import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:diubangwenjian/core/identity/migrations.dart' as identity;
import 'package:diubangwenjian/core/identity/peer.dart';
import 'package:diubangwenjian/core/identity/peer_repository.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late PeerRepository repository;
  late dynamic db;

  /// singleInstance: false：每次独立内存连接（否则 :memory: 复用实例，
  /// 二次建表报 already exists）。
  Future<dynamic> openDb() async {
    final database = await openDatabase(
      inMemoryDatabasePath,
      version: 1,
      singleInstance: false,
    );
    for (final migration in identity.identityMigrations) {
      await migration.up(database);
    }
    await identity.identityStableIdMigration.up(database);
    await identity.identityBrandMigration.up(database);
    await identity.identityEmojiMigration.up(database);
    return database;
  }

  setUp(() async {
    db = await openDb();
    repository = PeerRepository(db: () => db as dynamic);
  });

  tearDown(() async {
    await (db as dynamic).close();
  });

  test('upsert + findByFingerprint：写入与指纹查询往返（含 secret）', () async {
    final peer = Peer(
      fingerprint: 'aa' * 32,
      name: '红米 K60',
      model: 'K60',
      pairedAt: 1700000000000,
      secret: '11' * 32,
    );
    await repository.upsert(peer);

    final found = await repository.findByFingerprint('aa' * 32);
    expect(found, isNotNull);
    expect(found!.name, '红米 K60');
    expect(found.model, 'K60');
    expect(found.secret, '11' * 32);
  });

  test('upsert 幂等：重复配对刷新字段不建新行', () async {
    final fp = 'bb' * 32;
    await repository.upsert(Peer(
      fingerprint: fp,
      name: '旧名',
      model: 'M1',
      pairedAt: 1,
      secret: '22' * 32,
    ));
    await repository.upsert(Peer(
      fingerprint: fp,
      name: '新名',
      model: 'M1',
      pairedAt: 2,
      secret: '33' * 32, // 重新配对换新 secret
      lastSeenAddress: '192.168.1.5:5244',
    ));

    final all = await repository.getAll();
    expect(all, hasLength(1));
    expect(all.first.name, '新名');
    expect(all.first.secret, '33' * 32);
    expect(all.first.lastSeenAddress, '192.168.1.5:5244');
  });

  test('rename 改显示名', () async {
    final fp = 'cc' * 32;
    await repository.upsert(Peer(
      fingerprint: fp,
      name: 'A',
      model: 'M',
      pairedAt: 1,
      secret: '44' * 32,
    ));
    await repository.rename(fp, 'B');
    expect((await repository.findByFingerprint(fp))!.name, 'B');
  });

  test('revoke 删行即吊销：查不到即不信任', () async {
    final fp = 'dd' * 32;
    await repository.upsert(Peer(
      fingerprint: fp,
      name: 'A',
      model: 'M',
      pairedAt: 1,
      secret: '55' * 32,
    ));
    await repository.revoke(fp);
    expect(await repository.findByFingerprint(fp), isNull);
    expect(await repository.getAll(), isEmpty);
  });

  test('stable_id 合并：同 sid 新指纹替换旧行并保留首次配对时间', () async {
    final oldFp = 'aa' * 32;
    final newFp = 'bb' * 32;
    const sid = 'same-physical-hash';
    var supersededFrom = '';
    var supersededTo = '';
    final merging = PeerRepository(
      db: () => db as dynamic,
      onFingerprintSuperseded: (from, to) {
        supersededFrom = from;
        supersededTo = to;
      },
    );

    await merging.upsert(Peer(
      fingerprint: oldFp,
      name: '旧名',
      model: 'M',
      pairedAt: 1000,
      secret: '11' * 32,
      stableIdHash: sid,
    ));
    await (db as dynamic).execute('''
      CREATE TABLE IF NOT EXISTS chat_messages (
        id TEXT PRIMARY KEY,
        peer_fingerprint TEXT NOT NULL,
        direction TEXT NOT NULL,
        kind TEXT NOT NULL,
        body TEXT NOT NULL,
        created_at_ms INTEGER NOT NULL
      )
    ''');
    await (db as dynamic).insert('chat_messages', {
      'id': 'm1',
      'peer_fingerprint': oldFp,
      'direction': 'in',
      'kind': 'text',
      'body': 'hi',
      'created_at_ms': 1,
    });

    await merging.upsert(Peer(
      fingerprint: newFp,
      name: '新名',
      model: 'M',
      pairedAt: 9000,
      secret: '22' * 32,
      stableIdHash: sid,
      lastSeenAddress: '10.0.0.2:5244',
    ));

    expect(await merging.findByFingerprint(oldFp), isNull);
    final merged = await merging.findByFingerprint(newFp);
    expect(merged, isNotNull);
    expect(merged!.name, '新名');
    expect(merged.pairedAt, 1000); // 保留首次
    expect(merged.stableIdHash, sid);
    expect(await merging.getAll(), hasLength(1));
    expect(supersededFrom, oldFp);
    expect(supersededTo, newFp);

    final chats = await (db as dynamic).query('chat_messages');
    expect(chats, hasLength(1));
    expect(chats.first['peer_fingerprint'], newFp);
  });

  group('迁移 v2（secret 列）', () {
    test('新库：v1+v2 全量迁移 → secret 列存在且默认空串', () async {
      final database = await openDb();
      final columns = await database.rawQuery(
        'PRAGMA table_info(peers)',
      );
      final secretColumn = columns
          .where((c) => c['name'] == 'secret')
          .toList();
      expect(secretColumn, hasLength(1));
      expect(secretColumn.first['notnull'], 1);

      // 旧行为兼容：不传 secret 的行 → 空串（旧记录语义）
      final repo = PeerRepository(db: () => database);
      await database.insert('peers', {
        'fingerprint': 'ee' * 32,
        'name': '直插行',
        'model': 'M',
        'paired_at': 1,
      });
      final peer = await repo.findByFingerprint('ee' * 32);
      expect(peer!.secret, '');
      await database.close();
    });

    test('旧库 v1 → v2：ALTER 后老行 secret 为空（需重新配对）', () async {
      // 模拟旧库：只跑 v1（独立内存连接）
      final database = await openDatabase(
        inMemoryDatabasePath,
        version: 1,
        singleInstance: false,
      );
      final v1Only = identity.identityMigrations
          .where((m) => m.version == 1)
          .toList();
      for (final migration in v1Only) {
        await migration.up(database);
      }
      await database.insert('peers', {
        'fingerprint': 'ff' * 32,
        'name': '老配对',
        'model': 'M',
        'paired_at': 1,
      });

      // 升级：跑 v2
      for (final migration
          in identity.identityMigrations.where((m) => m.version == 2)) {
        await migration.up(database);
      }

      final repo = PeerRepository(db: () => database);
      final peer = await repo.findByFingerprint('ff' * 32);
      expect(peer, isNotNull);
      expect(peer!.secret, ''); // 空串 = 无签名密钥，中间件拒绝
      await database.close();
    });
  });
}
