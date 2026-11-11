import 'package:flutter/foundation.dart';

import 'peer_runtime.dart';

/// 对端 Runtime 内存表（按 fingerprint；断线清空）。
class PeerRuntimeStore {
  final Map<String, PeerRuntime> _byFp = {};
  final Map<String, ValueNotifier<PeerRuntime?>> _notifiers = {};

  PeerRuntime? get(String fingerprint) => _byFp[fingerprint];

  /// 分区 UI 订阅；断线 clear 后值为 null。
  ValueListenable<PeerRuntime?> listenable(String fingerprint) {
    return _notifiers.putIfAbsent(
      fingerprint,
      () => ValueNotifier<PeerRuntime?>(_byFp[fingerprint]),
    );
  }

  void apply(String fingerprint, PeerRuntime patch) {
    final merged = (_byFp[fingerprint] ?? PeerRuntime.empty).merge(
      PeerRuntime(
        batteryPercent: patch.batteryPercent,
        isCharging: patch.isCharging,
        memTotalBytes: patch.memTotalBytes,
        memAvailBytes: patch.memAvailBytes,
        storageTotalBytes: patch.storageTotalBytes,
        storageAvailBytes: patch.storageAvailBytes,
        externalPresent: patch.externalPresent,
        externalTotalBytes: patch.externalTotalBytes,
        externalAvailBytes: patch.externalAvailBytes,
        updatedAtMs:
            patch.updatedAtMs ?? DateTime.now().millisecondsSinceEpoch,
      ),
    );
    _byFp[fingerprint] = merged;
    final n = _notifiers[fingerprint];
    if (n != null) {
      n.value = merged;
    } else {
      _notifiers[fingerprint] = ValueNotifier(merged);
    }
  }

  void clear(String fingerprint) {
    _byFp.remove(fingerprint);
    final n = _notifiers[fingerprint];
    if (n != null) n.value = null;
  }

  void clearAll() {
    _byFp.clear();
    for (final n in _notifiers.values) {
      n.value = null;
    }
  }

  void dispose() {
    for (final n in _notifiers.values) {
      n.dispose();
    }
    _notifiers.clear();
    _byFp.clear();
  }
}
