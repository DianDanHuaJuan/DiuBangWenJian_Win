import '../identity/device_identity_service.dart';
import '../storage/local_system_stats.dart';
import 'peer_runtime.dart';

/// 本机 status 快照（采集 → wire runtime + 可选 static）。
class LocalStatusSnapshot {
  const LocalStatusSnapshot({
    required this.runtime,
    required this.brand,
    required this.model,
    required this.emoji,
    required this.updatedAtMs,
  });

  final PeerRuntime runtime;
  final String brand;
  final String model;
  final String emoji;
  final int updatedAtMs;

  factory LocalStatusSnapshot.fromParts({
    required LocalSystemStats stats,
    required DeviceIdentity identity,
    int? nowMs,
  }) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final runtime = PeerRuntime(
      batteryPercent: stats.batteryPercent,
      isCharging: stats.isCharging,
      memTotalBytes: stats.memTotalBytes,
      memAvailBytes: stats.memAvailBytes,
      storageTotalBytes: stats.storageTotalBytes,
      storageAvailBytes: stats.storageAvailBytes,
      externalPresent: stats.hasExternal,
      externalTotalBytes: stats.externalTotalBytes,
      externalAvailBytes: stats.externalAvailBytes,
      updatedAtMs: now,
    );
    return LocalStatusSnapshot(
      runtime: runtime,
      brand: identity.brand,
      model: identity.model,
      emoji: identity.emoji,
      updatedAtMs: now,
    );
  }

  Map<String, dynamic> toStatusPayload({
    required String selfFingerprint,
    required bool includeStatic,
  }) {
    return {
      'fp': selfFingerprint,
      if (includeStatic)
        'static': {
          'brand': brand,
          'model': model,
          if (emoji.isNotEmpty) 'emoji': emoji,
        },
      'runtime': runtime.toJson(),
      'updatedAtMs': updatedAtMs,
    };
  }
}
