import 'dart:async';

import '../common/app_logger.dart';
import '../identity/peer.dart';
import '../network/peer_address.dart';
import 'discovery_service.dart';

/// 在线设备视图（UDP announce 续命；已配对超时可走 HTTPS ping 门闸）。
class OnlinePeer {
  const OnlinePeer({
    required this.fingerprint,
    required this.name,
    required this.model,
    required this.address,
    required this.lastSeenMillis,
    this.brand = '',
    this.emoji = '',
    this.nasService = false,
  });

  final String fingerprint;
  final String name;
  final String brand;
  final String model;
  final String emoji;

  /// host:port（announce 携带；仅作拨号地址线索）。
  final String address;

  final int lastSeenMillis;

  /// 对端是否开启 NAS 服务（announce / info caps）。
  final bool nasService;

  OnlinePeer copyWithSeen({
    required int millis,
    String? address,
    bool? nasService,
  }) =>
      OnlinePeer(
        fingerprint: fingerprint,
        name: name,
        brand: brand,
        model: model,
        emoji: emoji,
        address: address ?? this.address,
        lastSeenMillis: millis,
        nasService: nasService ?? this.nasService,
      );
}

/// 在线状态聚合：UDP announce 续命；与 peers 表求交得到已配对在线。
class PeerRegistry {
  PeerRegistry({
    required this.pairedPeers,
    required Future<List<Peer>> Function() loadPeers,
    this.nowMillis,
  }) : _loadPeers = loadPeers;

  final Future<List<Peer>> Function() _loadPeers;
  final List<Peer> Function() pairedPeers;
  final int Function()? nowMillis;

  final Map<String, OnlinePeer> _online = {};
  /// fingerprint → 冷静期结束时刻（毫秒）；期内超时不再 ping，直接标灰。
  final Map<String, int> _pingFailUntilMillis = {};
  final Set<String> _pingInFlight = {};
  final _onlineController =
      StreamController<List<OnlinePeer>>.broadcast();
  final _nearbyController =
      StreamController<List<OnlinePeer>>.broadcast();

  Stream<List<OnlinePeer>> get onlinePairedStream => _onlineController.stream;
  List<OnlinePeer> get onlinePaired => _snapshots(
        pairedPeers().map((p) => p.fingerprint).toSet(),
      );

  Stream<List<OnlinePeer>> get nearbyStream => _nearbyController.stream;
  List<OnlinePeer> get nearby => _snapshots(
        pairedPeers().map((p) => p.fingerprint).toSet(),
        excludePaired: false,
      )
          .where((o) => !pairedPeers()
              .map((p) => p.fingerprint)
              .toSet()
              .contains(o.fingerprint))
          .toList();

  /// 是否已在在线视图（近期 UDP announce）。
  bool isOnline(String fingerprint) => _online.containsKey(fingerprint);

  void onAnnounce(AnnouncePayload payload) {
    final address = PeerAddress.format(payload.host, payload.port) ??
        '${payload.host}:${payload.port}';
    final now = _now();
    final existing = _online[payload.fingerprint];
    _pingFailUntilMillis.remove(payload.fingerprint);
    final next = OnlinePeer(
      fingerprint: payload.fingerprint,
      name: payload.name,
      brand: payload.brand,
      model: payload.model,
      emoji: payload.emoji,
      address: address,
      lastSeenMillis: now,
      nasService: payload.nas,
    );
    _online[payload.fingerprint] = next;
    final meaningful = existing == null ||
        existing.address != next.address ||
        existing.name != next.name ||
        existing.brand != next.brand ||
        existing.model != next.model ||
        existing.emoji != next.emoji ||
        existing.nasService != next.nasService;
    if (meaningful) {
      if (existing == null) {
        AppLogger.log(
          'presence online (first announce)',
          scope: 'presence',
          details: {
            'fp': _shortFp(payload.fingerprint),
            'address': address,
            'nas': payload.nas,
            'onlineCount': _online.length,
          },
        );
      } else {
        AppLogger.logVerbose(
          'presence updated',
          scope: 'presence',
          details: {
            'fp': _shortFp(payload.fingerprint),
            'address': address,
            'nas': payload.nas,
            'onlineCount': _online.length,
          },
        );
      }
      _emit();
    }
  }

