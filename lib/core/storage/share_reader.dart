import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_paths.dart';
import 'storage_root.dart';
import 'storage_root_store.dart';

/// 共享区列举 / 删除（当前根 ∪ 历史 path 根；SAF 阶段后续）。
class ShareReader {
  ShareReader({required StorageRootStore rootStore}) : _roots = rootStore;

  final StorageRootStore _roots;

  /// 兼容旧调用：当前根（+可选历史）顶层仅文件扁平列表。
  Future<List<ShareEntry>> listFiles({bool includeHistory = true}) async {
    final current = await _roots.ensureCurrent();
    final roots = <StorageRoot>[current];
    if (includeHistory) {
      roots.addAll(await _roots.historyRoots());
    }
    final out = <ShareEntry>[];
    for (final root in roots) {
      if (root.revoked || root.kind != StorageRootKind.path) continue;
      out.addAll(
        await listDirectory(rootId: root.id, relativePath: '', filesOnly: true),
      );
    }
    out.sort((a, b) => b.modifiedAtMs.compareTo(a.modifiedAtMs));
    return out;
  }

  /// 列举某根下相对目录的直接子项（文件+文件夹）。
  Future<List<ShareEntry>> listDirectory({
    required String rootId,
    String relativePath = '',
    bool filesOnly = false,
  }) async {
    final root = await _findRoot(rootId);
    if (root == null || root.revoked || root.kind != StorageRootKind.path) {
      return const [];
    }
    // 空相对路径 = 共享根本身，必须可列；非空才做安全校验。
    if (relativePath.isNotEmpty && !_isSafeRelative(relativePath)) {
      return const [];
    }

    final dirPath = relativePath.isEmpty
        ? root.uriOrPath
        : p.join(root.uriOrPath, relativePath);
    final canonicalRoot = p.normalize(root.uriOrPath);
    final canonicalDir = p.normalize(dirPath);
    if (!p.isWithin(canonicalRoot, canonicalDir) &&
        canonicalDir != canonicalRoot) {
      return const [];
    }

    final dir = Directory(canonicalDir);
    if (!await dir.exists()) return const [];

    final out = <ShareEntry>[];
    await for (final entity in dir.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue;
      final isDir = entity is Directory;
      if (filesOnly && isDir) continue;
      if (entity is! File && entity is! Directory) continue;

      final rel = relativePath.isEmpty ? name : p.join(relativePath, name);
      final stat = await entity.stat();
      out.add(
        ShareEntry(
          rootId: root.id,
          rootDisplayName: root.displayName,
          fileName: name,
          relativePath: AppPaths.portable(rel),
          absolutePath: entity.path,
          sizeBytes: isDir ? 0 : stat.size,
          modifiedAtMs: stat.modified.millisecondsSinceEpoch,
          isDirectory: isDir,
        ),
      );
    }

    out.sort((a, b) {
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return b.modifiedAtMs.compareTo(a.modifiedAtMs);
    });
    return out;
  }

  /// 可用根列表（当前 + 未吊销历史）。
  Future<List<StorageRoot>> listAccessibleRoots({
    bool includeHistory = true,
  }) async {
    final current = await _roots.ensureCurrent();
    final out = <StorageRoot>[];
    if (!current.revoked && current.kind == StorageRootKind.path) {
      out.add(current);
    }
    if (includeHistory) {
      for (final r in await _roots.historyRoots()) {
        if (!r.revoked && r.kind == StorageRootKind.path) out.add(r);
      }
    }
    return out;
  }

  Future<bool> deleteEntry({
    required String rootId,
    required String relativePath,
  }) async {
    final root = await _findRoot(rootId);
    if (root == null || root.revoked || root.kind != StorageRootKind.path) {
      return false;
    }
    if (!_isSafeRelative(relativePath) || relativePath.isEmpty) return false;

    final joined = p.normalize(p.join(root.uriOrPath, relativePath));
    final canonicalRoot = p.normalize(root.uriOrPath);
    if (!p.isWithin(canonicalRoot, joined)) return false;

    final type = await FileSystemEntity.type(joined, followLinks: false);
    if (type == FileSystemEntityType.file) {
      await File(joined).delete();
      return true;
    }
    if (type == FileSystemEntityType.directory) {
      await Directory(joined).delete(recursive: true);
      return true;
    }
    return false;
  }

  Future<StorageRoot?> _findRoot(String rootId) async {
    final current = await _roots.ensureCurrent();
    if (current.id == rootId) return current;
    for (final root in await _roots.historyRoots()) {
      if (root.id == rootId) return root;
    }
    return null;
  }

  static bool _isSafeRelative(String relativePath) {
    final rel = AppPaths.portable(relativePath);
    if (rel.isEmpty) return false;
    if (rel.contains('..')) return false;
    if (rel.startsWith('/')) return false;
    return true;
  }
}

class ShareEntry {
  const ShareEntry({
    required this.rootId,
    required this.rootDisplayName,
    required this.fileName,
    required this.absolutePath,
    required this.sizeBytes,
    required this.modifiedAtMs,
    this.relativePath = '',
    this.isDirectory = false,
  });

  final String rootId;
  final String rootDisplayName;
  final String fileName;

  /// 相对共享根的路径（`a/b.txt`）；顶层文件即文件名。
  final String relativePath;
  final String absolutePath;
  final int sizeBytes;
  final int modifiedAtMs;
  final bool isDirectory;
}
