import 'package:flutter/foundation.dart';

/// 聊天未读（星号）：有 inbound 文字/报价即标记，进该 peer 聊天页清除。
///
/// Windows 单进程：仅内存，无跨 Engine IPC。
class ChatUnreadStore extends ChangeNotifier {
  final Set<String> _unread = {};
  String? _viewingPeer;

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
  }

  void clear(String peerFingerprint) {
    final fp = peerFingerprint.trim();
    if (fp.isEmpty) return;
    if (!_unread.remove(fp)) return;
    notifyListeners();
  }
}
