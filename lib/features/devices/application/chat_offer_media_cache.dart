import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../app/di/service_locator.dart';
import '../../../core/common/app_exception.dart';
import '../../../core/task/transfer_task.dart';

/// 聊天报价媒体缓存：图片/视频进缓存可预览；点「下载」再晋升公共库（见综合策略 §5）。
///
/// - 图片单文件上限 [_maxBytesPerImage]；视频 [_maxBytesPerVideo]
/// - 目录总量上限 [_maxTotalBytes]，超限按 mtime 淘汰
/// - 默认保留约 [_maxAge]
/// - 中断/失败删除未完成缓存（不做单文件续传）
class ChatOfferMediaCache {
  ChatOfferMediaCache({
    this.maxBytesPerImage = _maxBytesPerImage,
    this.maxBytesPerVideo = _maxBytesPerVideo,
    this.maxTotalBytes = _maxTotalBytes,
    this.maxAge = _maxAge,
  });

  static const _maxBytesPerImage = 100 * 1024 * 1024; // 100MB
  static const _maxBytesPerVideo = 4 * 1024 * 1024 * 1024; // 4GB
  static const _maxTotalBytes = 2 * 1024 * 1024 * 1024; // 2GB
  static const _maxAge = Duration(days: 7);

  final int maxBytesPerImage;
  final int maxBytesPerVideo;
  final int maxTotalBytes;
  final Duration maxAge;

  Future<Directory>? _dirFuture;

  Future<Directory> _dir() {
    return _dirFuture ??= () async {
      final tmp = await getTemporaryDirectory();
      final d = Directory(p.join(tmp.path, 'wenjian_chat_offer_cache'));
      if (!await d.exists()) await d.create(recursive: true);
      return d;
    }();
  }

  Future<File> fileFor(String taskId) async {
    final dir = await _dir();
    final safe = taskId.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return File(p.join(dir.path, safe));
  }

  /// 缓存中已有完整（或按 size 对齐）文件则返回路径。
  Future<String?> cachedPathIfReady(TransferTask task) async {
    final f = await fileFor(task.id);
    if (!await f.exists()) return null;
    final len = await f.length();
    if (len <= 0) return null;
    if (task.sizeBytes > 0 && len < task.sizeBytes) return null;
    return f.path;
  }

  static bool _isVideoName(String name) {
    final lower = name.toLowerCase();
    const videos = ['.mp4', '.mov', '.mkv', '.webm', '.avi', '.m4v', '.3gp'];
    return videos.any(lower.endsWith);
  }

  /// 拉取报价原件到缓存；已缓存则直接返回路径。失败删除半成品。
  Future<String> ensureOriginalCached({
    required TransferTask task,
    void Function(double progress)? onProgress,
  }) async {
    final existing = await cachedPathIfReady(task);
    if (existing != null) return existing;

    final isVideo = _isVideoName(task.fileName);
    final limit = isVideo ? maxBytesPerVideo : maxBytesPerImage;
    if (task.sizeBytes > limit) {
      throw AppException(
        code: 'too_large',
        message: isVideo ? '视频过大，请直接下载保存' : '文件较大，请直接下载',
      );
    }

    final dest = await fileFor(task.id);
    if (await dest.exists()) {
      try {
        await dest.delete();
      } catch (_) {}
    }

    try {
      final n = await serviceLocator.peerApiClient().downloadToFile(
            task.peerFingerprint,
            '/api/v1/transfer/payload',
            destFile: dest,
            query: {'id': task.id},
            onBytes: (c) {
              final total = task.sizeBytes;
              if (total <= 0) return;
              onProgress?.call((c / total).clamp(0.0, 1.0));
            },
          );
      if (n == null || n <= 0) {
        throw const AppException(code: 'download', message: '预览加载失败');
      }
      if (task.sizeBytes > 0 && n < task.sizeBytes) {
        throw const AppException(code: 'incomplete', message: '预览未传完，请重试');
      }
      await _evictIfNeeded(protectPath: dest.path);
      return dest.path;
    } catch (_) {
      try {
        if (await dest.exists()) await dest.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// 正式下载晋升后立刻删除该 task 预览原件（见缓存策略 §B）。
  Future<void> discard(String taskId) async {
    try {
      final f = await fileFor(taskId);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<void> _evictIfNeeded({String? protectPath}) async {
    final dir = await _dir();
    final cutoff =
        DateTime.now().subtract(maxAge).millisecondsSinceEpoch;
    final files = <File>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File || e.path.endsWith('.part')) continue;
      files.add(e);
    }

    final stats = <File, FileStat>{};
    for (final f in files) {
      try {
        stats[f] = await f.stat();
      } catch (_) {}
    }

    // 先按年龄删
    for (final f in List<File>.from(files)) {
      final st = stats[f];
      if (st == null) continue;
      if (st.modified.millisecondsSinceEpoch >= cutoff) continue;
      if (protectPath != null && p.equals(f.path, protectPath)) continue;
      try {
        await f.delete();
        files.remove(f);
        stats.remove(f);
      } catch (_) {}
    }

    var total = 0;
    for (final st in stats.values) {
      total += st.size;
    }
    if (total <= maxTotalBytes) return;

    final ordered = stats.entries.toList()
      ..sort(
        (a, b) => a.value.modified.compareTo(b.value.modified),
      );
    for (final e in ordered) {
      if (total <= maxTotalBytes) break;
      if (protectPath != null && p.equals(e.key.path, protectPath)) {
        continue;
      }
      try {
        await e.key.delete();
        total -= e.value.size;
      } catch (_) {}
    }
  }
}
