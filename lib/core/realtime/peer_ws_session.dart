import 'dart:async';

import '../storage/nas_peer_preview_cache.dart';
import 'realtime_session_service.dart';

/// 对端业务会话门面：聊天 / NAS 文件页共用一条出站 WS。
///
/// - [enter]：进入某 peer 的 chat/files（换 peer 会先断旧连）
/// - [leaveToDevicesList]：回到设备列表时由导航入口显式调用
/// - 切概览/设置 Tab **不断开**
///
/// 不要在启动时监听 GoRouter.state（空 matches 会 Bad state: No element）。
/// 回列表必须走显式 leave（见 docs/architecture_notes.md）。
/// NAS 预览磁盘缓存随会话结束清理（见 docs/对端NAS预览缓存策略.md）。
class PeerWsSession {
  PeerWsSession({
    required RealtimeSessionService Function() session,
    required Future<void> Function() ensureHostRunning,
    NasPeerPreviewCache? previewCache,
  })  : _session = session,
        _ensureHostRunning = ensureHostRunning,
        _previewCache = previewCache ?? NasPeerPreviewCache.instance;

  final RealtimeSessionService Function() _session;
  final Future<void> Function() _ensureHostRunning;
  final NasPeerPreviewCache _previewCache;

  String? _activePeerFp;

  String? get activePeerFingerprint => _activePeerFp;

  /// 进入对端会话；同 peer 续连，其它 peer 先断再连。
  Future<bool> enter(String peerFingerprint) async {
    final fp = peerFingerprint.trim();
    if (fp.isEmpty) return false;

    await _ensureHostRunning();
    final session = _session();

    if (_activePeerFp == fp &&
        session.isConnected &&
        session.connectedPeer == fp) {
      return session.connect(fp);
    }

    if (_activePeerFp != null && _activePeerFp != fp) {
      final prev = _activePeerFp!;
      if (session.isConnected) {
        await session.disconnect();
      }
      unawaited(_previewCache.endPeerSession(prev));
    }

    _activePeerFp = fp;
    final ok = await session.connect(fp);
    if (!ok && _activePeerFp == fp) {
      _activePeerFp = null;
    }
    return ok;
  }

  /// 用户退回设备列表：结束当前对端会话。
  Future<void> leaveToDevicesList() async {
    final session = _session();
    final leaving = _activePeerFp;
    final had = leaving != null || session.isConnected;
    _activePeerFp = null;
    if (!had) return;
    await session.disconnect();
    if (leaving != null) {
      await _previewCache.endPeerSession(leaving);
    }
  }
}
