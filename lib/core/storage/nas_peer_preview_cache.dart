import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../common/app_logger.dart';

/// 对端 NAS 预览磁盘缓存：按 peer 会话登记，leave / 启动时清理。
///
/// 见 docs/对端NAS预览缓存策略.md。不含聊天缓存与公共库。
class NasPeerPreviewCache {
  NasPeerPreviewCache._();

  static final NasPeerPreviewCache instance = NasPeerPreviewCache._();

  static const _manifestName = 'wenjian_nas_preview_session.json';

  Future<File>? _manifestFuture;
  Map<String, _PeerSession>? _peers;
  Future<void>? _loadFuture;

  Future<File> _manifestFile() {
    return _manifestFuture ??= () async {
      final tmp = await getTemporaryDirectory();
      return File(p.join(tmp.path, _manifestName));
    }();
  }

  Future<void> _ensureLoaded() {
    return _loadFuture ??= _load();
  }

  Future<void> _load() async {
    try {
      final f = await _manifestFile();
      if (!await f.exists()) {
        _peers = {};
        return;
      }
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map) {
        _peers = {};
        return;
      }
      final peersRaw = raw['peers'];
      final map = <String, _PeerSession>{};
      if (peersRaw is Map) {
        for (final e in peersRaw.entries) {
          final fp = e.key.toString();
          final v = e.value;
          if (v is! Map) continue;
          final paths = <String>{};
          final list = v['paths'];
          if (list is List) {
            for (final x in list) {
              final s = x?.toString().trim() ?? '';
              if (s.isNotEmpty) paths.add(s);
            }
          }
          map[fp] = _PeerSession(
            status: (v['status'] as String?) ?? 'active',
            paths: paths,
            updatedAtMs: v['updatedAtMs'] as int? ?? 0,
          );
        }
      }
      _peers = map;
    } catch (e, st) {
      AppLogger.log(
        'nas preview cache load failed',
        scope: 'cache',
        error: e,
        stackTrace: st,
      );
      _peers = {};
    }
  }

  Future<void> _persist() async {
    final peers = _peers;
    if (peers == null) return;
    try {
      final f = await _manifestFile();
      final body = {
        'peers': {
          for (final e in peers.entries)
            e.key: {
              'status': e.value.status,
              'paths': e.value.paths.toList()..sort(),
              'updatedAtMs': e.value.updatedAtMs,
            },
        },
      };
      await f.writeAsString(jsonEncode(body), flush: true);
    } catch (e, st) {
      AppLogger.log(
        'nas preview cache persist failed',
        scope: 'cache',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// 登记对端预览缓存文件（写入成功后调用）。
  Future<void> track({
    required String peerFingerprint,
    required String absolutePath,
  }) async {
    final fp = peerFingerprint.trim();
    final path = absolutePath.trim();
    if (fp.isEmpty || path.isEmpty) return;
    await _ensureLoaded();
    final peers = _peers!;
    final now = DateTime.now().millisecondsSinceEpoch;
    final session = peers.putIfAbsent(
      fp,
      () => _PeerSession(status: 'active', paths: {}, updatedAtMs: now),
    );
    session.status = 'active';
    session.updatedAtMs = now;
    if (session.paths.add(path)) {
      await _persist();
    }
  }

  /// 结束某 peer 会话：删登记文件并去掉条目。
  Future<void> endPeerSession(String? peerFingerprint) async {
    final fp = peerFingerprint?.trim() ?? '';
    if (fp.isEmpty) return;
    await _ensureLoaded();
    final session = _peers!.remove(fp);
    await _persist();
    if (session == null) return;
    await _deletePaths(session.paths);
  }

  /// 启动扫尾：清理所有残留会话（含杀进程留下的 active）。
  Future<void> purgeStaleOnLaunch() async {
    await _ensureLoaded();
    final peers = _peers!;
    if (peers.isEmpty) return;
    final allPaths = <String>{};
    for (final s in peers.values) {
      allPaths.addAll(s.paths);
    }
    peers.clear();
    await _persist();
    await _deletePaths(allPaths);
  }

  Future<void> _deletePaths(Set<String> paths) async {
    for (final path in paths) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
      try {
        final part = File('$path.part');
        if (await part.exists()) await part.delete();
      } catch (_) {}
    }
  }
}

class _PeerSession {
  _PeerSession({
    required this.status,
    required this.paths,
    required this.updatedAtMs,
  });

  String status;
  final Set<String> paths;
  int updatedAtMs;
}