  /// 本地注入在线（配对刚完成等）；续命仍只靠后续 announce。
  void markReachable({
    required String fingerprint,
    required String name,
    required String model,
    required String address,
    String brand = '',
    String emoji = '',
    bool? nasService,
  }) {
    final existing = _online[fingerprint];
    _online[fingerprint] = OnlinePeer(
      fingerprint: fingerprint,
      name: name,
      brand: brand.isNotEmpty ? brand : (existing?.brand ?? ''),
      model: model,
      emoji: emoji.isNotEmpty ? emoji : (existing?.emoji ?? ''),
      address: address,
      lastSeenMillis: _now(),
      nasService: nasService ?? existing?.nasService ?? false,
    );

    _emit();
  }

  /// 由 /api/v1/info caps 回写 NAS 能力（不改地址）。
  void markNasService(String fingerprint, bool enabled) {
    final existing = _online[fingerprint];
    if (existing == null || existing.nasService == enabled) return;
    _online[fingerprint] = existing.copyWithSeen(
      millis: existing.lastSeenMillis,
      nasService: enabled,
    );
    _emit();
  }

  /// 吊销 / 指纹被替代时立刻从在线表拿掉（不经过 10s 超时）。
  void markUnreachable(String fingerprint) {
    if (_online.remove(fingerprint) != null) {
      AppLogger.log(
        'presence markUnreachable',
        scope: 'presence',
        details: {
          'fp': _shortFp(fingerprint),
          'onlineCount': _online.length,
        },
      );
      _emit();
    }
  }

  /// NAS FGS → UI：用权威快照整表替换在线视图（含已配对与 nearby）。
  void replacePresenceFromSnapshot(List<OnlinePeer> peers) {
    _online
      ..clear()
      ..addEntries(peers.map((p) => MapEntry(p.fingerprint, p)));
    _emit();
  }

  /// 序列化当前在线表（FGS 推 presence_snapshot 用）。
  List<Map<String, Object?>> serializeOnlinePeers(Iterable<OnlinePeer> peers) =>
      [
        for (final p in peers)
          {
            'fingerprint': p.fingerprint,
            'name': p.name,
            'brand': p.brand,
            'model': p.model,
            'emoji': p.emoji,
            'address': p.address,
            'lastSeenMillis': p.lastSeenMillis,
            'nasService': p.nasService,
          },
      ];

  /// 扫过期：未配对 / 无地址 / 无门闸回调 → 直接摘除；
  /// 已配对且有地址 → 短 ping，通则续命，不通再灰（冷静期内跳过 ping）。
  Future<void> sweepExpired({
    Future<bool> Function(OnlinePeer peer)? verifyPairedReachable,
  }) async {
    final now = _now();
    final pairedFps = pairedPeers().map((p) => p.fingerprint).toSet();
    final expired = _online.entries
        .where(
          (e) => now - e.value.lastSeenMillis >= offlineTimeout.inMilliseconds,
        )
        .map((e) => e.value)
        .toList();
    if (expired.isEmpty) return;

    final toRemove = <String>[];
    final toVerify = <OnlinePeer>[];
    final removeReasons = <String, String>{};

    for (final peer in expired) {
      final fp = peer.fingerprint;
      final paired = pairedFps.contains(fp);
      final hasAddress = PeerAddress.tryParse(peer.address) != null ||
          _pairedAddress(fp) != null;
      final staleSec =
          ((now - peer.lastSeenMillis) / 1000).round();

      if (!paired ||
          !hasAddress ||
          verifyPairedReachable == null) {
        toRemove.add(fp);
        removeReasons[fp] = !paired
            ? 'unpaired_stale_${staleSec}s'
            : (!hasAddress
                ? 'no_address_stale_${staleSec}s'
                : 'no_ping_gate_stale_${staleSec}s');
        continue;
      }

      final coolUntil = _pingFailUntilMillis[fp] ?? 0;
      if (now < coolUntil) {
        toRemove.add(fp);
        removeReasons[fp] = 'ping_cooldown_stale_${staleSec}s';
        continue;
      }

      if (_pingInFlight.contains(fp)) continue;
      toVerify.add(peer);
    }

    if (toRemove.isNotEmpty) {
      AppLogger.log(
        'presence sweep remove',
        scope: 'presence',
        details: {
          'count': toRemove.length,
          'peers': [
            for (final fp in toRemove)
              {
                'fp': _shortFp(fp),
                'reason': removeReasons[fp] ?? 'stale',
              },
          ],
        },
      );
      for (final fp in toRemove) {
        _online.remove(fp);
        _pingInFlight.remove(fp);
      }
      _emit();
    }

    if (verifyPairedReachable == null || toVerify.isEmpty) return;

    final slots =
        presencePingGateMaxConcurrent - _pingInFlight.length;
    if (slots <= 0) return;

    await Future.wait([
      for (final peer in toVerify.take(slots))
        _runPingGate(peer, verifyPairedReachable),
    ]);
  }

