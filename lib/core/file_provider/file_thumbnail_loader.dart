import 'dart:io';
import 'dart:typed_data';

import '../../app/di/service_locator.dart';
import '../common/thumb_fetch_exception.dart';
import '../image/media_image_cache.dart';
import '../protocol/nas_api_paths.dart';
import '../protocol/thumb_image_tier.dart';
import '../storage/nas_peer_preview_cache.dart';
import 'file_entry.dart';

/// 网格缩略图门面：视口调度走 [GridThumbnailCache]，单拉复用同一 LRU。
///
/// 对端现为并行单张 HTTP（并发见 [GridThumbnailCache.maxConcurrent]）；暂不用 batch。
class FileThumbnailLoader {
  FileThumbnailLoader._();

  static final FileThumbnailLoader instance = FileThumbnailLoader._();

  static const _preloadCount = 8;
  static const _gridPx = ThumbImageTier.gridMaxPx;

  GridThumbnailCache get cache => GridThumbnailCache.instance;

  Uint8List? peek(FileEntry entry, {required bool isSelf, String? peerFingerprint}) {
    final key = GridThumbnailCache.keyFor(
      isSelf: isSelf,
      peerFingerprint: peerFingerprint,
      entry: _keyOf(entry),
      maxPx: _gridPx,
    );
    return cache.peek(key);
  }

  Stream<void> watch(
    FileEntry entry, {
    required bool isSelf,
    String? peerFingerprint,
  }) {
    final key = GridThumbnailCache.keyFor(
      isSelf: isSelf,
      peerFingerprint: peerFingerprint,
      entry: _keyOf(entry),
      maxPx: _gridPx,
    );
    return cache.updates.where((k) => k == key).map((_) {});
  }

  /// 视口请求：仅切片窗口建 key；[allowPreload]/[scrollBias] 对齐原客户端。
  void requestVisibleRange({
    required List<FileEntry> entries,
    required int firstIndex,
    required int lastIndex,
    required bool isSelf,
    String? peerFingerprint,
    bool allowPreload = true,
    int scrollBias = 0,
  }) {
    if (entries.isEmpty) return;
    final preload = allowPreload ? _preloadCount : 0;
    final start = (firstIndex - preload).clamp(0, entries.length - 1);
    final end = (lastIndex + preload).clamp(0, entries.length - 1);
    if (start > end) return;

    final slice = <FileEntryKey>[];
    for (var i = start; i <= end; i++) {
      slice.add(_keyOf(entries[i]));
    }

    cache.requestVisible(
      entries: slice,
      windowStartIndex: start,
      firstIndex: firstIndex,
      lastIndex: lastIndex,
      isSelf: isSelf,
      peerFingerprint: peerFingerprint,
      allowPreload: allowPreload,
      scrollBias: scrollBias,
      maxPx: _gridPx,
      fetcher: (k) => _fetchKey(
        k,
        isSelf: isSelf,
        peerFingerprint: peerFingerprint,
      ),
    );
  }

  Future<Uint8List?> load({
    required FileEntry entry,
    required bool isSelf,
    String? peerFingerprint,
  }) async {
    if (entry.isDirectory || (!entry.isImage && !entry.isVideo)) {
      return null;
    }
    final key = GridThumbnailCache.keyFor(
      isSelf: isSelf,
      peerFingerprint: peerFingerprint,
      entry: _keyOf(entry),
      maxPx: _gridPx,
    );
    final hit = cache.peek(key);
    if (hit != null) return hit;
    final bytes = await _fetchKey(
      _keyOf(entry),
      isSelf: isSelf,
      peerFingerprint: peerFingerprint,
    );
    if (bytes != null && bytes.isNotEmpty) {
      cache.put(key, bytes);
    }
    return bytes;
  }

  FileEntryKey _keyOf(FileEntry e) => FileEntryKey(
        rootId: e.rootId,
        relativePath: e.relativePath,
        isMedia: e.isImage || e.isVideo,
        absolutePath: e.absolutePath,
        contentUri: e.contentUri,
      );

