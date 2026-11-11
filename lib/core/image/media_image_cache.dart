import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../common/thumb_fetch_exception.dart';
import '../protocol/thumb_image_tier.dart';

/// L2 预览级磁盘缓存：按文件数上限淘汰（docs/缩略图与预览图缓存方案.md）。
class PreviewDiskCache {
  PreviewDiskCache({this.maxEntries = 100});

  /// 最多保留的预览文件数。
  final int maxEntries;

  Future<Directory>? _dirFuture;

  Future<Directory> _ensureDir() {
    return _dirFuture ??= () async {
      final tmp = await getTemporaryDirectory();
      final d = Directory(p.join(tmp.path, 'wenjian_preview_cache'));
      if (!await d.exists()) await d.create(recursive: true);
      return d;
    }();
  }

  String _fileName(String cacheKey) {
    final digest = cacheKey.hashCode.toUnsigned(32).toRadixString(16);
    final safe = cacheKey.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final clipped = safe.length > 48 ? safe.substring(0, 48) : safe;
    return '${clipped}_$digest.jpg';
  }

  Future<File> _fileFor(String cacheKey) async {
    final dir = await _ensureDir();
    return File(p.join(dir.path, _fileName(cacheKey)));
  }

  Future<File?> getFile(String cacheKey) async {
    try {
      final f = await _fileFor(cacheKey);
      if (await f.exists() && await f.length() > 0) return f;
    } catch (_) {}
    return null;
  }

  Future<Uint8List?> getBytes(String cacheKey) async {
    final f = await getFile(cacheKey);
    if (f == null) return null;
    try {
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<File?> putBytes(String cacheKey, List<int> bytes) async {
    if (bytes.isEmpty) return null;
    try {
      final f = await _fileFor(cacheKey);
      final part = File('${f.path}.part');
      await part.writeAsBytes(bytes, flush: true);
      if (await f.exists()) await f.delete();
      await part.rename(f.path);
      await _evictIfNeeded();
      return f;
    } catch (_) {
      return null;
    }
  }

  Future<void> _evictIfNeeded() async {
    final dir = await _ensureDir();
    final files = <File>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is File && !e.path.endsWith('.part')) files.add(e);
    }
    if (files.length <= maxEntries) return;
    final stats = <File, FileStat>{};
    for (final f in files) {
      try {
        stats[f] = await f.stat();
      } catch (_) {}
    }
    final ordered = stats.keys.toList()
      ..sort(
        (a, b) => stats[a]!.modified.compareTo(stats[b]!.modified),
      );
    var keep = files.length;
    for (final f in ordered) {
      if (keep <= maxEntries) break;
      try {
        await f.delete();
        keep--;
      } catch (_) {}
    }
  }

  /// 预览缓存键：与网格 LRU 命名空间分离。
  static String previewKey({
    required String rootId,
    required String relativePath,
    int maxPx = ThumbImageTier.previewMaxPx,
    String? peerFingerprint,
  }) {
    final peer = (peerFingerprint == null || peerFingerprint.isEmpty)
        ? 'local'
        : peerFingerprint;
    return 'preview|$peer|$rootId|$relativePath|$maxPx';
  }
}

/// L0 网格缩略图：视口队列 + 内存 LRU + 有限并发（对齐 NASClient ThumbnailRepository）。
///
/// 更新通过 [updates] 按 key 广播，禁止用整表 [notifyListeners] 驱动网格。
class GridThumbnailCache extends ChangeNotifier {
  GridThumbnailCache._();

  static final GridThumbnailCache instance = GridThumbnailCache._();

  static const maxEntries = 200;
  /// 远端网格并发（对齐 656456c 前的泵上限 / 流畅性方案 ≤3）。
  static const maxConcurrent = 3;
  /// 硬失败（404 等）负缓存。
  static const failTtl = Duration(seconds: 60);
  /// 可重试失败（超时/网络）短负缓存，随后自动再拉。
  static const softFailTtl = Duration(seconds: 3);
  static const requestDebounce = Duration(milliseconds: 24);

  final LinkedHashMap<String, Uint8List> _cache = LinkedHashMap();
  final Map<String, Future<Uint8List?>> _inflight = {};
  final Map<String, DateTime> _failedUntil = {};
  final List<_ThumbJob> _queue = [];
  final Set<String> _queuedKeys = {};
  var _running = 0;

  final StreamController<String> _updates =
      StreamController<String>.broadcast();

  /// 单 key 到位通知（格子级刷新）。
  Stream<String> get updates => _updates.stream;

