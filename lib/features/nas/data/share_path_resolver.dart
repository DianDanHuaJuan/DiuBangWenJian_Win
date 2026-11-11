import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/storage/storage_root.dart';
import '../../../core/storage/storage_root_store.dart';

/// 共享区内安全解析（防 `..` / 越界）；允许 `a/b` 相对路径。
class SharePathResolver {
  SharePathResolver({required StorageRootStore rootStore}) : _roots = rootStore;

  final StorageRootStore _roots;

  static bool isUnsafeName(String name) {
    if (name.isEmpty) return true;
    if (name.contains('..')) return true;
    if (name.contains('\\')) return true;
    if (name.startsWith('/')) return true;
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
    final joined = p.normalize(p.join(root.uriOrPath, relativePath));
    final canonicalRoot = p.normalize(root.uriOrPath);
    if (!p.isWithin(canonicalRoot, joined) && joined != canonicalRoot) {
      return null;
    }
    return File(joined);
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
    final joined = relativePath.isEmpty
        ? p.normalize(root.uriOrPath)
        : p.normalize(p.join(root.uriOrPath, relativePath));
    final canonicalRoot = p.normalize(root.uriOrPath);
    if (!p.isWithin(canonicalRoot, joined) && joined != canonicalRoot) {
      return null;
    }
    return Directory(joined);
  }
}
