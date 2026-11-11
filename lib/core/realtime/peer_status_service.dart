import 'dart:async';

import '../identity/device_identity_service.dart';
import '../identity/peer_repository.dart';
import '../storage/local_system_stats.dart';
import 'local_status_snapshot.dart';
import 'peer_runtime.dart';
import 'peer_runtime_store.dart';
import 'realtime_connection_registry.dart';
import 'realtime_event.dart';
import 'realtime_session_service.dart';

/// 业务 WS 上的 peer.status 推送 / 接收 / get（决策文档 §5）。
class PeerStatusService {
  PeerStatusService({
    required this.runtimeStore,
    required this.hubRegistry,
    required RealtimeSessionService Function() session,
    required this.identityService,
    required this.statsSource,
    required Future<PeerRepository> Function() peerRepository,
    this.onPeerStaticUpdated,
    this.publishInterval = const Duration(seconds: 5),
  })  : _session = session,
        _peerRepository = peerRepository;

  final PeerRuntimeStore runtimeStore;
  final RealtimeConnectionRegistry hubRegistry;
  final RealtimeSessionService Function() _session;
  final DeviceIdentityService identityService;
  final LocalSystemStatsSource statsSource;
  final Future<PeerRepository> Function() _peerRepository;
  final Future<void> Function()? onPeerStaticUpdated;
  final Duration publishInterval;

  RealtimeSessionService get session => _session();

  Timer? _timer;
  StreamSubscription<RealtimeEvent>? _sessionSub;
  PeerRuntime? _lastPushed;
  DateTime? _lastPeriodicAt;
  final Set<String> _firstFrameSent = {};
  bool _tickBusy = false;

  void start() {
    _sessionSub?.cancel();
    _sessionSub = session.events.listen((event) {
      final fp = session.connectedPeer;
      if (fp == null) return;
      unawaited(handleInbound(fp, event));
    });
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    unawaited(_sessionSub?.cancel() ?? Future.value());
    _sessionSub = null;
    _firstFrameSent.clear();
    _lastPushed = null;
    _lastPeriodicAt = null;
  }

  /// 入站或出站 WS 建立后调用。
  void onPeerConnected(String peerFingerprint) {
    unawaited(_sendStatus(to: peerFingerprint, includeStatic: true));
    _ensureTimer();
  }

  /// WS 断开：清空该对端 Runtime。
  void onPeerDisconnected(String peerFingerprint) {
    runtimeStore.clear(peerFingerprint);
    _firstFrameSent.remove(peerFingerprint);
    if (!_hasAnyConnection) {
      _timer?.cancel();
      _timer = null;
      _lastPushed = null;
      _lastPeriodicAt = null;
    }
  }

  Future<void> handleInbound(String peerFingerprint, RealtimeEvent event) async {
    switch (event.type) {
      case RealtimeEventType.peerStatus:
        await _applyRemoteStatus(peerFingerprint, event.payload);
        return;
      case RealtimeEventType.peerStatusGet:
        await _sendStatus(
          to: peerFingerprint,
          includeStatic: await _peerNeedsStatic(peerFingerprint),
        );
        return;
      default:
        return;
    }
  }

  /// 展开卡片 / 下拉刷新：向已连接对端发 get。
  Future<void> requestStatus(String peerFingerprint) async {
    if (!_isConnectedTo(peerFingerprint)) return;
    final event = RealtimeEvent.create(
      type: RealtimeEventType.peerStatusGet,
      payload: const {'want': 'runtime'},
    );
    _sendRaw(peerFingerprint, event);
  }

  /// 概览下拉：对所有已连接对端 get。
  Future<void> requestStatusFromConnectedPeers() async {
    final fps = <String>{
      ...hubRegistry.connectedFingerprints,
      if (session.connectedPeer != null) session.connectedPeer!,
    };
    for (final fp in fps) {
      await requestStatus(fp);
    }
  }