  Future<void> _runPingGate(
    OnlinePeer peer,
    Future<bool> Function(OnlinePeer peer) verify,
  ) async {
    final fp = peer.fingerprint;
    _pingInFlight.add(fp);
    AppLogger.logVerbose(
      'presence ping gate start',
      scope: 'presence',
      details: {
        'fp': _shortFp(fp),
        'address': peer.address,
        'staleMs': _now() - peer.lastSeenMillis,
      },
    );

    var ok = false;
    try {
      ok = await verify(peer);
    } catch (e) {
      ok = false;
      AppLogger.log(
        'presence ping gate threw',
        scope: 'presence',
        error: e,
        details: {'fp': _shortFp(fp)},
      );
    } finally {
      _pingInFlight.remove(fp);
    }

    final cur = _online[fp];
    if (cur == null) return;

    if (ok) {
      _pingFailUntilMillis.remove(fp);
      _online[fp] = cur.copyWithSeen(millis: _now());
      AppLogger.logVerbose(
        'presence ping gate ok → renew',
        scope: 'presence',
        details: {'fp': _shortFp(fp), 'address': peer.address},
      );
      return;
    }

    _pingFailUntilMillis[fp] =
        _now() + presencePingFailCooldown.inMilliseconds;
    // 门闸期间若已有新 announce，勿误摘。
    if (_now() - cur.lastSeenMillis < offlineTimeout.inMilliseconds) {
      AppLogger.log(
        'presence ping fail but announce revived',
        scope: 'presence',
        details: {'fp': _shortFp(fp)},
      );
      return;
    }
    _online.remove(fp);
    AppLogger.log(
      'presence ping fail → offline',
      scope: 'presence',
      details: {
        'fp': _shortFp(fp),
        'address': peer.address,
        'cooldownSec': presencePingFailCooldown.inSeconds,
        'onlineCount': _online.length,
      },
    );
    _emit();
  }

  static String _shortFp(String fp) =>
      fp.length > 12 ? '${fp.substring(0, 12)}…' : fp;

  String? _pairedAddress(String fingerprint) {
    for (final p in pairedPeers()) {
      if (p.fingerprint != fingerprint) continue;
      if (PeerAddress.tryParse(p.lastSeenAddress) != null) {
        return p.lastSeenAddress;
      }
    }
    return null;
  }

  Future<void> reloadPaired() async {
    await _loadPeers();
    _emit();
  }

  void _emit() {
    _onlineController.add(onlinePaired);
    _nearbyController.add(nearby);
  }

  List<OnlinePeer> _snapshots(
    Set<String> pairedFps, {
    bool excludePaired = true,
  }) {
    final list = _online.values
        .where(
          (o) => excludePaired ? pairedFps.contains(o.fingerprint) : true,
        )
        .toList()
      ..sort((a, b) => b.lastSeenMillis.compareTo(a.lastSeenMillis));
    return list;
  }

  int _now() =>
      nowMillis?.call() ?? DateTime.now().millisecondsSinceEpoch;

  void dispose() {
    _onlineController.close();
    _nearbyController.close();
  }
}
