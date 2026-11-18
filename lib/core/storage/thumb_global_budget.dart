/// 跨 grid/preview 闸的全局生成槽位，避免两闸叠满打爆机械盘。
class ThumbGlobalBudget {
  ThumbGlobalBudget({int? maxConcurrent})
      : maxConcurrent = maxConcurrent ?? defaultMaxConcurrent;

  /// 定案：全局同时生成 ≡ 1（与 remote/warmup 一致）。
  static const defaultMaxConcurrent = 1;

  final int maxConcurrent;

  var _running = 0;
  final List<void Function()> _listeners = [];

  int get running => _running;
  bool get hasCapacity => _running < maxConcurrent;

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  bool tryAcquire() {
    if (_running >= maxConcurrent) return false;
    _running++;
    return true;
  }

  void release() {
    if (_running > 0) _running--;
    final copy = List<void Function()>.from(_listeners);
    for (final l in copy) {
      l();
    }
  }
}
