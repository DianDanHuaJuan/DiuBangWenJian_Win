import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:diubangwenjian/core/common/key_value_store.dart';
import 'package:diubangwenjian/core/identity/peer.dart';
import 'package:diubangwenjian/core/pairing/pairing_payload.dart';
import 'package:diubangwenjian/core/pairing/pairing_services.dart';
import 'package:diubangwenjian/core/pairing/pair_password_service.dart';
import 'package:diubangwenjian/core/pairing/qr_crypto.dart';

void main() {
  group('NASPAIR4 载荷', () {
    test('encode/decode 往返一致（瘦身：裸 JSON + fp base64url）', () {
      final payload = PairingPayload(
        version: 4,
        host: '192.168.1.10',
        port: 5244,
        deviceName: '红米 K60',
        model: 'K60',
        fingerprint: 'ab' * 32,
        ticket: 'c0ffee',
        serverPublicKey: 'dGVzdA', // base64url "test"
        stableIdHash: 'should-not-appear',
      );
      final encoded = payload.encode();
      expect(encoded, startsWith('NASPAIR4:'));
      expect(encoded.contains('base64'), isFalse);
      expect(encoded.contains('"name"'), isFalse);
      expect(encoded.contains('"model"'), isFalse);
      expect(encoded.contains('sid'), isFalse);
      expect(encoded.contains('"t"'), isTrue);

      final decoded = PairingPayload.decode(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.host, '192.168.1.10');
      expect(decoded.fingerprint, 'ab' * 32);
      expect(decoded.ticket, 'c0ffee');
      expect(decoded.serverPublicKey, 'dGVzdA');
      expect(decoded.deviceName, isEmpty);
      expect(decoded.model, isEmpty);
      expect(decoded.stableIdHash, isNull);
    });

    test('兼容旧版 base64url(json) 含 name/model/sid', () {
      final legacyJson = jsonEncode({
        'v': 4,
        'host': '10.0.0.1',
        'port': 5244,
        'name': '旧机',
        'model': 'M1',
        'fp': 'cd' * 32,
        'ticket': 'legacyTicket',
        'pk': 'dGVzdA',
        'sid': 'sid-legacy',
      });
      final encoded =
          'NASPAIR4:${base64Url.encode(utf8.encode(legacyJson))}';
      final decoded = PairingPayload.decode(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.host, '10.0.0.1');
      expect(decoded.deviceName, '旧机');
      expect(decoded.stableIdHash, 'sid-legacy');
      expect(decoded.fingerprint, 'cd' * 32);
    });

    test('缺公钥/版本不符/格式错误返回 null', () {
      expect(PairingPayload.decode('NASPAIR4:!!!'), isNull);
      expect(PairingPayload.decode('https://example.com'), isNull);
    });
  });

  group('加密封装', () {
    final crypto = PairingCrypto();

    test('seal/open 往返（同密钥）', () async {
      final key = List<int>.generate(32, (i) => i);
      final sealed = await crypto.seal(
        key: key,
        plaintext: {'fp': 'cd' * 32, 'name': '测试机'},
      );
      final opened = await crypto.open(key: key, sealed: sealed);
      expect(opened, isNotNull);
      expect(opened!['fp'], 'cd' * 32);
    });

    test('密钥不符解密失败（密码错路径）', () async {
      final sealed = await crypto.seal(
        key: List<int>.generate(32, (i) => i),
        plaintext: {'x': 1},
      );
      final opened = await crypto.open(
        key: List<int>.generate(32, (i) => 255 - i),
        sealed: sealed,
      );
      expect(opened, isNull);
    });

    test('密码派生密钥确定性一致', () async {
      final a = await crypto.deriveKeyFromPassword('abc12345');
      final b = await crypto.deriveKeyFromPassword('abc12345');
      final c = await crypto.deriveKeyFromPassword('other!!');
      expect(a, b);
      expect(a, isNot(c));
    });

    test('X25519 协商双方派生同一会话密钥', () async {
      final a = await crypto.generateEphemeralKeyPair();
      final b = await crypto.generateEphemeralKeyPair();
      final aPub = await crypto.publicKeyBytes(a);
      final bPub = await crypto.publicKeyBytes(b);
      final keyA = await crypto.deriveSharedKey(
        ephemeralPrivate: a,
        peerPublicKeyBytes: bPub,
      );
      final keyB = await crypto.deriveSharedKey(
        ephemeralPrivate: b,
        peerPublicKeyBytes: aPub,
      );
      expect(keyA, keyB);
      expect(keyA, hasLength(32));
    });
  });

  group('密码配对服务', () {
    test('展示轮次：begin/verify/end', () async {
      SharedPreferences.setMockInitialValues({});
      final service = PairPasswordService(
        keyValueStore: KeyValueStore(
          sharedPreferences: await SharedPreferences.getInstance(),
        ),
      );

      final pwd = service.beginRound();
      expect(pwd, hasLength(8));
      expect(RegExp(r'^\d{8}$').hasMatch(pwd), isTrue);
      expect(service.hasActiveRound, isTrue);

      expect(await service.verify(pwd), isTrue);
      expect(await service.verify('00000000'), isFalse);
      expect(await service.verify(pwd), isTrue);

      service.endRound();
      expect(service.hasActiveRound, isFalse);
      expect(await service.verify(pwd), isFalse);
    });

    test('限速：连错 5 次锁 60s，正确密码也拒绝', () async {
      SharedPreferences.setMockInitialValues({});
      final service = PairPasswordService(
        keyValueStore: KeyValueStore(
          sharedPreferences: await SharedPreferences.getInstance(),
        ),
      );
      final pwd = service.beginRound();

      for (var i = 0; i < 5; i++) {
        await service.verify('wrong-$i');
      }
      expect(service.isLocked, isTrue);
      expect(service.remainingLockSeconds, greaterThan(0));
      expect(await service.verify(pwd), isFalse);
    });
  });

  group('票据防重放', () {
    test('一次性票据消费一次后失效', () {
      final registry = PairingTicketRegistry();
      final ticket = registry.issue(privateKeyBytes: List.filled(32, 1));
      expect(registry.peekPrivateKey(ticket), isNotNull);
      expect(registry.consume(ticket), isTrue);
      expect(registry.consume(ticket), isFalse);
      expect(registry.peekPrivateKey(ticket), isNull);
    });

    test('revoke 后不可再 peek/consume', () {
      final registry = PairingTicketRegistry();
      final ticket = registry.issue(privateKeyBytes: List.filled(32, 2));
      registry.revoke(ticket);
      expect(registry.peekPrivateKey(ticket), isNull);
      expect(registry.consume(ticket), isFalse);
    });
  });

  group('密码 enroll 双端闭环', () {
    test('client 构造 → host 处理 → client 落表（含 remoteIp）', () async {
      final store = <String, PeerRecord>{};
      final hostRepo = _FakePeerRepository(store, 'host');
      final clientRepo = _FakePeerRepository(store, 'client');

      SharedPreferences.setMockInitialValues({});
      final kvs = KeyValueStore(
        sharedPreferences: await SharedPreferences.getInstance(),
      );

      final host = PairingHostService(
        peerRepository: hostRepo,
        keyValueStore: kvs,
        identity: () async => (
              fingerprint: '11' * 32,
              name: '服务机',
              model: 'SM-S9080',
              stableIdHash: 'sid-host',
            ),
        localAddress: () => '192.168.1.10',
        port: () => 5244,
      );

      final client = PairingClientService(peerRepository: clientRepo);

      final round = await host.beginDisplayRound();
      final password = round.password;
      final sealed = await client.buildPasswordEnroll(
        password: password,
        fingerprint: '22' * 32,
        deviceName: '发起机',
        model: 'K60',
        listenPort: 5244,
      );

      final sealedResponse = await host.handlePasswordEnroll(
        sealed: sealed,
        remoteIp: '192.168.1.20',
      );
      expect(sealedResponse, isNotNull);

      final result = await client.consumePasswordResponse(
        password: password,
        sealedResponse: sealedResponse!,
        host: '192.168.1.10',
        port: 5244,
      );
      expect(result, isNotNull);
      expect(result!.peer.fingerprint, '11' * 32);
      expect(result.peer.secret, hasLength(64));

      expect(hostRepo.saved, isNotEmpty);
      expect(hostRepo.saved.first.fingerprint, '22' * 32);
      expect(hostRepo.saved.first.secret, result.peer.secret);
      expect(hostRepo.saved.first.lastSeenAddress, '192.168.1.20:5244');
    });

    test('缺 listenPort → enroll 拒绝且不落表', () async {
      final store = <String, PeerRecord>{};
      final hostRepo = _FakePeerRepository(store, 'host');

      SharedPreferences.setMockInitialValues({});
      final kvs = KeyValueStore(
        sharedPreferences: await SharedPreferences.getInstance(),
      );
      final host = PairingHostService(
        peerRepository: hostRepo,
        keyValueStore: kvs,
        identity: () async => (
              fingerprint: '11' * 32,
              name: '服务机',
              model: 'M',
              stableIdHash: 'sid-host',
            ),
        localAddress: () => '192.168.1.10',
        port: () => 5244,
      );

      // 手工构造无 listenPort 的密封包
      final crypto = PairingCrypto();
      final password = (await host.beginDisplayRound()).password;
      final key = await crypto.deriveKeyFromPassword(password);
      final sealed = await crypto.seal(
        key: key,
        plaintext: EnrollRequest(
          ticket: '',
          fingerprint: '22' * 32,
          deviceName: '发起机',
          model: 'K60',
        ).toJson(),
      );

      final response = await host.handlePasswordEnroll(
        sealed: sealed,
        remoteIp: '192.168.1.20',
      );
      expect(response, isNull);
      expect(hostRepo.saved, isEmpty);
    });

    test('密码错误 → 解密失败 → 双端都不落表', () async {
      final store = <String, PeerRecord>{};
      final hostRepo = _FakePeerRepository(store, 'host');
      final clientRepo = _FakePeerRepository(store, 'client');

      SharedPreferences.setMockInitialValues({});
      final kvs = KeyValueStore(
        sharedPreferences: await SharedPreferences.getInstance(),
      );
      final host = PairingHostService(
        peerRepository: hostRepo,
        keyValueStore: kvs,
        identity: () async => (
              fingerprint: '11' * 32,
              name: '服务机',
              model: 'M',
              stableIdHash: 'sid-host',
            ),
        localAddress: () => '192.168.1.10',
        port: () => 5244,
      );
      final client = PairingClientService(peerRepository: clientRepo);

      final sealed = await client.buildPasswordEnroll(
        password: 'wrong-pw',
        fingerprint: '22' * 32,
        deviceName: '发起机',
        model: 'K60',
        listenPort: 5244,
      );
      final response = await host.handlePasswordEnroll(sealed: sealed);
      expect(response, isNull);
      expect(hostRepo.saved, isEmpty);
      expect(clientRepo.saved, isEmpty);
    });
  });

  group('扫码 enroll 双端闭环（X25519）', () {
    test('QR 路径闭环：payload → enroll → 应答 → 双向落表', () async {
      final store = <String, PeerRecord>{};
      final hostRepo = _FakePeerRepository(store, 'host');
      final clientRepo = _FakePeerRepository(store, 'client');

      SharedPreferences.setMockInitialValues({});
      final kvs = KeyValueStore(
        sharedPreferences: await SharedPreferences.getInstance(),
      );
      final host = PairingHostService(
        peerRepository: hostRepo,
        keyValueStore: kvs,
        identity: () async => (
              fingerprint: '11' * 32,
              name: '被扫机',
              model: 'M2',
              stableIdHash: 'sid-host',
            ),
        localAddress: () => '192.168.1.10',
        port: () => 5244,
      );
      final client = PairingClientService(peerRepository: clientRepo);

      final payload = await host.buildQrPayload();
      expect(payload.host, '192.168.1.10');
      expect(payload.ticket, isNotEmpty);
      expect(payload.serverPublicKey, isNotEmpty);

      final package = await client.buildQrEnroll(
        payload: payload,
        fingerprint: '22' * 32,
        deviceName: '扫码机',
        model: 'K60',
        listenPort: 5244,
      );

      final sealedResponse = await host.handleQrEnroll(
        sealed: package.sealed,
        clientPublicKey: package.clientPublicKey,
        ticket: payload.ticket,
        remoteIp: '192.168.1.30',
      );
      expect(sealedResponse, isNotNull);

      final result = await client.consumeQrResponse(
        payload: payload,
        sealedResponse: sealedResponse!,
        sessionKey: package.sessionKey,
      );
      expect(result, isNotNull);
      expect(result!.peer.fingerprint, '11' * 32);
      expect(result.peer.secret, hasLength(64));

      expect(hostRepo.saved.first.fingerprint, '22' * 32);
      expect(hostRepo.saved.first.secret, result.peer.secret);
      expect(hostRepo.saved.first.lastSeenAddress, '192.168.1.30:5244');
    });

    test('票据防重放：同一 enroll 重放被拒', () async {
      final store = <String, PeerRecord>{};
      final hostRepo = _FakePeerRepository(store, 'host');

      SharedPreferences.setMockInitialValues({});
      final kvs = KeyValueStore(
        sharedPreferences: await SharedPreferences.getInstance(),
      );
      final host = PairingHostService(
        peerRepository: hostRepo,
        keyValueStore: kvs,
        identity: () async => (
              fingerprint: '11' * 32,
              name: '被扫机',
              model: 'M2',
              stableIdHash: 'sid-host',
            ),
        localAddress: () => '192.168.1.10',
        port: () => 5244,
      );
      final client =
          PairingClientService(peerRepository: _FakePeerRepository(store, 'client'));

      final payload = await host.buildQrPayload();
      final package = await client.buildQrEnroll(
        payload: payload,
        fingerprint: '22' * 32,
        deviceName: '扫码机',
        model: 'K60',
        listenPort: 5244,
      );

      final first = await host.handleQrEnroll(
        sealed: package.sealed,
        clientPublicKey: package.clientPublicKey,
        ticket: payload.ticket,
      );
      expect(first, isNotNull);

      final replay = await host.handleQrEnroll(
        sealed: package.sealed,
        clientPublicKey: package.clientPublicKey,
        ticket: payload.ticket,
      );
      expect(replay, isNull);
    });

    test('应答指纹不一致 → 拒绝落表', () async {
      final store = <String, PeerRecord>{};
      final clientRepo = _FakePeerRepository(store, 'client');
      final client = PairingClientService(peerRepository: clientRepo);
      final crypto = PairingCrypto();

      final payload = PairingPayload(
        version: 4,
        host: '192.168.1.10',
        port: 5244,
        deviceName: '被扫机',
        model: 'M2',
        fingerprint: '11' * 32,
        ticket: 'deadbeef',
        serverPublicKey: 'dGVzdA',
      );

      final sessionKey = List<int>.generate(32, (i) => i);
      final evil = await crypto.seal(
        key: sessionKey,
        plaintext: {
          'fp': '33' * 32,
          'name': '顶替机',
          'model': 'X',
          'secret': '44' * 32,
        },
      );
      final result = await client.consumeQrResponse(
        payload: payload,
        sealedResponse: evil,
        sessionKey: sessionKey,
      );
      expect(result, isNull);
      expect(clientRepo.saved, isEmpty);
    });
  });
}

class PeerRecord {
  final String fingerprint;
  final String secret;
  final String? lastSeenAddress;
  PeerRecord(this.fingerprint, [this.secret = '', this.lastSeenAddress]);
}

class _FakePeerRepository implements PeerWriter {
  _FakePeerRepository(this.store, this.owner);
  final Map<String, PeerRecord> store;
  final String owner;
  final List<PeerRecord> saved = [];

  @override
  Future<void> upsert(Peer peer) async {
    final record = PeerRecord(
      peer.fingerprint,
      peer.secret,
      peer.lastSeenAddress,
    );
    store[peer.fingerprint] = record;
    saved.add(record);
  }
}