  /// 只读命中，**不**调整 LRU（供 build / peek）。
  Uint8List? peek(String key) => _cache[key];

  /// 命中并挪到 LRU 尾（显式触摸时用）。
  Uint8List? getCached(String key) {
    final v = _cache[key];
    if (v == null) return null;
    _cache.remove(key);
    _cache[key] = v;
    return v;
  }

  void put(String key, Uint8List bytes) {
    if (bytes.isEmpty) return;
    _cache.remove(key);
    _cache[key] = bytes;
    while (_cache.length > maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    _failedUntil.remove(key);
    if (!_updates.isClosed) _updates.add(key);
  }

  static String keyFor({
    required bool isSelf,
    String? peerFingerprint,
    required FileEntryKey entry,
    int maxPx = 192,
  }) =>
      '${isSelf ? 'local' : peerFingerprint}|${entry.rootId}|${entry.relativePath}|$maxPx';

  Timer? _debounce;
  Timer? _failWakeTimer;
  DateTime? _failWakeAt;
  _VisibleRequest? _pending;
  /// 最近一次视口，供 failTtl/softFail 到期后自动再调度。
  _VisibleRequest? _lastVisible;

  /// 视口驱动：debounce 后入队；滚动中可反复调用。
  ///
  /// [entries] 应为已切片的窗口（含可选 preload），[windowStartIndex] 为该切片
  /// 在完整目录中的起始下标；[firstIndex]/[lastIndex] 为全局可见区。
  void requestVisible({
    required List<FileEntryKey> entries,
    required int windowStartIndex,
    required int firstIndex,
    required int lastIndex,
    required bool isSelf,
    String? peerFingerprint,
    required Future<Uint8List?> Function(FileEntryKey entry) fetcher,
    bool allowPreload = true,
    int scrollBias = 0,
    int maxPx = 192,
  }) {
    final req = _VisibleRequest(
      entries: entries,
      windowStartIndex: windowStartIndex,
      firstIndex: firstIndex,
      lastIndex: lastIndex,
      isSelf: isSelf,
      peerFingerprint: peerFingerprint,
      fetcher: fetcher,
      allowPreload: allowPreload,
      scrollBias: scrollBias,
      maxPx: maxPx,
    );
    _pending = req;
    _lastVisible = req;
    _debounce?.cancel();
    _debounce = Timer(requestDebounce, _applyPending);
  }

  void _scheduleFailWake(Duration delay) {
    if (_lastVisible == null) return;
    final wait = delay < const Duration(milliseconds: 200)
        ? const Duration(milliseconds: 200)
        : delay;
    final at = DateTime.now().add(wait);
    if (_failWakeAt != null &&
        _failWakeTimer != null &&
        _failWakeTimer!.isActive &&
        !_failWakeAt!.isAfter(at)) {
      // 已有更早或同等的唤醒，不推迟。
      return;
    }
    _failWakeTimer?.cancel();
    _failWakeAt = at;
    _failWakeTimer = Timer(wait, () {
      _failWakeAt = null;
      final last = _lastVisible;
      if (last == null) return;
      _pending = last;
      _applyPending();
    });
  }

  void _markFailed(String key, {required bool retryable}) {
    final ttl = retryable ? softFailTtl : failTtl;
    _failedUntil[key] = DateTime.now().add(ttl);
    _scheduleFailWake(ttl);
  }

  void _applyPending() {
    final req = _pending;
    _pending = null;
    if (req == null || req.entries.isEmpty) return;

    final desired = <String>{};
    final jobs = <_ThumbJob>[];
    var skipFailTtl = 0;
    for (var i = 0; i < req.entries.length; i++) {
      final e = req.entries[i];
      if (!e.isMedia) continue;
      final absIndex = req.windowStartIndex + i;
      final inVisible = absIndex >= req.firstIndex && absIndex <= req.lastIndex;
      if (!inVisible && !req.allowPreload) continue;

      final key = keyFor(
        isSelf: req.isSelf,
        peerFingerprint: req.peerFingerprint,
        entry: e,
        maxPx: req.maxPx,
      );
      desired.add(key);
      if (peek(key) != null) continue;
      final failAt = _failedUntil[key];
      if (failAt != null && DateTime.now().isBefore(failAt)) {
        skipFailTtl++;
        continue;
      }
      if (_inflight.containsKey(key)) continue;
      if (_queuedKeys.contains(key)) continue;

      // priority: 可见=0；preload 按滚动方向偏置
      var priority = inVisible ? 0 : 2;
      if (!inVisible && req.scrollBias != 0) {
        final ahead = req.scrollBias > 0
            ? absIndex > req.lastIndex
            : absIndex < req.firstIndex;
        priority = ahead ? 1 : 3;
      }
      jobs.add(
        _ThumbJob(
          key: key,
          entry: e,
          fetcher: req.fetcher,
          priority: priority,
          absIndex: absIndex,
        ),
      );
    }

    // 丢弃已离开窗口的排队任务（inflight 不取消，完成后若仍离屏仅占一次槽）。
    _queue.removeWhere((j) {
      final drop = !desired.contains(j.key);
      if (drop) _queuedKeys.remove(j.key);
      return drop;
    });

    jobs.sort((a, b) {
      final c = a.priority.compareTo(b.priority);
      if (c != 0) return c;
      if (req.scrollBias > 0) return a.absIndex.compareTo(b.absIndex);
      if (req.scrollBias < 0) return b.absIndex.compareTo(a.absIndex);
      return a.absIndex.compareTo(b.absIndex);
    });
    for (final j in jobs) {
      _queue.add(j);
      _queuedKeys.add(j.key);
    }
    // 当前窗口仍有项在 failTtl 内：到期后再拉一遍，避免半屏停住。
    if (skipFailTtl > 0) {
      DateTime? earliest;
      for (final key in desired) {
        final until = _failedUntil[key];
        if (until == null) continue;
        if (peek(key) != null) continue;
        if (earliest == null || until.isBefore(earliest)) earliest = until;
      }
      if (earliest != null) {
        final remain = earliest.difference(DateTime.now());
        if (remain > Duration.zero) _scheduleFailWake(remain);
      }
    }
    _pump();
  }

  void _pump() {
    while (_running < maxConcurrent && _queue.isNotEmpty) {
      final job = _queue.removeAt(0);
      _queuedKeys.remove(job.key);
      if (peek(job.key) != null) continue;
      if (_inflight.containsKey(job.key)) continue;
      _running++;
      final future = job.fetcher(job.entry).then((bytes) {
        _inflight.remove(job.key);
        _running--;
        if (bytes != null && bytes.isNotEmpty) {
          _cache[job.key] = bytes;
          while (_cache.length > maxEntries) {
            _cache.remove(_cache.keys.first);
          }
          _failedUntil.remove(job.key);
          if (!_updates.isClosed) _updates.add(job.key);
        } else {
          _markFailed(job.key, retryable: false);
        }
        _pump();
        return bytes;
      }).catchError((Object e) {
        _inflight.remove(job.key);
        _running--;
        final retryable = e is ThumbFetchException && e.retryable;
        _markFailed(job.key, retryable: retryable);
        _pump();
        return null;
      });
      _inflight[job.key] = future;
    }
  }

  void clear() {
    _debounce?.cancel();
    _failWakeTimer?.cancel();
    _failWakeAt = null;
    _pending = null;
    _lastVisible = null;
    _cache.clear();
    _queue.clear();
    _queuedKeys.clear();
    _failedUntil.clear();
    notifyListeners();
  }
}

class _VisibleRequest {
  _VisibleRequest({
    required this.entries,
    required this.windowStartIndex,
    required this.firstIndex,
    required this.lastIndex,
    required this.isSelf,
    required this.peerFingerprint,
    required this.fetcher,
    required this.allowPreload,
    required this.scrollBias,
    required this.maxPx,
  });

  final List<FileEntryKey> entries;
  final int windowStartIndex;
  final int firstIndex;
  final int lastIndex;
  final bool isSelf;
  final String? peerFingerprint;
  final Future<Uint8List?> Function(FileEntryKey entry) fetcher;
  final bool allowPreload;
  final int scrollBias;
  final int maxPx;
}

/// 轻量条目键（避免网格持有过多闭包）。
class FileEntryKey {
  const FileEntryKey({
    required this.rootId,
    required this.relativePath,
    required this.isMedia,
    this.absolutePath,
    this.contentUri,
  });

  final String rootId;
  final String relativePath;
  final bool isMedia;
  final String? absolutePath;
  final String? contentUri;
}

class _ThumbJob {
  _ThumbJob({
    required this.key,
    required this.entry,
    required this.fetcher,
    required this.priority,
    required this.absIndex,
  });

  final String key;
  final FileEntryKey entry;
  final Future<Uint8List?> Function(FileEntryKey entry) fetcher;
  final int priority;
  final int absIndex;
}