  Future<void> _applyRemoteStatus(
    String peerFingerprint,
    Map<String, dynamic> payload,
  ) async {
    final staticMap = payload['static'];
    if (staticMap is Map) {
      final brand = '${staticMap['brand'] ?? ''}'.trim();
      final model = '${staticMap['model'] ?? ''}'.trim();
      final emoji = '${staticMap['emoji'] ?? ''}'.trim();
      var changed = false;
      try {
        final repo = await _peerRepository();
        if (brand.isNotEmpty) {
          changed = await repo.fillBrandIfEmpty(peerFingerprint, brand) ||
              changed;
        }
        if (model.isNotEmpty) {
          changed = await repo.fillModelIfEmpty(peerFingerprint, model) ||
              changed;
        }
        if (emoji.isNotEmpty) {
          changed =
              await repo.updateEmoji(peerFingerprint, emoji) || changed;
        }
      } catch (_) {}
      if (changed) {
        await onPeerStaticUpdated?.call();
      }
    }
    final runtimeMap = payload['runtime'];
    if (runtimeMap is Map) {
      final runtime = PeerRuntime.fromJson(
        Map<String, dynamic>.from(runtimeMap),
      ).merge(
        PeerRuntime(
          updatedAtMs: (payload['updatedAtMs'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch,
        ),
      );
      runtimeStore.apply(peerFingerprint, runtime);
    }
  }

  Future<void> _tick() async {
    if (_tickBusy) return;
    if (!_hasAnyConnection) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _tickBusy = true;
    try {
      final snap = await _readSnapshot();
      final now = DateTime.now();
      final duePeriodic = _lastPeriodicAt == null ||
          now.difference(_lastPeriodicAt!) >= publishInterval;
      final significant = _isSignificantChange(snap.runtime);
      if (duePeriodic || significant) {
        await _broadcastRuntime(snap);
        if (duePeriodic) _lastPeriodicAt = now;
      }
    } finally {
      _tickBusy = false;
    }
  }

  Future<void> _sendStatus({
    required String to,
    required bool includeStatic,
  }) async {
    final snap = await _readSnapshot();
    final selfFp = identityService.cachedIdentity?.fingerprint ?? '';
    if (selfFp.isEmpty) return;
    final event = RealtimeEvent.create(
      type: RealtimeEventType.peerStatus,
      payload: snap.toStatusPayload(
        selfFingerprint: selfFp,
        includeStatic: includeStatic || !_firstFrameSent.contains(to),
      ),
    );
    if (_sendRaw(to, event)) {
      _firstFrameSent.add(to);
      _lastPushed = snap.runtime;
    }
  }

  Future<void> _broadcastRuntime(LocalStatusSnapshot snap) async {
    final selfFp = identityService.cachedIdentity?.fingerprint ?? '';
    if (selfFp.isEmpty) return;
    final event = RealtimeEvent.create(
      type: RealtimeEventType.peerStatus,
      payload: snap.toStatusPayload(
        selfFingerprint: selfFp,
        includeStatic: false,
      ),
    );
    var any = false;
    for (final fp in hubRegistry.connectedFingerprints) {
      if (_sendRaw(fp, event)) any = true;
    }
    final out = session.connectedPeer;
    if (out != null && _sendRaw(out, event)) any = true;
    if (any) _lastPushed = snap.runtime;
  }

  bool _sendRaw(String peerFingerprint, RealtimeEvent event) {
    if (hubRegistry.sendTo(peerFingerprint, event)) return true;
    if (session.connectedPeer == peerFingerprint) {
      unawaited(session.send(event));
      return true;
    }
    return false;
  }

  Future<LocalStatusSnapshot> _readSnapshot() async {
    final identity = await identityService.identity;
    final stats = await statsSource.read();
    return LocalStatusSnapshot.fromParts(stats: stats, identity: identity);
  }

  Future<bool> _peerNeedsStatic(String peerFingerprint) async {
    try {
      final peer = await (await _peerRepository()).findByFingerprint(
        peerFingerprint,
      );
      return peer == null ||
          peer.brand.trim().isEmpty ||
          peer.emoji.trim().isEmpty;
    } catch (_) {
      return true;
    }
  }

  /// 本机 static（含 emoji）变更后，向已连接对端再推一帧带 static 的 status。
  Future<void> republishStaticToConnected() async {
    final fps = <String>{
      ...hubRegistry.connectedFingerprints,
      if (session.connectedPeer != null) session.connectedPeer!,
    };
    for (final fp in fps) {
      await _sendStatus(to: fp, includeStatic: true);
    }
  }

  bool _isSignificantChange(PeerRuntime next) {
    final prev = _lastPushed;
    if (prev == null) return true;
    final prevBat = prev.batteryPercent ?? 0;
    final nextBat = next.batteryPercent ?? 0;
    if ((nextBat - prevBat).abs() >= 1) return true;
    if ((prev.isCharging ?? false) != (next.isCharging ?? false)) return true;
    if ((prev.externalPresent ?? false) != (next.externalPresent ?? false)) {
      return true;
    }
    return false;
  }

  bool get _hasAnyConnection =>
      hubRegistry.hasConnections || session.isConnected;

  bool _isConnectedTo(String fp) =>
      hubRegistry.get(fp) != null || session.connectedPeer == fp;

  void _ensureTimer() {
    // 1s 轮询：满 5s 周期推；电量/充电/外置显著变化立即推。
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_tick());
    });
  }
}
