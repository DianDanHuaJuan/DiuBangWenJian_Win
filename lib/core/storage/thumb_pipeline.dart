import 'dart:io';
import 'dart:typed_data';

import '../protocol/thumb_image_tier.dart';
import '../../features/nas/data/api/services/thumbnail_service.dart';
import 'thumb_cache_store.dart';
import 'thumb_diag.dart';
import 'thumb_generation_gate.dart';
import 'thumb_global_budget.dart';
import 'thumb_key_index.dart';

/// 查盘 → 经档位闸生成 → 写盘 + 索引（Windows NAS 主机统一入口）。
class ThumbPipeline {
  ThumbPipeline({
    required ThumbCacheStore cache,
    required ThumbGenerationGate gridGate,
    required ThumbGenerationGate previewGate,
    required ThumbnailService generator,
    required ThumbKeyIndex index,
    ThumbGlobalBudget? budget,
    this.generateTimeout = const Duration(seconds: 12),
  })  : _cache = cache,
        _gridGate = gridGate,
        _previewGate = previewGate,
        _generator = generator,
        _index = index,
        _budget = budget;

  /// 组装双闸 + 共享全局预算（remote/warmup/全局一律 1；preview 闸无 warmup）。
  factory ThumbPipeline.withDefaultGates({
    required ThumbCacheStore cache,
    required ThumbnailService generator,
    required ThumbKeyIndex index,
    Duration generateTimeout = const Duration(seconds: 12),
    int globalMax = ThumbGlobalBudget.defaultMaxConcurrent,
    int remoteMax = ThumbGenerationGate.defaultMaxRemote,
  }) {
    final budget = ThumbGlobalBudget(maxConcurrent: globalMax);
    late final ThumbGenerationGate gridGate;
    late final ThumbGenerationGate previewGate;
    bool anyRemoteDemand() =>
        gridGate.hasRemoteDemand || previewGate.hasRemoteDemand;
    gridGate = ThumbGenerationGate(
      name: 'grid',
      budget: budget,
      maxRemote: remoteMax,
      maxWarmup: ThumbGenerationGate.defaultMaxWarmup,
      shouldYieldWarmup: anyRemoteDemand,
    );
    previewGate = ThumbGenerationGate(
      name: 'preview',
      budget: budget,
      maxRemote: remoteMax,
      maxWarmup: 0,
      shouldYieldWarmup: anyRemoteDemand,
    );
    return ThumbPipeline(
      cache: cache,
      gridGate: gridGate,
      previewGate: previewGate,
      generator: generator,
      index: index,
      budget: budget,
      generateTimeout: generateTimeout,
    );
  }

  final ThumbCacheStore _cache;
  final ThumbGenerationGate _gridGate;
  final ThumbGenerationGate _previewGate;
  final ThumbnailService _generator;
  final ThumbKeyIndex _index;
  final ThumbGlobalBudget? _budget;
  final Duration generateTimeout;

  final Map<String, Future<Uint8List?>> _inflight = {};
  final Map<String, int> _failCounts = {};

  static const maxWarmupFails = 3;

  /// 预热专用：始终走 grid 闸。
  ThumbGenerationGate get gate => _gridGate;
  ThumbGenerationGate get gridGate => _gridGate;
  ThumbGenerationGate get previewGate => _previewGate;
  ThumbGlobalBudget? get budget => _budget;
  ThumbCacheStore get cache => _cache;
  ThumbKeyIndex get index => _index;
  int get inflightCount => _inflight.length;

  bool get hasRemoteDemand =>
      _gridGate.hasRemoteDemand || _previewGate.hasRemoteDemand;

  bool get shouldYieldWarmup => hasRemoteDemand;

  ThumbGenerationGate gateFor(ThumbImageTier tier) =>
      tier == ThumbImageTier.preview ? _previewGate : _gridGate;

  bool isPermanentlyFailed(String cacheKey) =>
      (_failCounts[cacheKey] ?? 0) >= maxWarmupFails;

  Future<Uint8List?> getOrGenerate({
    required File file,
    required ThumbImageTier tier,
    required String rootId,
    required String name,
    required int mtimeMs,
    required int sizeBytes,
    required ThumbGenPriority priority,
  }) async {
    final key = _cache.cacheKey(
      tier: tier,
      rootId: rootId,
      name: name,
      mtimeMs: mtimeMs,
      sizeBytes: sizeBytes,
    );

    if (priority == ThumbGenPriority.warmup && isPermanentlyFailed(key)) {
      return null;
    }

    final hit = await _cache.read(tier: tier, key: key);
    if (hit != null && hit.isNotEmpty) {
      return hit;
    }

    final existing = _inflight[key];
    if (existing != null) return existing;

    final gate = gateFor(tier);
    late final Future<Uint8List?> future;
    future = () async {
      try {
        final again = await _cache.read(tier: tier, key: key);
        if (again != null && again.isNotEmpty) return again;

        if (priority == ThumbGenPriority.warmup && shouldYieldWarmup) {
          return null;
        }

        Uint8List? bytes;
        try {
          bytes = await gate.run(
            priority: priority,
            label: '${tier.wireName}|$name',
            task: () async {
              if (priority == ThumbGenPriority.warmup && shouldYieldWarmup) {
                return null;
              }
              final sw = Stopwatch()..start();
              final raw = await _generator
                  .thumbnailFor(file, maxPx: tier.maxPx)
                  .timeout(generateTimeout, onTimeout: () {
                ThumbDiag.markPhase(
                  'pipeline_generate_timeout',
                  details: {
                    'name': name,
                    'tier': tier.wireName,
                    'timeoutSec': generateTimeout.inSeconds,
                  },
                );
                return null;
              });
              sw.stop();
              ThumbDiag.markPhase(
                'pipeline_generate_end',
                details: {
                  'name': name,
                  'tier': tier.wireName,
                  'priority': priority.name,
                  'bytes': raw?.length ?? 0,
                  'genMs': sw.elapsedMilliseconds,
                },
              );
              return raw;
            },
          );
        } catch (_) {
          return null;
        }

        if (bytes == null || bytes.isEmpty) {
          if (priority == ThumbGenPriority.warmup) {
            _failCounts[key] = (_failCounts[key] ?? 0) + 1;
          }
          return null;
        }

        await _cache.write(tier: tier, key: key, bytes: bytes);
        await _index.put(
          key: key,
          tier: tier,
          rootId: rootId,
          name: name,
        );
        _failCounts.remove(key);
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

  /// 应用内删除原图前：按 meta 清 grid+preview 与索引。
  Future<void> purgeSource({
    required String rootId,
    required String name,
    required int mtimeMs,
    required int sizeBytes,
  }) async {
    for (final tier in ThumbImageTier.values) {
      final key = _cache.cacheKey(
        tier: tier,
        rootId: rootId,
        name: name,
        mtimeMs: mtimeMs,
        sizeBytes: sizeBytes,
      );
      await _cache.delete(tier: tier, key: key);
      await _index.removeKey(key);
      _failCounts.remove(key);
    }
    // 历史旧 key（mtime 已变）：再按 path 扫索引。
    final extras = await _index.keysForSource(rootId: rootId, name: name);
    for (final e in extras) {
      await _cache.delete(tier: e.tier, key: e.key);
      await _index.removeKey(e.key);
    }
  }
}
