/// 本机挂载存储卷（内置 / SD / OTG / Windows 盘符）。
class StorageVolumeInfo {
  const StorageVolumeInfo({
    required this.path,
    required this.description,
    required this.isPrimary,
    required this.isRemovable,
    required this.writable,
    this.state = '',
    this.rootId = '',
  });

  final String path;
  final String description;
  final bool isPrimary;
  final bool isRemovable;
  final bool writable;
  final String state;

  /// 服务端下发的浏览 rootId（如 `extvol:C:/`）；空则客户端自行拼接。
  final String rootId;

  bool get isExternal => isRemovable && !isPrimary;

  factory StorageVolumeInfo.fromMap(Map<dynamic, dynamic> map) {
    return StorageVolumeInfo(
      path: (map['path'] as String?) ?? '',
      description: (map['description'] as String?) ?? '',
      isPrimary: map['isPrimary'] == true,
      isRemovable: map['isRemovable'] == true,
      writable: map['writable'] != false,
      state: (map['state'] as String?) ?? '',
      rootId: (map['rootId'] as String?) ?? '',
    );
  }
}
