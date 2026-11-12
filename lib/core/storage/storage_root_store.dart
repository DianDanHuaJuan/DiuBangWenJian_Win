import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../common/app_exception.dart';
import '../common/app_logger.dart';
import '../common/key_value_store.dart';
import 'app_paths.dart';
import 'default_share_directory_probe.dart';
import 'storage_access_diagnostics.dart';
import 'storage_constants.dart';
import 'storage_root.dart';

/// 当前根 + 历史根持久化（doc/02 storage_root_store）。
///
/// - 写只进 [current]；不自动切盘（决策 #14）。
/// - 默认写根有且仅有公共 `Download/diubangfiles`；禁止应用私有目录落盘。
/// - 用户手动改过的根以用户为准，不再静默跳回默认（除非当前根是私有目录）。
class StorageRootStore {
  StorageRootStore({
    required KeyValueStore keyValueStore,
    this.onPersisted,
  }) : _kv = keyValueStore;

  final KeyValueStore _kv;

  /// 写根已落盘后回调（冷总线 commit）。
  Future<void> Function(String reason)? onPersisted;

  List<StorageRoot>? _cache;
  String? _currentId;

  /// 并发 [ensureCurrent] 共用一次创建（避免双开 `_createDefaultRoot` 撞探测文件）。
  Future<StorageRoot>? _ensureCurrentInFlight;

  /// 确保有可用写根并返回当前写根。
  ///
  /// 若尚无当前根，或当前根落在应用私有目录，则创建/切到公共默认根。
  Future<StorageRoot> ensureCurrent() async {
    await _syncFromDiskIfNeeded();
    final ready = _usableCurrent();
    if (ready != null) return ready;

    // 单飞：并发调用共用一次创建，避免双开探测文件互踩。
    return _ensureCurrentInFlight ??= _ensureCurrentLocked().whenComplete(() {
      _ensureCurrentInFlight = null;
    });
  }