  Future<Uint8List?> _fetchKey(
    FileEntryKey entry, {
    required bool isSelf,
    String? peerFingerprint,
  }) async {
    try {
      if (isSelf) {
        if (entry.rootId == 'library' ||
            (entry.contentUri != null && entry.contentUri!.isNotEmpty)) {
          final lib = serviceLocator.mediaLibraryService();
          final asset = await lib.findByRelativePath(entry.relativePath);
          if (asset != null) {
            return lib.thumbnailFor(asset, maxPx: _gridPx);
          }
        }
        final path = entry.absolutePath;
        if (path == null || path.isEmpty) return null;
        final file = File(path);
        if (!await file.exists()) return null;
        return serviceLocator.thumbnailService().thumbnailFor(file, maxPx: _gridPx);
      }
      final fp = peerFingerprint;
      if (fp == null || fp.isEmpty) return null;
      final bytes = await serviceLocator.peerApiClient().downloadBytes(
            fp,
            NasApiPaths.thumbnail,
            query: {
              NasApiQuery.rootId: entry.rootId,
              NasApiQuery.name: entry.relativePath,
              NasApiQuery.type: ThumbImageTier.grid.wireName,
            },
          );
      if (bytes == null || bytes.isEmpty) return null;
      return Uint8List.fromList(bytes);
    } on ThumbFetchException {
      rethrow;
    } catch (_) {
      return null;
    }
  }
}

/// 预览级加载：客户端磁盘缓存 → 本机/对端 preview 档（非原文件）。
class PreviewImageLoader {
  PreviewImageLoader._();
  static final PreviewImageLoader instance = PreviewImageLoader._();

  static const _previewPx = ThumbImageTier.previewMaxPx;

  final PreviewDiskCache disk = PreviewDiskCache();

  Future<Uint8List?> loadPreview({
    required FileEntry entry,
    required bool isSelf,
    String? peerFingerprint,
  }) async {
    final cacheKey = PreviewDiskCache.previewKey(
      rootId: entry.rootId,
      relativePath: entry.relativePath,
      maxPx: _previewPx,
      peerFingerprint: isSelf ? null : peerFingerprint,
    );
    final cached = await disk.getBytes(cacheKey);
    if (cached != null && cached.isNotEmpty) return cached;

    Uint8List? bytes;
    try {
      if (isSelf) {
        if (entry.rootId == 'library' ||
            (entry.contentUri != null && entry.contentUri!.isNotEmpty)) {
          final lib = serviceLocator.mediaLibraryService();
          final asset = await lib.findByRelativePath(entry.relativePath);
          if (asset != null) {
            bytes = await lib.thumbnailFor(asset, maxPx: _previewPx);
          }
        }
        if (bytes == null) {
          final path = entry.absolutePath;
          if (path != null && path.isNotEmpty) {
            final file = File(path);
            if (await file.exists()) {
              bytes = await serviceLocator
                  .thumbnailService()
                  .thumbnailFor(file, maxPx: _previewPx);
            }
          }
        }
      } else {
        final fp = peerFingerprint;
        if (fp == null || fp.isEmpty) return null;
        final raw = await serviceLocator.peerApiClient().downloadBytes(
              fp,
              NasApiPaths.thumbnail,
              query: {
                NasApiQuery.rootId: entry.rootId,
                NasApiQuery.name: entry.relativePath,
                NasApiQuery.type: ThumbImageTier.preview.wireName,
              },
            );
        if (raw != null && raw.isNotEmpty) {
          bytes = Uint8List.fromList(raw);
        }
      }
    } catch (_) {
      return null;
    }
    if (bytes != null && bytes.isNotEmpty) {
      final file = await disk.putBytes(cacheKey, bytes);
      final fp = peerFingerprint?.trim();
      if (!isSelf && fp != null && fp.isNotEmpty && file != null) {
        await NasPeerPreviewCache.instance.track(
          peerFingerprint: fp,
          absolutePath: file.path,
        );
      }
    }
    return bytes;
  }

  Future<void> prefetchNeighbors({
    required List<FileEntry> mediaFiles,
    required int centerIndex,
    required bool isSelf,
    String? peerFingerprint,
    int radius = 2,
  }) async {
    if (mediaFiles.isEmpty) return;
    final start = (centerIndex - radius).clamp(0, mediaFiles.length - 1);
    final end = (centerIndex + radius).clamp(0, mediaFiles.length - 1);
    final futures = <Future<void>>[];
    for (var i = start; i <= end; i++) {
      final e = mediaFiles[i];
      if (!e.isImage) continue;
      futures.add(
        loadPreview(
          entry: e,
          isSelf: isSelf,
          peerFingerprint: peerFingerprint,
        ),
      );
    }
    await Future.wait(futures);
  }
}
