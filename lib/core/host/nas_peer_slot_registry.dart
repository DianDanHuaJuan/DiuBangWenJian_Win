import 'dart:math' as math;

/// NAS 主机侧「同时在线已配对设备」槽位。
///
/// 按 fingerprint 占 1 槽；同设备多请求不叠加。满员拒绝新设备。
class NasPeerSlotRegistry {
  NasPeerSlotRegistry({
    int maxConcurrentPeers = defaultMaxConcurrentPeers,
    this.idle = defaultIdle,
  }) : _limit = _clampLimit(maxConcurrentPeers);

  static const int minConcurrentPeers = 4;
  static const int maxConcurrentPeersCap = 8;
  static const int defaultMaxConcurrentPeers = 6;
  static const Duration defaultIdle = Duration(minutes: 4);

  final Duration idle;
  int _limit;
  final Map<String, DateTime> _lastTouch = {};

  int get limit => _limit;

  int get used {
    _reapIdle();
    return _lastTouch.length;
  }

  set limit(int value) {
    _limit = _clampLimit(value);
    _reapIdle();
    while (_lastTouch.length > _limit) {
      _evictOldest();
    }
  }

  static int _clampLimit(int value) =>
      math.max(minConcurrentPeers, math.min(maxConcurrentPeersCap, value));

  bool contains(String fingerprint) {
    final fp = fingerprint.trim();
    if (fp.isEmpty) return false;
    _reapIdle();
    return _lastTouch.containsKey(fp);
  }

  /// 已在槽内则 touch；否则尝试占槽。成功 true。
  bool tryAcquire(String fingerprint) {
    final fp = fingerprint.trim();
    if (fp.isEmpty) return false;
    _reapIdle();
    if (_lastTouch.containsKey(fp)) {
      _lastTouch[fp] = DateTime.now();
      return true;
    }
    if (_lastTouch.length >= _limit) return false;
    _lastTouch[fp] = DateTime.now();
    return true;
  }

  void touch(String fingerprint) {
    final fp = fingerprint.trim();
    if (fp.isEmpty) return;
    if (!_lastTouch.containsKey(fp)) return;
    _lastTouch[fp] = DateTime.now();
  }

  void release(String fingerprint) {
    _lastTouch.remove(fingerprint.trim());
  }

  void clearAll() => _lastTouch.clear();

  void _reapIdle() {
    if (_lastTouch.isEmpty) return;
    final cutoff = DateTime.now().subtract(idle);
    final stale = [
      for (final e in _lastTouch.entries)
        if (e.value.isBefore(cutoff)) e.key,
    ];
    for (final k in stale) {
      _lastTouch.remove(k);
    }
  }

  void _evictOldest() {
    if (_lastTouch.isEmpty) return;
    String? oldest;
    DateTime? t;
    for (final e in _lastTouch.entries) {
      if (t == null || e.value.isBefore(t)) {
        oldest = e.key;
        t = e.value;
      }
    }
    if (oldest != null) _lastTouch.remove(oldest);
  }
}
