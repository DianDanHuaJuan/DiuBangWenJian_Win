import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'media_library_models.dart';
import 'media_library_source.dart';

export 'media_library_models.dart';

/// 本机媒体墙门面（对应 NAS `rootId=library`）：缓存 + 平台数据源。
class MediaLibraryService {
  MediaLibraryService({
    MediaLibrarySource? source,
    Future<Directory?> Function()? resolveScanRoot,
  }) : _source = source ??
            MediaLibrarySource.create(resolveScanRoot: resolveScanRoot);

  static const rootId = MediaLibraryIds.rootId;
  static const rootDisplayName = MediaLibraryIds.rootDisplayName;

  final MediaLibrarySource _source;

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
    for (final a in list) {
      map[a.relativePath] = a;
      if (a.displayName.isNotEmpty) map.putIfAbsent(a.displayName, () => a);
      if (a.id.isNotEmpty) map.putIfAbsent(a.id, () => a);
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
    return _byRelativePath?[relativePath];
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
      '${tempDir.path}${Platform.pathSeparator}lib_${asset.id}_${asset.displayName}',
    );
    await dest.writeAsBytes(bytes, flush: true);
    return dest;
  }
}
