import 'windows_system_stats.dart';
import 'storage_volumes.dart';

/// 单个盘符容量。
class VolumeDiskStats {
  const VolumeDiskStats({
    required this.letter,
    required this.path,
    required this.label,
    required this.totalBytes,
    required this.availBytes,
  });

  final String letter;
  final String path;
  final String label;
  final int totalBytes;
  final int availBytes;

  int get usedBytes => (totalBytes - availBytes).clamp(0, totalBytes);

  double get usedRatio => totalBytes > 0 ? usedBytes / totalBytes : 0;
}

/// 本机内存 / 存储快照（概览环形图）。
class LocalSystemStats {
  const LocalSystemStats({
    required this.memTotalBytes,
    required this.memAvailBytes,
    required this.storageTotalBytes,
    required this.storageAvailBytes,
    this.volumes = const [],
    this.externalTotalBytes = 0,
    this.externalAvailBytes = 0,
    this.externalLabel = '',
    this.batteryPercent = 0,
    this.isCharging = false,
  });

  final int memTotalBytes;
  final int memAvailBytes;

  /// 系统盘（对端 status 协议仍用单字段）。
  final int storageTotalBytes;
  final int storageAvailBytes;

  /// 本机各盘符（C/D/…），概览可全部展示。
  final List<VolumeDiskStats> volumes;

  /// 兼容旧字段：无单独「外置」语义时为 0。
  final int externalTotalBytes;
  final int externalAvailBytes;
  final String externalLabel;

  final int batteryPercent;
  final bool isCharging;

  bool get hasExternal => externalTotalBytes > 0;

  int get memUsedBytes =>
      (memTotalBytes - memAvailBytes).clamp(0, memTotalBytes);

  int get storageUsedBytes =>
      (storageTotalBytes - storageAvailBytes).clamp(0, storageTotalBytes);

  int get externalUsedBytes =>
      (externalTotalBytes - externalAvailBytes).clamp(0, externalTotalBytes);

  double get memUsedRatio =>
      memTotalBytes > 0 ? memUsedBytes / memTotalBytes : 0;

  double get storageUsedRatio =>
      storageTotalBytes > 0 ? storageUsedBytes / storageTotalBytes : 0;

  double get externalUsedRatio =>
      externalTotalBytes > 0 ? externalUsedBytes / externalTotalBytes : 0;

  static const empty = LocalSystemStats(
    memTotalBytes: 0,
    memAvailBytes: 0,
    storageTotalBytes: 0,
    storageAvailBytes: 0,
    batteryPercent: 0,
    isCharging: false,
  );
}

/// Windows Win32 采集；失败返回 [LocalSystemStats.empty]。
class LocalSystemStatsSource {
  LocalSystemStatsSource({StorageVolumes? volumes})
      : _volumes = volumes ?? StorageVolumes();

  final StorageVolumes _volumes;

  Future<LocalSystemStats> read() async {
    try {
      return await WindowsSystemStats.read(volumes: _volumes);
    } catch (_) {
      return LocalSystemStats.empty;
    }
  }
}
