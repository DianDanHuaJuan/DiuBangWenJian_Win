import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../../../core/protocol/thumb_image_tier.dart';

/// 服务端 grid 缩略图落盘：统一目录、100MB 上限、算过才写、不预热。
///
/// singleflight：`async` + `try/finally` 移除 inflight。
class GridThumbDiskCache {
  GridThumbDiskCache({
    this.maxBytes = 100 << 20,
    this.algoVersion = 'v1-grid-192',
    this.generateTimeout = const Duration(seconds: 8),
  });

  final int maxBytes;
  final String algoVersion;

  /// 现算超时：超时当 miss，保证 HTTP handler 能返回。
  final Duration generateTimeout;

  Future<Directory>? _dirFuture;
  final Map<String, Future<Uint8List?>> _inflight = {};

  Future<Directory> _ensureDir() {
    return _dirFuture ??= () async {
      final support = await getApplicationSupportDirectory();
      final d = Directory(p.join(support.path, '.thumbs', 'grid'));
      if (!await d.exists()) await d.create(recursive: true);
      return d;
    }();
  }

  String cacheKey({
    required String rootId,
    required String name,
    required int mtimeMs,
    required int sizeBytes,
  }) {
    final raw =
        '$algoVersion|grid|${ThumbImageTier.gridMaxPx}|$rootId|$name|$mtimeMs|$sizeBytes';
    return sha256.convert(utf8.encode(raw)).toString();
  }

  Future<File> _fileFor(String key) async {
    final dir = await _ensureDir();
    return File(p.join(dir.path, '$key.jpg'));
  }

  Future<Uint8List?> read(String key) async {
    try {
      final f = await _fileFor(key);
      if (!await f.exists()) return null;
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// 命中缓存或执行 [generate]；同键 singleflight。
  Future<Uint8List?> getOrPut(
    String key,
    Future<Uint8List?> Function() generate,
  ) {
    final existing = _inflight[key];
    if (existing != null) return existing;

    late final Future<Uint8List?> future;
    future = () async {
      try {
        final hit = await read(key);
        if (hit != null) return hit;
        final bytes = await generate().timeout(
          generateTimeout,
          onTimeout: () => null,
        );
        if (bytes == null || bytes.isEmpty) return null;
        await _write(key, bytes);
        return bytes;
      } finally {
        if (identical(_inflight[key], future)) {
          _inflight.remove(key);
        }
      }
    }();
    _inflight[key] = future;
    return future;
  }

  Future<void> _write(String key, List<int> bytes) async {
    try {
      final f = await _fileFor(key);
      final part =
          File('${f.path}.${DateTime.now().microsecondsSinceEpoch}.part');
      await part.writeAsBytes(bytes, flush: true);
      if (await f.exists()) await f.delete();
      await part.rename(f.path);
      await _trim();
    } catch (_) {}
  }

  Future<void> _trim() async {
    final dir = await _ensureDir();
    final files = <File>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is File && e.path.endsWith('.jpg')) files.add(e);
    }
    final stats = <File, FileStat>{};
    var total = 0;
    for (final f in files) {
      try {
        final st = await f.stat();
        stats[f] = st;
        total += st.size;
      } catch (_) {}
    }
    if (total <= maxBytes) return;
    final ordered = stats.keys.toList()
      ..sort((a, b) => stats[a]!.modified.compareTo(stats[b]!.modified));
    for (final f in ordered) {
      if (total <= maxBytes) break;
      try {
        final size = stats[f]?.size ?? 0;
        await f.delete();
        total -= size;
      } catch (_) {}
    }
  }
}
