import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../common/app_logger.dart';
import '../protocol/thumb_image_tier.dart';
import 'app_paths.dart';
import 'storage_root_store.dart';
import 'thumb_diag.dart';

/// 共享根下 `.thumbs/{grid|preview}` 落盘（Windows NAS 主机）。
///
/// 不做容量/数量 trim（定案：相对原图可忽略）。
class ThumbCacheStore {
  ThumbCacheStore({
    required StorageRootStore rootStore,
    this.algoVersion = 'win-v1-aspect',
  }) : _roots = rootStore;

  final StorageRootStore _roots;
  final String algoVersion;

  String cacheKey({
    required ThumbImageTier tier,
    required String rootId,
    required String name,
    required int mtimeMs,
    required int sizeBytes,
  }) {
    final raw =
        '$algoVersion|${tier.wireName}|${tier.maxPx}|$rootId|$name|$mtimeMs|$sizeBytes';
    return sha256.convert(utf8.encode(raw)).toString();
  }

  Future<Directory> _tierDir(ThumbImageTier tier) async {
    final root = await _roots.ensureCurrent();
    final dir = Directory(
      AppPaths.native(
        AppPaths.joinPortable(
          AppPaths.portable(root.uriOrPath),
          '.thumbs',
          tier.wireName,
        ),
      ),
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _fileFor(ThumbImageTier tier, String key) async {
    final dir = await _tierDir(tier);
    return File(p.join(dir.path, '$key.jpg'));
  }

  Future<bool> exists({
    required ThumbImageTier tier,
    required String key,
  }) async {
    try {
      return await (await _fileFor(tier, key)).exists();
    } catch (_) {
      return false;
    }
  }

  Future<Uint8List?> read({
    required ThumbImageTier tier,
    required String key,
  }) async {
    try {
      final f = await _fileFor(tier, key);
      if (!await f.exists()) return null;
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<void> write({
    required ThumbImageTier tier,
    required String key,
    required List<int> bytes,
  }) async {
    if (bytes.isEmpty) return;
    try {
      final sw = Stopwatch()..start();
      final f = await _fileFor(tier, key);
      final part =
          File('${f.path}.${DateTime.now().microsecondsSinceEpoch}.part');
      await part.writeAsBytes(bytes, flush: true);
      if (await f.exists()) await f.delete();
      await part.rename(f.path);
      sw.stop();
      ThumbDiag.markPhase(
        'cache_write',
        details: {
          'tier': tier.wireName,
          'bytes': bytes.length,
          'ms': sw.elapsedMilliseconds,
        },
      );
    } catch (e) {
      AppLogger.log(
        'thumb cache write fail',
        scope: 'thumb_diag',
        error: e,
        details: {'tier': tier.wireName, 'key': key},
      );
    }
  }

  Future<bool> delete({
    required ThumbImageTier tier,
    required String key,
  }) async {
    try {
      final f = await _fileFor(tier, key);
      if (!await f.exists()) return false;
      await f.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 路径是否落在 `.thumbs` 下（媒体扫描应跳过）。
  static bool isUnderThumbsDir(String absolutePath) {
    final portable = AppPaths.portable(absolutePath).toLowerCase();
    return portable.contains('/.thumbs/') || portable.endsWith('/.thumbs');
  }
}
