import 'dart:io';

import 'package:path/path.dart' as p;

import '../common/app_exception.dart';
import 'app_paths.dart';
import 'storage_constants.dart';
import 'storage_root.dart';
import 'storage_root_store.dart';
import 'windows_system_stats.dart';

/// 写入结果。
class ShareWriteResult {
  const ShareWriteResult({
    required this.absolutePath,
    required this.fileName,
    required this.rootId,
  });

  final String absolutePath;
  final String fileName;
  final String rootId;
}

/// 唯一接收写入口（doc/02 share_writer；决策 #14：只写当前根，不自动切盘）。
class ShareWriter {
  ShareWriter({
    required StorageRootStore rootStore,
    Future<int?> Function(String dirPath)? freeBytesReader,
  })  : _roots = rootStore,
        _freeBytesReader = freeBytesReader ?? _platformFreeBytes;

  final StorageRootStore _roots;
  final Future<int?> Function(String dirPath) _freeBytesReader;

  StorageRootStore get rootStore => _roots;

  /// 将 [bytes] 写入当前共享根；重名自动加后缀。
  ///
  /// [relativeDir] 为根下相对子目录（如 `图片`），禁止 `..` / 绝对路径。
  /// [numericCollisionSuffix] 为 true 时用 `name1.ext`（备份定案）；默认 `name (1).ext`。
  Future<ShareWriteResult> writeBytes({
    required String preferredFileName,
    required List<int> bytes,
    String relativeDir = '',
    bool numericCollisionSuffix = false,
  }) async {
    final root = await _roots.ensureCurrent();
    if (root.revoked) {
      throw const AppException(
        code: 'storage_unavailable',
        message: '当前共享位置不可用，请在设置中更换',
      );
    }
    if (root.kind != StorageRootKind.path) {
      throw const AppException(
        code: 'storage_kind_unsupported',
        message: '当前共享位置类型暂不支持写入，请改回本机 Download',
      );
    }
    if (isAppPrivateStoragePath(root.uriOrPath)) {
      throw const AppException(
        code: 'storage_private_forbidden',
        message: '禁止写入应用私有目录，请在设置中更换落盘位置',
      );
    }

    await _ensureSpace(root.uriOrPath, bytes.length);

    final dir = await _resolveWriteDir(root.uriOrPath, relativeDir);
    final uniqueName = await _uniqueName(
      dir,
      preferredFileName,
      numericSuffix: numericCollisionSuffix,
    );
    final file = File(p.join(dir.path, uniqueName));
    try {
      await file.writeAsBytes(bytes, flush: true);
    } on FileSystemException catch (e) {
      if (_isNoSpace(e)) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
        throw const AppException(
          code: 'storage_no_space',
          message: '存储空间不足，无法写入',
        );
      }
      rethrow;
    }

    return ShareWriteResult(
      absolutePath: file.path,
      fileName: uniqueName,
      rootId: root.id,
    );
  }

  /// 打开当前根下目标文件的写入 sink（大文件流式落盘）；调用方负责 close。
  ///
  /// 不做单文件断点续传：失败应由调用方 [discardIncompleteFile] 删除未完成文件。
  Future<({IOSink sink, ShareWriteResult result})> openWriteSink({
    required String preferredFileName,
    int? expectedLength,
    String relativeDir = '',
    bool numericCollisionSuffix = false,
  }) async {
    final root = await _roots.ensureCurrent();
    if (root.revoked || root.kind != StorageRootKind.path) {
      throw const AppException(
        code: 'storage_unavailable',
        message: '当前共享位置不可用',
      );
    }
    if (isAppPrivateStoragePath(root.uriOrPath)) {
      throw const AppException(
        code: 'storage_private_forbidden',
        message: '禁止写入应用私有目录，请在设置中更换落盘位置',
      );
    }
    if (expectedLength != null) {
      await _ensureSpace(root.uriOrPath, expectedLength);
    }

    final dir = await _resolveWriteDir(root.uriOrPath, relativeDir);
    final uniqueName = await _uniqueName(
      dir,
      preferredFileName,
      numericSuffix: numericCollisionSuffix,
    );
    final file = File(p.join(dir.path, uniqueName));
    final sink = file.openWrite();
    return (
      sink: sink,
      result: ShareWriteResult(
        absolutePath: file.path,
        fileName: uniqueName,
        rootId: root.id,
      ),
    );
  }

  Future<Directory> _resolveWriteDir(String rootPath, String relativeDir) async {
    final rootPortable = AppPaths.portable(rootPath);
    final trimmed = AppPaths.portable(relativeDir);
    if (trimmed.isEmpty) {
      final dir = Directory(AppPaths.native(rootPortable));
      await dir.create(recursive: true);
      return dir;
    }
    if (trimmed.contains('..') ||
        trimmed.startsWith('/') ||
        AppPaths.isWindowsDriveRoot(trimmed) ||
        trimmed.startsWith('//')) {
      throw const AppException(
        code: 'storage_bad_path',
        message: '非法写入子目录',
      );
    }
    final joinedPortable = AppPaths.joinPortable(rootPortable, trimmed);
    if (!AppPaths.isWithinPortable(rootPortable, joinedPortable)) {
      throw const AppException(
        code: 'storage_bad_path',
        message: '写入路径越界',
      );
    }
    final dir = Directory(AppPaths.native(joinedPortable));
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> _ensureSpace(String dirPath, int needBytes) async {
    try {
      final free = await _freeBytesReader(dirPath);
      if (free != null &&
          free >= 0 &&
          free < needBytes + StorageConstants.reserveBytes) {
        throw const AppException(
          code: 'storage_no_space',
          message: '存储空间不足，无法写入',
        );
      }
    } on AppException {
      rethrow;
    } catch (_) {
      // 探测失败不拦写；依赖写中途 ENOSPC。
    }
  }

  static Future<int?> _platformFreeBytes(String dirPath) =>
      WindowsSystemStats.freeBytesForPath(dirPath);

  bool _isNoSpace(FileSystemException e) {
    final msg = e.message.toLowerCase();
    return msg.contains('no space') ||
        msg.contains('enospc') ||
        e.osError?.errorCode == 28;
  }

  Future<String> _uniqueName(
    Directory dir,
    String preferred, {
    bool numericSuffix = false,
  }) async {
    final base = p.basename(preferred).trim();
    final safe = base.isEmpty ? 'file' : base;
    Future<bool> taken(String name) async {
      final path = p.join(dir.path, name);
      final type = await FileSystemEntity.type(path, followLinks: false);
      return type != FileSystemEntityType.notFound;
    }

    if (!await taken(safe)) return safe;

    final stem = p.basenameWithoutExtension(safe);
    final ext = p.extension(safe);
    for (var i = 1; i < 10000; i++) {
      final name = numericSuffix ? '$stem$i$ext' : '$stem ($i)$ext';
      if (!await taken(name)) return name;
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;
    return numericSuffix ? '$stem$stamp$ext' : '$stem ($stamp)$ext';
  }
}
