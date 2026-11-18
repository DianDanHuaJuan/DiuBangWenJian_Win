import 'storage_volume_info.dart';
import 'storage_volume_lister.dart';

export 'storage_volume_info.dart';

/// 本机卷列表门面（实现按平台注入）。
///
/// **进程级**短 TTL 缓存 + 单飞，避免浏览墙时对端轮询 `/storage/volumes`
/// 导致反复枚举盘符与密日志（各处 `StorageVolumes()` 新实例也共享缓存）。
class StorageVolumes {
  StorageVolumes({
    StorageVolumeLister? lister,
    this.cacheTtl = defaultCacheTtl,
  }) : _lister = lister ?? StorageVolumeLister.create();

  static const defaultCacheTtl = Duration(seconds: 8);

  final StorageVolumeLister _lister;
  final Duration cacheTtl;

  static List<StorageVolumeInfo>? _sharedCached;
  static DateTime? _sharedCachedAt;
  static Future<List<StorageVolumeInfo>>? _sharedInflight;

  Future<List<StorageVolumeInfo>> list({bool force = false}) async {
    final ttl = cacheTtl;
    if (!force &&
        _sharedCached != null &&
        _sharedCachedAt != null &&
        DateTime.now().difference(_sharedCachedAt!) < ttl) {
      return _sharedCached!;
    }
    final existing = _sharedInflight;
    if (existing != null) return existing;

    final future = () async {
      try {
        final list = await _lister.list();
        _sharedCached = List<StorageVolumeInfo>.unmodifiable(list);
        _sharedCachedAt = DateTime.now();
        return _sharedCached!;
      } finally {
        _sharedInflight = null;
      }
    }();
    _sharedInflight = future;
    return future;
  }

  /// 插拔盘符或用户主动刷新时调用。
  static void invalidateShared() {
    _sharedCached = null;
    _sharedCachedAt = null;
  }

  void invalidate() => invalidateShared();
}
