import 'dart:io';

import '../../../core/storage/app_paths.dart';
import '../../../core/storage/storage_root.dart';
import '../../../core/storage/storage_root_store.dart';

/// 共享区内安全解析（防 `..` / 越界）；允许 `a/b` 相对路径。
class SharePathResolver {
  SharePathResolver({required StorageRootStore rootStore}) : _roots = rootStore;

  final StorageRootStore _roots;

  static bool isUnsafeName(String name) {
    final rel = AppPaths.portable(name);
    if (rel.isEmpty) return true;
    if (rel.contains('..')) return true;
    if (rel.startsWith('/')) return true;
    if (AppPaths.isWindowsDriveRoot(rel) || rel.startsWith('//')) return true;
    return false;
  }

  Future<StorageRoot?> findRoot(String rootId) async {
    final current = await _roots.ensureCurrent();
    if (current.id == rootId) return current;
    for (final root in await _roots.historyRoots()) {
      if (root.id == rootId) return root;
    }
    return null;
  }

  Future<StorageRoot> currentRoot() => _roots.ensureCurrent();

  Future<File?> resolveFile({
    required String rootId,
    required String relativePath,
  }) async {
    final root = await findRoot(rootId);
    if (root == null || root.revoked || root.kind != StorageRootKind.path) {
      return null;
    }
    if (isUnsafeName(relativePath)) return null;
    final rootPortable = AppPaths.portable(root.uriOrPath);
    final joinedPortable =
        AppPaths.joinPortable(rootPortable, AppPaths.portable(relativePath));
    if (!AppPaths.isWithinPortable(rootPortable, joinedPortable)) {
      return null;
    }
    return File(AppPaths.native(joinedPortable));
  }

  Future<Directory?> resolveDir({
    required String rootId,
    required String relativePath,
  }) async {
    final root = await findRoot(rootId);
    if (root == null || root.revoked || root.kind != StorageRootKind.path) {
      return null;
    }
    if (relativePath.isNotEmpty && isUnsafeName(relativePath)) return null;
    final rootPortable = AppPaths.portable(root.uriOrPath);
    final joinedPortable = relativePath.isEmpty
        ? rootPortable
        : AppPaths.joinPortable(rootPortable, AppPaths.portable(relativePath));
    if (!AppPaths.isWithinPortable(rootPortable, joinedPortable)) {
      return null;
    }
    return Directory(AppPaths.native(joinedPortable));
  }
}
