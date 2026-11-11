import 'package:flutter/foundation.dart';

/// 聊天未读（星号）：有 inbound 文字/报价即标记，进该 peer 聊天页清除。
///
/// **热总线**：仅内存；跨 Engine 靠 [onUnreadDelta] IPC，不写 SharedReplica。
/// 见 docs/FGS与UI双引擎数据同步策略.md §4。
class ChatUnreadStore extends ChangeNotifier {
  ChatUnreadStore({this.onUnreadDelta});

  /// 本侧用户操作后通知对侧（`mark` / `clear`）；applyRemote 时勿设。
  void Function(String fingerprint, String op)? onUnreadDelta;

  final Set<String> _unread = {};
  String? _viewingPeer;
  bool _applyingRemote = false;

  Set<String> get unreadPeers => Set.unmodifiable(_unread);

  bool hasUnread(String peerFingerprint) =>
      _unread.contains(peerFingerprint.trim());

  /// 聊天页可见时调用；同 peer 入站不点星，并清除已有未读。
  void setViewingPeer(String? peerFingerprint) {
    final fp = peerFingerprint?.trim();
    _viewingPeer = (fp == null || fp.isEmpty) ? null : fp;
    if (_viewingPeer != null) {
      clear(_viewingPeer!);
    }
  }

  /// 离开某聊天页时调用；若已切到另一 peer 的聊天则不动。
  void clearViewingIf(String peerFingerprint) {
    final fp = peerFingerprint.trim();
    if (_viewingPeer == fp) {
      _viewingPeer = null;
    }
  }

  void mark(String peerFingerprint) {
    final fp = peerFingerprint.trim();
    if (fp.isEmpty) return;
    if (_viewingPeer == fp) return;
    if (!_unread.add(fp)) return;
    notifyListeners();
    _emit(fp, 'mark');
  }

  void clear(String peerFingerprint) {
    final fp = peerFingerprint.trim();
    if (fp.isEmpty) return;
    if (!_unread.remove(fp)) return;
    notifyListeners();
    _emit(fp, 'clear');
  }

  /// 对侧热 IPC：合并进本机 Set，不回声。
  void applyRemote({required String fingerprint, required String op}) {
    final fp = fingerprint.trim();
    if (fp.isEmpty) return;
    _applyingRemote = true;
    try {
      if (op == 'clear') {
        if (_unread.remove(fp)) notifyListeners();
        return;
      }
      if (op == 'mark') {
        if (_viewingPeer == fp) return;
        if (_unread.add(fp)) notifyListeners();
      }
    } finally {
      _applyingRemote = false;
    }
  }

  void _emit(String fp, String op) {
    if (_applyingRemote) return;
    onUnreadDelta?.call(fp, op);
  }
}
