/// 扫描循环是否继续（[shouldCancel] 为 true 时停止）。
bool mediaScanShouldContinue({bool Function()? shouldCancel}) {
  if (shouldCancel == null) return true;
  return !shouldCancel();
}

/// 本地选取结果模型（与平台选择器解耦）。
class LocalMediaScanProgress {
  const LocalMediaScanProgress({
    required this.scannedAssets,
    required this.totalAssets,
    required this.discoveredItems,
    required this.unavailableCount,
  });

  final int scannedAssets;
  final int totalAssets;
  final int discoveredItems;
  final int unavailableCount;
}

class LocalMediaPickResult {
  final List<PickedLocalMediaItem> items;
  final int unavailableCount;

  const LocalMediaPickResult({required this.items, this.unavailableCount = 0});
}

class PickedLocalMediaItem {
  final String id;
  final String localPath;
  final String displayName;
  final int size;
  final String? mimeType;
  final DateTime? createdAt;
  final DateTime? modifiedAt;
  final int? durationSeconds;

  const PickedLocalMediaItem({
    required this.id,
    required this.localPath,
    required this.displayName,
    required this.size,
    this.mimeType,
    this.createdAt,
    this.modifiedAt,
    this.durationSeconds,
  });
}
