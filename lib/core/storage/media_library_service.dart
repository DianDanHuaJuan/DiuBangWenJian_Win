import 'dart:io';
import 'package:flutter/foundation.dart';

import 'app_paths.dart';
import 'media_library_models.dart';
import 'media_library_source.dart';

export 'media_library_models.dart';

/// 本机媒体墙门面（对应 NAS `rootId=library`）：缓存 + 平台数据源。
class MediaLibraryService {
  MediaLibraryService({
    MediaLibrarySource? source,
    Future<Directory?> Function()? resolveScanRoot,
    this.onBeforeDelete,
  }) : _source = source ??
            MediaLibrarySource.create(resolveScanRoot: resolveScanRoot);

  static const rootId = MediaLibraryIds.rootId;
  static const rootDisplayName = MediaLibraryIds.rootDisplayName;

  final MediaLibrarySource _source;

  /// 删原图前清理 grid/preview（由 DI 注入）。
  final Future<void> Function(MediaLibraryAsset asset)? onBeforeDelete;

  List<MediaLibraryAsset>? _cache;
  Map<String, MediaLibraryAsset>? _byRelativePath;
  DateTime? _cacheAt;
  static const _ttl = Duration(seconds: 30);

  void invalidateCache() {
    _cache = null;
    _byRelativePath = null;
    _cacheAt = null;
  }

  void _setCache(List<MediaLibraryAsset> list) {
    _cache = list;
    _cacheAt = DateTime.now();
    final map = <String, MediaLibraryAsset>{};
    void put(String? key, MediaLibraryAsset asset) {
      final k = key?.trim() ?? '';
      if (k.isEmpty) return;
      map.putIfAbsent(k, () => asset);
    }

    for (final a in list) {
      for (final key in AppPaths.lookupKeys(a.relativePath)) {
        put(key, a);
      }
      put(a.id, a);
      put(AppPaths.portable(a.id), a);
      put(a.displayName, a);
      final abs = a.absolutePath?.trim();
      if (abs != null && abs.isNotEmpty) {
        for (final key in AppPaths.lookupKeys(abs)) {
          put(key, a);
        }
      }
    }
    _byRelativePath = map;
  }

  Future<List<MediaLibraryAsset>> listAll({bool forceRefresh = false}) async {
    if (!forceRefresh &&
        _cache != null &&
        _cacheAt != null &&
        DateTime.now().difference(_cacheAt!) < _ttl) {
      return _cache!;
    }
    if (kIsWeb) {
      _setCache(const []);
      return _cache!;
    }
    try {
      final merged = await _source.listAll();
      _setCache(merged);
      return merged;
    } catch (_) {
      _setCache(const []);
      return _cache!;
    }
  }

  Future<List<MediaLibraryAsset>> listFiltered({
    String path = '',
    bool forceRefresh = false,
  }) async {
    final all = await listAll(forceRefresh: forceRefresh);
    final filter = path.trim().toLowerCase();
    if (filter.isEmpty) return all;
    return all.where((a) => a.mediaKind == filter).toList(growable: false);
  }

  Future<MediaLibraryPage> listPage({
    String path = '',
    int offset = 0,
    int limit = 120,
    bool forceRefresh = false,
  }) async {
    final all = await listFiltered(path: path, forceRefresh: forceRefresh);
    final total = all.length;
    final start = offset.clamp(0, total);
    final end = (start + limit.clamp(1, 500)).clamp(0, total);
    return MediaLibraryPage(
      items: all.sublist(start, end),
      total: total,
      offset: start,
      limit: limit,
      hasMore: end < total,
    );
  }

  Future<MediaLibraryAsset?> findByRelativePath(String relativePath) async {
    await listAll();
    final map = _byRelativePath;
    if (map == null) return null;
    final raw = relativePath.trim();
    if (raw.isEmpty) return null;
    for (final key in AppPaths.lookupKeys(raw)) {
      final hit = map[key];
      if (hit != null) return hit;
    }
    // 兼容旧客户端把绝对路径当 relativePath 传来。
    final needle = AppPaths.portable(raw).toLowerCase();
    for (final entry in map.entries) {
      if (AppPaths.portable(entry.key).toLowerCase() == needle) {
        return entry.value;
      }
      final abs = entry.value.absolutePath;
      if (abs != null && AppPaths.equals(abs, raw)) return entry.value;
    }
    return null;
  }

  Future<Uint8List?> readBytes(
    MediaLibraryAsset asset, {
    int? rangeStart,
    int? rangeEnd,
  }) =>
      _source.readBytes(asset, rangeStart: rangeStart, rangeEnd: rangeEnd);

  Future<Uint8List?> thumbnailFor(
    MediaLibraryAsset asset, {
    int maxPx = 256,
  }) =>
      _source.thumbnailFor(asset, maxPx: maxPx);

  Future<bool> deleteAsset(MediaLibraryAsset asset) async {
    try {
      await onBeforeDelete?.call(asset);
    } catch (_) {}
    final ok = await _source.deleteAsset(asset);
    if (ok) invalidateCache();
    return ok;
  }

  Future<bool> deleteByRelativePath(String relativePath) async {
    final asset = await findByRelativePath(relativePath);
    if (asset == null) return false;
    return deleteAsset(asset);
  }

  Future<File?> materializeTemp(
    MediaLibraryAsset asset,
    Directory tempDir,
  ) async {
    final path = asset.absolutePath;
    if (path != null && path.isNotEmpty) {
      final file = File(path);
      if (await file.exists()) return file;
    }
    final bytes = await readBytes(asset);
    if (bytes == null || bytes.isEmpty) return null;
    final dest = File(
      AppPaths.native(
        AppPaths.joinPortable(
          AppPaths.portable(tempDir.path),
          'lib_${asset.id}_${asset.displayName}',
        ),
      ),
    );
    await dest.writeAsBytes(bytes, flush: true);
    return dest;
  }
}
