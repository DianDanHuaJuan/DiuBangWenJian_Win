import 'dart:async';
import 'dart:io';

import '../common/key_value_store.dart';
import 'app_paths.dart';
import 'media_library_service.dart';
import 'storage_root_store.dart';
import 'thumb_diag.dart';
import 'thumb_pipeline.dart';
import 'thumb_warmup_scheduler.dart';

/// 日扫：孤儿清理 + grid 漏缺入队；打开 APP 勿直接重活。
class ThumbDailyScan {
  ThumbDailyScan({
    required KeyValueStore kv,
    required StorageRootStore roots,
    required MediaLibraryService mediaLibrary,
    required ThumbPipeline pipeline,
    required ThumbWarmupScheduler warmup,
    this.minInterval = const Duration(hours: 24),
    this.chunkSize = 40,
  })  : _kv = kv,
        _roots = roots,
        _mediaLibrary = mediaLibrary,
        _pipeline = pipeline,
        _warmup = warmup;

  static const lastScanKey = 'thumb.daily_scan_at_ms';

  final KeyValueStore _kv;
  final StorageRootStore _roots;
  final MediaLibraryService _mediaLibrary;
  final ThumbPipeline _pipeline;
  final ThumbWarmupScheduler _warmup;
  final Duration minInterval;
  final int chunkSize;

  var _running = false;

  /// [force] 用于换根；否则距上次不足 [minInterval] 则跳过。
  Future<void> maybeRun({bool force = false}) async {
    if (_running) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _kv.getInt(lastScanKey) ?? 0;
    if (!force && last > 0 && now - last < minInterval.inMilliseconds) {
      // 日扫未到：若已有待办仍可 kick（一般为空）。
      _warmup.kick();
      return;
    }
    await run(force: force);
  }

  Future<void> run({bool force = false}) async {
    if (_running) return;
    _running = true;
    final sw = Stopwatch()..start();
    var orphans = 0;
    var enqueued = 0;
    var checked = 0;
    try {
      ThumbDiag.important(
        'daily_scan_begin',
        details: {'force': force},
      );

      // 1) 孤儿：索引有、源不在 → 删文件+索引。
      final root = await _roots.ensureCurrent();
      final rootPath = AppPaths.portable(root.uriOrPath);
      final entries = await _pipeline.index.entries();
      for (var i = 0; i < entries.length; i++) {
        final e = entries[i];
        checked++;
        final abs = AppPaths.native(
          AppPaths.joinPortable(rootPath, e.name),
        );
        // library 相对路径相对共享根；若源不存在则孤儿。
        final src = File(abs);
        final alive = await src.exists();
        if (!alive) {
          await _pipeline.cache.delete(tier: e.tier, key: e.key);
          await _pipeline.index.removeKey(e.key);
          orphans++;
        }
        if (i > 0 && i % chunkSize == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }

      // 2) grid 漏缺 → 入预热队列（仅 grid）。
      final assets = await _mediaLibrary.listAll(forceRefresh: true);
      for (var i = 0; i < assets.length; i++) {
        final a = assets[i];
        if (a.mediaKind != 'image' && a.mediaKind != 'video') continue;
        final path = a.absolutePath?.trim() ?? '';
        if (path.isEmpty) continue;
        final file = File(path);
        if (!await file.exists()) continue;
        final added = await _warmup.enqueueGrid(
          file: file,
          rootId: MediaLibraryService.rootId,
          name: a.relativePath,
          mtimeMs: a.modifiedAtMs,
          sizeBytes: a.sizeBytes,
        );
        if (added) enqueued++;
        if (i > 0 && i % chunkSize == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }

      await _kv.setInt(lastScanKey, DateTime.now().millisecondsSinceEpoch);
      sw.stop();
      ThumbDiag.important(
        'daily_scan_end',
        details: {
          'orphans': orphans,
          'enqueued': enqueued,
          'indexChecked': checked,
          'assets': assets.length,
          'pendingWarmup': _warmup.pendingCount,
          'ms': sw.elapsedMilliseconds,
        },
      );
      _warmup.kick();
    } catch (e) {
      ThumbDiag.important('daily_scan_error', details: {'error': '$e'});
    } finally {
      _running = false;
    }
  }
}
