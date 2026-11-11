import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:diubangwenjian/core/discovery/discovery_service.dart';
import 'package:diubangwenjian/core/discovery/peer_registry.dart';
import 'package:diubangwenjian/core/identity/peer.dart';

void main() {
  group('AnnouncePayload 编解码', () {
    test('encode/decode 往返一致（含 wantReply / brand）', () {
      final payload = AnnouncePayload(
        version: 1,
        fingerprint: 'ab' * 32,
        name: '红米 K60',
        brand: 'Redmi',
        model: 'K60',
        host: '192.168.1.10',
        port: 5244,
        wantReply: true,
      );
      final decoded = AnnouncePayload.decode(
        '{"v":1,"fp":"${'ab' * 32}","name":"红米 K60","brand":"Redmi",'
        '"model":"K60","host":"192.168.1.10","port":5244,"r":1}',
      );
      expect(decoded, isNotNull);
      expect(decoded!.fingerprint, payload.fingerprint);
      expect(decoded.name, payload.name);
      expect(decoded.brand, 'Redmi');
      expect(decoded.host, payload.host);
      expect(decoded.port, payload.port);
      expect(decoded.wantReply, isTrue);
    });

    test('缺省 brand / emoji 兼容旧包', () {
      final legacy = AnnouncePayload.decode(
        '{"v":1,"fp":"x","name":"n","model":"m","host":"h","port":1}',
      );
      expect(legacy!.brand, '');
      expect(legacy.emoji, '');
    });

    test('emoji 编解码', () {
      final decoded = AnnouncePayload.decode(
        '{"v":1,"fp":"x","name":"n","model":"m","emoji":"🦊",'
        '"host":"h","port":1}',
      );
      expect(decoded!.emoji, '🦊');
      expect(
        AnnouncePayload(
          version: 1,
          fingerprint: 'x',
          name: 'n',
          model: 'm',
          emoji: '🦊',
          host: 'h',
          port: 1,
        ).toJson()['emoji'],
        '🦊',
      );
    });

    test('r=0 → 回声包不再触发回声；缺省 r 视为需要回声', () {
      final reply = AnnouncePayload.decode(
        '{"v":1,"fp":"x","name":"n","model":"m","host":"h","port":1,"r":0}',
      );
      expect(reply!.wantReply, isFalse);

      final legacy = AnnouncePayload.decode(
        '{"v":1,"fp":"x","name":"n","model":"m","host":"h","port":1}',
      );
      expect(legacy!.wantReply, isTrue);
    });

    test('异版本/乱包返回 null', () {
      expect(AnnouncePayload.decode('{"v":2,...}'), isNull);
      expect(AnnouncePayload.decode('not json'), isNull);
    });
  });

  group('定时参数', () {
    test('5s 心跳 / 10s 离线（2 拍） / 1s 扫地', () {
      expect(announceInterval, const Duration(seconds: 5));
      expect(offlineTimeout, const Duration(seconds: 10));
      expect(presenceSweepInterval, const Duration(seconds: 1));
      expect(discoveryEnsureMaxAttempts, 3);
    });
  });

  group('PeerRegistry 在线聚合', () {
    late PeerRegistry registry;
    var now = 1000000;

    Peer peer(String fp) => Peer(
          fingerprint: fp,
          name: 'peer-$fp',
          model: 'model',
          pairedAt: 0,
          secret: '00' * 32,
        );

    setUp(() {
      now = 1000000;
      registry = PeerRegistry(
        pairedPeers: () => [peer('a' * 64), peer('b' * 64)],
        loadPeers: () async => [peer('a' * 64), peer('b' * 64)],
        nowMillis: () => now,
      );
    });

    AnnouncePayload announce(String fp) => AnnouncePayload(
          version: 1,
          fingerprint: fp,
          name: 'dev-$fp',
          model: 'm',
          host: '192.168.1.50',
          port: 5244,
        );

    test('已配对 announce → onlinePaired', () {
      registry.onAnnounce(announce('a' * 64));
      expect(registry.onlinePaired, hasLength(1));
      expect(registry.onlinePaired.first.fingerprint, 'a' * 64);
      expect(registry.nearby, isEmpty);
    });

    test('未配对 announce → nearby 线索（不进 onlinePaired）', () {
      registry.onAnnounce(announce('c' * 64));
      expect(registry.onlinePaired, isEmpty);
      expect(registry.nearby, hasLength(1));
      expect(registry.nearby.first.fingerprint, 'c' * 64);
    });

    test('10s 超时扫地（已配对与附近同一套）', () async {
      registry.onAnnounce(announce('c' * 64));
      expect(registry.nearby, hasLength(1));
      now += 9999;
      await registry.sweepExpired();
      expect(registry.nearby, hasLength(1));
      now += 1;
      await registry.sweepExpired();
      expect(registry.nearby, isEmpty);

      // 无 verify 回调时已配对也直接摘（兼容旧行为）。
      registry.onAnnounce(announce('a' * 64));
      expect(registry.onlinePaired, hasLength(1));
      now += 10000;
      await registry.sweepExpired();
      expect(registry.onlinePaired, isEmpty);
    });

    test('心跳续命：announce 刷新 lastSeen（已配对同样）', () async {
      registry.onAnnounce(announce('a' * 64));
      for (var i = 0; i < 5; i++) {
        now += announceInterval.inMilliseconds;
        registry.onAnnounce(announce('a' * 64));
        await registry.sweepExpired();
        expect(registry.onlinePaired, hasLength(1));
      }
    });

    test('方案A：已配对超时 ping 通则续命不摘', () async {
      registry.onAnnounce(announce('a' * 64));
      now += offlineTimeout.inMilliseconds;
      final pinged = <String>[];
      await registry.sweepExpired(
        verifyPairedReachable: (peer) async {
          pinged.add(peer.fingerprint);
          return true;
        },
      );
      expect(pinged, ['a' * 64]);
      expect(registry.onlinePaired, hasLength(1));
      // 续命后未再超时则不再 ping
      await registry.sweepExpired(
        verifyPairedReachable: (_) async => false,
      );
      expect(registry.onlinePaired, hasLength(1));
    });

    test('方案A：已配对超时 ping 不通则标灰', () async {
      registry.onAnnounce(announce('a' * 64));
      now += offlineTimeout.inMilliseconds;
      await registry.sweepExpired(
        verifyPairedReachable: (_) async => false,
      );
      expect(registry.onlinePaired, isEmpty);
    });

    test('方案A：ping 进行中若 announce 续命则失败也不摘', () async {
      registry.onAnnounce(announce('a' * 64));
      now += offlineTimeout.inMilliseconds;
      final gate = Completer<bool>();
      final sweeping = registry.sweepExpired(
        verifyPairedReachable: (_) => gate.future,
      );
      expect(registry.onlinePaired, hasLength(1));
      // 门闸未完成时 UDP 回来
      now += 1000;
      registry.onAnnounce(announce('a' * 64));
      gate.complete(false);
      await sweeping;
      expect(registry.onlinePaired, hasLength(1));
    });

    test('markReachable 可本地注入在线（不替代 announce 续命）', () {
      registry.markReachable(
        fingerprint: 'a' * 64,
        name: 'n',
        model: 'm',
        address: '192.168.1.9:5244',
      );
      expect(registry.isOnline('a' * 64), isTrue);
      expect(registry.onlinePaired, hasLength(1));
    });

    test('配对后从 nearby 转入 onlinePaired（仍靠同一条 announce）', () async {
      final paired = <Peer>[peer('a' * 64)];
      late PeerRegistry dynamicRegistry;
      dynamicRegistry = PeerRegistry(
        pairedPeers: () => paired,
        loadPeers: () async => paired,
        nowMillis: () => now,
      );

      dynamicRegistry.onAnnounce(announce('c' * 64));
      expect(dynamicRegistry.nearby, hasLength(1));

      paired.add(peer('c' * 64));
      await dynamicRegistry.reloadPaired();
      expect(dynamicRegistry.nearby, isEmpty);
      expect(dynamicRegistry.onlinePaired, hasLength(1));
      expect(dynamicRegistry.onlinePaired.first.fingerprint, 'c' * 64);
    });

    test('流广播：未配对 announce 推送 nearbyStream', () async {
      final events = <List<OnlinePeer>>[];
      final sub = registry.nearbyStream.listen(events.add);
      registry.onAnnounce(announce('c' * 64));
      await Future<void>.delayed(Duration.zero);
      expect(events, isNotNull);
      expect(events.last, hasLength(1));
      await sub.cancel();
    });
  });

  group('DiscoveryService 隐身开关', () {
    test('setAnnounceEnabled 只关发送口', () {
      final service = DiscoveryService(
        self: () => AnnouncePayload(
          version: 1,
          fingerprint: 'ab' * 32,
          name: 'n',
          model: 'm',
          host: '1.1.1.1',
          port: 5244,
        ),
      );
      expect(service.announceEnabled, isTrue);
      service.setAnnounceEnabled(false);
      expect(service.announceEnabled, isFalse);
      service.dispose();
    });
  });
}
