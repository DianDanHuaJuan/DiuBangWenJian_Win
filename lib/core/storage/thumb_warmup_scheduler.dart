import 'dart:async';
import 'dart:collection';
import 'dart:io';

import '../protocol/thumb_image_tier.dart';
import 'thumb_diag.dart';
import 'thumb_generation_gate.dart';
import 'thumb_pipeline.dart';

class _WarmupItem {
  _WarmupItem({
    required this.file,
    required this.rootId,
    required this.name,
    required this.mtimeMs,
    required this.sizeBytes,
    required this.cacheKey,
  });

  final File file;
  final String rootId;
  final String name;
  final int mtimeMs;
  final int sizeBytes;
  final String cacheKey;
}

/// 仅 grid 预热：有界队列 + 完成后 200ms 涓流；无待办即停机。
class ThumbWarmupScheduler {
  ThumbWarmupScheduler({
    required ThumbPipeline pipeline,
    this.trickleDelay = const Duration(milliseconds: 200),
    this.busyPause = const Duration(milliseconds: 400),
  }) : _pipeline = pipeline;

  final ThumbPipeline _pipeline;
  final Duration trickleDelay;
  final Duration busyPause;

  final Queue<_WarmupItem> _queue = Queue();
  final Set<String> _queuedKeys = {};

  var _wanted = false;
  var _loopActive = false;
  var _epoch = 0;

  bool get isRunning => _wanted;
  int get pendingCount => _queue.length;

  void start() {
    if (_queue.isEmpty) {
      ThumbDiag.important('warmup_idle_stop', details: {'reason': 'empty'});
      return;
    }
    if (_wanted) return;
    _wanted = true;
    ThumbDiag.important(
      'warmup_start',
      details: {
        'pending': _queue.length,
        'maxRemote': _pipeline.gate.maxRemote,
        'maxWarmup': _pipeline.gate.maxWarmup,
        'globalMax': _pipeline.budget?.maxConcurrent,
      },
    );
    unawaited(_loop());
  }

  void stop() {
    if (!_wanted && _queue.isEmpty) return;
    _wanted = false;
    _epoch++;
    _pipeline.gate.clearWarmupQueue();
    _queue.clear();
    _queuedKeys.clear();
    ThumbDiag.important('warmup_stop');
  }

  void onShareRootChanged() {
    _pipeline.gate.clearWarmupQueue();
    _queue.clear();
    _queuedKeys.clear();
    unawaited(_pipeline.index.prepareRootChange());
    _epoch++;
    _wanted = false;
    ThumbDiag.important('warmup_root_changed');
  }

  /// 日扫发现缺 grid 时入队；已在队/永久失败则跳过。
  Future<bool> enqueueGrid({
    required File file,
    required String rootId,
    required String name,
    required int mtimeMs,
    required int sizeBytes,
  }) async {
    final key = _pipeline.cache.cacheKey(
      tier: ThumbImageTier.grid,
      rootId: rootId,
      name: name,
      mtimeMs: mtimeMs,
      sizeBytes: sizeBytes,
    );
    if (_queuedKeys.contains(key)) return false;
    if (_pipeline.isPermanentlyFailed(key)) return false;
    if (await _pipeline.cache.exists(tier: ThumbImageTier.grid, key: key)) {
      return false;
    }
    _queuedKeys.add(key);
    _queue.add(
      _WarmupItem(
        file: file,
        rootId: rootId,
        name: name,
        mtimeMs: mtimeMs,
        sizeBytes: sizeBytes,
        cacheKey: key,
      ),
    );
    return true;
  }

  /// 有待办则启动 worker（幂等）。
  void kick() {
    if (_queue.isEmpty) return;
    start();
  }

  Future<void> _loop() async {
    if (_loopActive) return;
    _loopActive = true;
    final epoch = _epoch;
    try {
      while (_wanted && epoch == _epoch) {
        if (_pipeline.hasRemoteDemand) {
          await Future<void>.delayed(busyPause);
          continue;
        }
        if (_queue.isEmpty) {
          _wanted = false;
          ThumbDiag.important('warmup_idle_stop', details: {'reason': 'drained'});
          return;
        }

        final item = _queue.removeFirst();
        _queuedKeys.remove(item.cacheKey);

        try {
          await _pipeline.getOrGenerate(
            file: item.file,
            tier: ThumbImageTier.grid,
            rootId: item.rootId,
            name: item.name,
            mtimeMs: item.mtimeMs,
            sizeBytes: item.sizeBytes,
            priority: ThumbGenPriority.warmup,
          );
        } catch (_) {}

        // 涓流：仅 warmup 路径。
        if (_wanted && epoch == _epoch) {
          await Future<void>.delayed(trickleDelay);
        }
      }
    } catch (e) {
      ThumbDiag.important('warmup_loop_error', details: {'error': '$e'});
    } finally {
      _loopActive = false;
      if (_wanted && epoch == _epoch && _queue.isNotEmpty) {
        unawaited(_loop());
      } else if (_queue.isEmpty) {
        _wanted = false;
      }
    }
  }
}
