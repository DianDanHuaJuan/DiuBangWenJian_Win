/// 对端运行时遥测（仅内存；WS peer.status 更新）。
class PeerRuntime {
  const PeerRuntime({
    this.batteryPercent,
    this.isCharging,
    this.memTotalBytes,
    this.memAvailBytes,
    this.storageTotalBytes,
    this.storageAvailBytes,
    this.externalPresent,
    this.externalTotalBytes,
    this.externalAvailBytes,
    this.updatedAtMs,
  });

  final int? batteryPercent;
  final bool? isCharging;
  final int? memTotalBytes;
  final int? memAvailBytes;
  final int? storageTotalBytes;
  final int? storageAvailBytes;
  final bool? externalPresent;
  final int? externalTotalBytes;
  final int? externalAvailBytes;
  final int? updatedAtMs;

  static const empty = PeerRuntime();

  PeerRuntime merge(PeerRuntime patch) => PeerRuntime(
        batteryPercent: patch.batteryPercent ?? batteryPercent,
        isCharging: patch.isCharging ?? isCharging,
        memTotalBytes: patch.memTotalBytes ?? memTotalBytes,
        memAvailBytes: patch.memAvailBytes ?? memAvailBytes,
        storageTotalBytes: patch.storageTotalBytes ?? storageTotalBytes,
        storageAvailBytes: patch.storageAvailBytes ?? storageAvailBytes,
        externalPresent: patch.externalPresent ?? externalPresent,
        externalTotalBytes: patch.externalTotalBytes ?? externalTotalBytes,
        externalAvailBytes: patch.externalAvailBytes ?? externalAvailBytes,
        updatedAtMs: patch.updatedAtMs ?? updatedAtMs,
      );

  Map<String, dynamic> toJson() => {
        if (batteryPercent != null) 'batteryPercent': batteryPercent,
        if (isCharging != null) 'isCharging': isCharging,
        if (memTotalBytes != null) 'memTotalBytes': memTotalBytes,
        if (memAvailBytes != null) 'memAvailBytes': memAvailBytes,
        if (storageTotalBytes != null) 'storageTotalBytes': storageTotalBytes,
        if (storageAvailBytes != null) 'storageAvailBytes': storageAvailBytes,
        if (externalPresent != null) 'externalPresent': externalPresent,
        if (externalTotalBytes != null) 'externalTotalBytes': externalTotalBytes,
        if (externalAvailBytes != null) 'externalAvailBytes': externalAvailBytes,
      };

  factory PeerRuntime.fromJson(Map<String, dynamic>? json) {
    if (json == null || json.isEmpty) return empty;
    return PeerRuntime(
      batteryPercent: (json['batteryPercent'] as num?)?.round(),
      isCharging: json['isCharging'] as bool?,
      memTotalBytes: (json['memTotalBytes'] as num?)?.toInt(),
      memAvailBytes: (json['memAvailBytes'] as num?)?.toInt(),
      storageTotalBytes: (json['storageTotalBytes'] as num?)?.toInt(),
      storageAvailBytes: (json['storageAvailBytes'] as num?)?.toInt(),
      externalPresent: json['externalPresent'] as bool?,
      externalTotalBytes: (json['externalTotalBytes'] as num?)?.toInt(),
      externalAvailBytes: (json['externalAvailBytes'] as num?)?.toInt(),
    );
  }
}
