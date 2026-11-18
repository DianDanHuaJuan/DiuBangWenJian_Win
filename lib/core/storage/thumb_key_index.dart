import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../protocol/thumb_image_tier.dart';
import 'app_paths.dart';
import 'storage_root_store.dart';
import 'thumb_diag.dart';

/// `{shareRoot}/.thumbs/index.json`：cacheKey → 源路径元数据（孤儿清理用）。
///
/// 内存先改；脏标记后 **防抖 3s** 整文件落盘；无变动不写。
class ThumbKeyIndex {
  ThumbKeyIndex({
    required StorageRootStore rootStore,
    this.persistDelay = const Duration(seconds: 3),
  }) : _roots = rootStore;

  final StorageRootStore _roots;
  final Duration persistDelay;

  Map<String, _Entry>? _cache;
  String? _loadedRootPath;
  Future<void>? _loadFuture;

  var _dirty = false;
  Timer? _persistTimer;
  Future<void>? _flushInflight;

  Future<File> _indexFile() async {
    final root = await _roots.ensureCurrent();
    final dir = Directory(
      AppPaths.native(
        AppPaths.joinPortable(AppPaths.portable(root.uriOrPath), '.thumbs'),
      ),
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File(p.join(dir.path, 'index.json'));
  }

  Future<void> _ensureLoaded() async {
    final root = await _roots.ensureCurrent();
    final rootPath = AppPaths.portable(root.uriOrPath);
    if (_cache != null && _loadedRootPath == rootPath) return;
    _loadFuture ??= () async {
      // 换根前尽量把旧脏数据刷掉。
      if (_dirty && _cache != null) {
        await flush();
      }
      final file = await _indexFile();
      final map = <String, _Entry>{};
      try {
        if (await file.exists()) {
          final raw = jsonDecode(await file.readAsString());
          if (raw is Map) {
            for (final e in raw.entries) {
              final v = e.value;
              if (v is! Map) continue;
              final tier = ThumbImageTier.tryParse('${v['tier']}');
              final rootId = '${v['rootId'] ?? ''}';
              final name = '${v['name'] ?? ''}';
              if (tier == null || rootId.isEmpty || name.isEmpty) continue;
              map['${e.key}'] = _Entry(
                tier: tier,
                rootId: rootId,
                name: name,
              );
            }
          }
        }
      } catch (e) {
        ThumbDiag.important('index_load_fail', details: {'error': '$e'});
      }
      _cache = map;
      _loadedRootPath = rootPath;
      _dirty = false;
    }();
    try {
      await _loadFuture;
    } finally {
      _loadFuture = null;
    }
  }

  void _schedulePersist() {
    _dirty = true;
    _persistTimer?.cancel();
    _persistTimer = Timer(persistDelay, () {
      unawaited(flush());
    });
  }

  Future<bool> _persistOnce() async {
    final map = _cache;
    if (map == null) return true;
    try {
      final file = await _indexFile();
      final out = <String, Object?>{};
      for (final e in map.entries) {
        out[e.key] = {
          'tier': e.value.tier.wireName,
          'rootId': e.value.rootId,
          'name': e.value.name,
        };
      }
      final part = File('${file.path}.part');
      await part.writeAsString(jsonEncode(out), flush: true);
      if (await file.exists()) await file.delete();
      await part.rename(file.path);
      return true;
    } catch (e) {
      ThumbDiag.important('index_persist_fail', details: {'error': '$e'});
      return false;
    }
  }

  /// 立即落盘（退出 / 换根）；无脏则 no-op。
  Future<void> flush() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    while (true) {
      if (_flushInflight != null) {
        await _flushInflight;
        if (!_dirty) return;
        continue;
      }
      if (!_dirty || _cache == null) return;

      final op = () async {
        try {
          while (_dirty) {
            _dirty = false;
            final ok = await _persistOnce();
            if (!ok) {
              _dirty = true;
              _persistTimer?.cancel();
              _persistTimer = Timer(persistDelay, () {
                unawaited(flush());
              });
              break;
            }
          }
        } finally {
          _flushInflight = null;
        }
      }();
      _flushInflight = op;
      await op;
      if (!_dirty) return;
    }
  }

  /// 换根后丢弃内存缓存（下次按新根加载）。
  void invalidateMemory() {
    _persistTimer?.cancel();
    _persistTimer = null;
    _cache = null;
    _loadedRootPath = null;
    _dirty = false;
  }

  /// 换根前：先 flush 再丢内存。
  Future<void> prepareRootChange() async {
    await flush();
    invalidateMemory();
  }

  Future<void> put({
    required String key,
    required ThumbImageTier tier,
    required String rootId,
    required String name,
  }) async {
    await _ensureLoaded();
    _cache![key] = _Entry(tier: tier, rootId: rootId, name: name);
    _schedulePersist();
  }

  Future<void> removeKey(String key) async {
    await _ensureLoaded();
    if (_cache!.remove(key) != null) {
      _schedulePersist();
    }
  }

  Future<List<({String key, ThumbImageTier tier, String rootId, String name})>>
      entries() async {
    await _ensureLoaded();
    return _cache!.entries
        .map(
          (e) => (
            key: e.key,
            tier: e.value.tier,
            rootId: e.value.rootId,
            name: e.value.name,
          ),
        )
        .toList(growable: false);
  }

  Future<List<({String key, ThumbImageTier tier})>> keysForSource({
    required String rootId,
    required String name,
  }) async {
    await _ensureLoaded();
    final out = <({String key, ThumbImageTier tier})>[];
    for (final e in _cache!.entries) {
      if (e.value.rootId == rootId && e.value.name == name) {
        out.add((key: e.key, tier: e.value.tier));
      }
    }
    return out;
  }
}

class _Entry {
  _Entry({
    required this.tier,
    required this.rootId,
    required this.name,
  });

  final ThumbImageTier tier;
  final String rootId;
  final String name;
}