  Future<StorageRoot> _ensureCurrentLocked() async {
    await _syncFromDiskIfNeeded();
    final ready = _usableCurrent();
    if (ready != null) return ready;

    final current = _findCurrent();
    if (current != null && isAppPrivateStoragePath(current.uriOrPath)) {
      AppLogger.log(
        'discard private current root → recreate public default',
        scope: 'storage',
        details: {'id': current.id, 'path': current.uriOrPath},
      );
      final list = [...?_cache];
      final index = list.indexWhere((r) => r.id == current.id);
      if (index >= 0) {
        list[index] = list[index].copyWith(revoked: true);
        _cache = list;
      }
      _currentId = null;
    }

    try {
      final created = await _createDefaultRoot();
      _cache = [...?_cache, created];
      _currentId = created.id;
      await _persist();
      AppLogger.log(
        'ensureCurrent created default root',
        scope: 'storage',
        details: {'id': created.id, 'path': created.uriOrPath},
      );
      await onPersisted?.call('storage_root_default');
      return created;
    } catch (e, st) {
      await StorageAccessDiagnostics.logSnapshot('ensureCurrent_create_failed');
      AppLogger.log(
        'ensureCurrent create failed',
        scope: 'storage',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }

  StorageRoot? _usableCurrent() {
    final current = _findCurrent();
    if (current != null &&
        !current.revoked &&
        !isAppPrivateStoragePath(current.uriOrPath)) {
      return current;
    }
    return null;
  }

  Future<StorageRoot?> get current async {
    await _syncFromDiskIfNeeded();
    return _findCurrent();
  }

  Future<List<StorageRoot>> listRoots() async {
    await _syncFromDiskIfNeeded();
    return List.unmodifiable(_cache ?? const []);
  }

  /// 历史根（不含当前；含已撤销，浏览层自行过滤）。
  Future<List<StorageRoot>> historyRoots() async {
    await _syncFromDiskIfNeeded();
    final id = _currentId;
    return (_cache ?? const [])
        .where((r) => r.id != id)
        .toList(growable: false);
  }

  /// 将 [root] 设为当前写根；若为新根则追加进列表。
  ///
  /// 禁止设为应用私有目录。
  Future<void> setCurrent(StorageRoot root) async {
    if (isAppPrivateStoragePath(root.uriOrPath)) {
      throw const AppException(
        code: 'storage_private_forbidden',
        message: '禁止使用应用私有目录作为落盘位置，请改用公共 Download 或其他外置目录',
      );
    }
    await _syncFromDiskIfNeeded();
    final list = [...?_cache];
    final index = list.indexWhere((r) => r.id == root.id);
    if (index >= 0) {
      list[index] = root;
    } else {
      list.add(root);
    }
    _cache = list;
    _currentId = root.id;
    await _persist();
    await onPersisted?.call('storage_root');
  }

  Future<void> markRevoked(String rootId) async {
    await _syncFromDiskIfNeeded();
    final list = [...?_cache];
    final index = list.indexWhere((r) => r.id == rootId);
    if (index < 0) return;
    list[index] = list[index].copyWith(revoked: true);
    _cache = list;
    if (_currentId == rootId) {
      _currentId = null;
    }
    await _persist();
    await onPersisted?.call('storage_root_revoked');
  }

  StorageRoot? _findCurrent() {
    final id = _currentId;
    if (id == null) return null;
    for (final r in _cache ?? const <StorageRoot>[]) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// UI isolate 写 prefs 后，FGS isolate 的 SharedPreferences 内存与 [_cache]
  /// 都不会自动更新；每次读根前 reload，id 变化则丢弃内存重载。
  Future<void> _syncFromDiskIfNeeded() async {
    await _kv.reload();
    final diskId = _kv.getString(StorageConstants.kvCurrentRootId);
    if (_cache != null && diskId == _currentId) {
      return;
    }
    _cache = null;
    _currentId = null;
    await _load();
  }

  Future<void> _load() async {
    if (_cache != null) return;
    _currentId = _kv.getString(StorageConstants.kvCurrentRootId);
    final raw = _kv.getString(StorageConstants.kvRootsJson);
    if (raw == null || raw.isEmpty) {
      _cache = [];
      return;
    }
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      _cache = list
          .map((e) => StorageRoot.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (e) {
      AppLogger.log('storage roots corrupt: $e', scope: 'storage');
      _cache = [];
      _currentId = null;
    }
  }

  Future<void> _persist() async {
    final roots = _cache ?? const <StorageRoot>[];
    await _kv.setString(
      StorageConstants.kvRootsJson,
      jsonEncode(roots.map((r) => r.toJson()).toList()),
    );
    final id = _currentId;
    if (id == null) {
      await _kv.remove(StorageConstants.kvCurrentRootId);
    } else {
      await _kv.setString(StorageConstants.kvCurrentRootId, id);
    }
  }

  /// 创建默认写根：仅公共 `Download/diubangfiles`。
  Future<StorageRoot> _createDefaultRoot() async {
    final dir = await resolveDefaultShareDirectory();
    final now = DateTime.now().millisecondsSinceEpoch;
    return StorageRoot(
      id: 'default_$now',
      kind: StorageRootKind.path,
      uriOrPath: dir.path,
      displayName: StorageConstants.displayPathLabel,
      addedAtMs: now,
    );
  }
}

/// 是否为应用私有落盘路径（禁止作为共享写根）。
bool isAppPrivateStoragePath(String path) {
  final n = AppPaths.portable(path).toLowerCase();
  if (n.contains('/app_flutter')) return true;
  if (n.contains('/data/user/')) return true;
  if (n.contains('/data/data/')) return true;
  // 应用专属外部目录仍属私有沙箱，相册/文件管理器默认不可见。
  if (RegExp(r'/android/data/[^/]+/(files|cache)(/|$)').hasMatch(n)) {
    return true;
  }
  return false;
}

/// 下载开始前调用：统一申请公共目录写权限并探测可写（避免多任务并发 request）。
Future<void> ensureShareStorageReady() => resolveDefaultShareDirectory();

Future<Directory>? _resolveDefaultShareInFlight;

/// 解析默认可写共享目录：有且仅有公共 `Download/diubangfiles`，失败则抛错（不回退私有目录）。
///
/// 默认路径（无 [tryPublicDownload]）单飞：并发调用共用一次探测。
Future<Directory> resolveDefaultShareDirectory({
  Future<Directory?> Function()? tryPublicDownload,
}) async {
  // 测试注入探测目录时不走单飞，避免互相串结果。
  if (tryPublicDownload != null) {
    return _resolveDefaultShareDirectoryBody(tryPublicDownload);
  }
  return _resolveDefaultShareInFlight ??=
      _resolveDefaultShareDirectoryBody(_tryPublicDownloadDir).whenComplete(() {
    _resolveDefaultShareInFlight = null;
  });
}

Future<Directory> _resolveDefaultShareDirectoryBody(
  Future<Directory?> Function() publicProbe,
) async {
  final public = await publicProbe();
  if (public == null) {
    throw const AppException(
      code: 'storage_public_unavailable',
      message: '无法定位公共 Download 目录，请在设置中手动指定落盘位置',
    );
  }
  if (isAppPrivateStoragePath(public.path)) {
    throw const AppException(
      code: 'storage_private_forbidden',
      message: '默认落盘禁止使用应用私有目录',
    );
  }

  try {
    await public.create(recursive: true);
    // 唯一探测文件名：避免并发写/删同一 `.write_probe` 被误判为「不可写」。
    final probe = File(
      p.join(
        public.path,
        '.write_probe_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await probe.writeAsString('ok', flush: true);
    try {
      await probe.delete();
    } catch (_) {}
    AppLogger.log(
      'public Download writable',
      scope: 'storage',
      details: {'path': public.path},
    );
    return public;
  } catch (e) {
    AppLogger.log(
      'public Download not writable: $e',
      scope: 'storage',
      details: {'path': public.path},
    );
    await StorageAccessDiagnostics.logSnapshot('download_not_writable');
    throw AppException(
      code: 'storage_public_not_writable',
      message: '公共 Download 目录不可写，请授予「所有文件访问」权限后重试',
      originalError: e,
    );
  }
}

/// 后台安全：只读权限状态，**绝不** [Permission.request]
///（FGS/HTTP 无 Activity → PlatformException → 远端 HTTP 500）。
///
/// 权限须在开启 NAS 的 UI 流程中申请完毕。
Future<Directory?> _tryPublicDownloadDir() =>
    DefaultShareDirectoryProbe.create().probe();
