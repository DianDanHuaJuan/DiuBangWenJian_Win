import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../app/di/service_locator.dart';
import '../../../core/network/peer_api_client.dart';
import '../../../core/task/transfer_task.dart';
import '../../nas/data/api/services/thumbnail_service.dart';

/// 互传图/视频气泡封面：按本地文件抽缩略图，落盘供对端 `/transfer/poster`。
class ChatOfferPoster {
  ChatOfferPoster({
    ThumbnailService? thumbnails,
    PeerApiClient? api,
    this.maxPosterFiles = 150,
  })  : _thumbs = thumbnails,
        _api = api;

  /// 未下载封面磁盘条数上限（超限按 mtime 淘汰最旧）。
  final int maxPosterFiles;

  ThumbnailService? _thumbs;
  PeerApiClient? _api;

  ThumbnailService get _thumbnailService =>
      _thumbs ??= serviceLocator.thumbnailService();

  PeerApiClient get _peerApi => _api ??= serviceLocator.peerApiClient();

  static bool isVideoFileName(String name) {
    final lower = name.toLowerCase();
    const videos = ['.mp4', '.mov', '.mkv', '.webm', '.avi', '.m4v', '.3gp'];
    return videos.any(lower.endsWith);
  }

  static bool isImageFileName(String name) {
    final lower = name.toLowerCase();
    const images = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic'];
    return images.any(lower.endsWith);
  }

  static bool isPosterFileName(String name) =>
      isVideoFileName(name) || isImageFileName(name);

  /// 兼容旧调用：Windows 无 MediaStore id。
  static bool isLikelyMediaStoreId(String? raw) => false;

  static void rememberMediaAssetId(String taskId, String? mediaAssetId) {}

  static String? rememberedMediaAssetId(String taskId) => null;

  Future<Directory> _dir() async {
    final root = await getTemporaryDirectory();
    final dir = Directory(p.join(root.path, 'chat_poster'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> posterFile(String taskId) async {
    final dir = await _dir();
    return File(p.join(dir.path, '$taskId.jpg'));
  }

  Future<String?> cachedPathIfReady(String taskId) async {
    final f = await posterFile(taskId);
    if (await f.exists() && await f.length() > 0) return f.path;
    return null;
  }

  /// 发送方：按 localPath 抽封面并缓存。
  Future<String?> ensureLocalPoster({
    required TransferTask task,
    String? mediaAssetId,
  }) async {
    if (!isPosterFileName(task.fileName)) return null;
    final existing = await cachedPathIfReady(task.id);
    if (existing != null) return existing;

    final path = task.localPath;
    if (path == null || path.isEmpty || !await File(path).exists()) {
      return null;
    }
    final bytes = await _thumbnailService.thumbnailFor(File(path), maxPx: 256);
    if (bytes == null || bytes.isEmpty) return null;

    final out = await posterFile(task.id);
    await out.writeAsBytes(bytes, flush: true);
    await _evictOverCount(protectPath: out.path);
    return out.path;
  }

  Future<void> discard(String taskId) async {
    try {
      final f = await posterFile(taskId);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<Uint8List?> thumbBytesForLocalFile(String absolutePath) async {
    if (absolutePath.isEmpty) return null;
    final file = File(absolutePath);
    if (!await file.exists()) return null;
    try {
      return await _thumbnailService.thumbnailFor(file, maxPx: 256);
    } catch (_) {
      return null;
    }
  }

  /// 接收方：拉取对端 poster；发送方异步生成时带退避重试。
  Future<String?> ensureRemotePoster(TransferTask task) async {
    if (!isPosterFileName(task.fileName)) return null;
    final existing = await cachedPathIfReady(task.id);
    if (existing != null) return existing;

    const delays = <Duration>[
      Duration.zero,
      Duration(milliseconds: 500),
      Duration(milliseconds: 1200),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ];
    final dest = await posterFile(task.id);
    for (final delay in delays) {
      if (delay > Duration.zero) {
        await Future<void>.delayed(delay);
        final ready = await cachedPathIfReady(task.id);
        if (ready != null) return ready;
      }
      final n = await _peerApi.downloadToFile(
        task.peerFingerprint,
        '/api/v1/transfer/poster',
        destFile: dest,
        query: {'id': task.id},
      );
      if (n != null && n > 0 && await dest.exists() && await dest.length() > 0) {
        await _evictOverCount(protectPath: dest.path);
        return dest.path;
      }
      try {
        if (await dest.exists()) await dest.delete();
      } catch (_) {}
    }
    return null;
  }

  Future<void> _evictOverCount({String? protectPath}) async {
    try {
      final dir = await _dir();
      final files = <File>[];
      await for (final e in dir.list(followLinks: false)) {
        if (e is File && e.path.toLowerCase().endsWith('.jpg')) {
          files.add(e);
        }
      }
      if (files.length <= maxPosterFiles) return;
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
      var count = files.length;
      for (final f in ordered) {
        if (count <= maxPosterFiles) break;
        if (protectPath != null && p.equals(f.path, protectPath)) continue;
        try {
          await f.delete();
          count--;
        } catch (_) {}
      }
    } catch (_) {}
  }
}
