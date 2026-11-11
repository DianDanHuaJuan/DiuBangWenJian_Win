import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../common/app_logger.dart';
import '../file_provider/file_entry.dart';
import '../transfer/stream_transfer_tuning.dart';
import 'incomplete_file.dart';
import 'storage_volumes.dart';

/// 外置卷文件夹浏览（定案：不做分类墙、不做自建媒体索引）。
class ExternalVolumeBrowser {
  ExternalVolumeBrowser({StorageVolumes? volumes})
      : _volumes = volumes ?? StorageVolumes();

  static const rootIdPrefix = 'extvol:';

  final StorageVolumes _volumes;

  Future<List<StorageVolumeInfo>> listExternalVolumes() async {
    final all = await _volumes.list();
    // 非主卷即视为外置（部分机型 OTG 的 isRemovable 标志不可靠）。
    final external = all
        .where((v) => !v.isPrimary && v.path.isNotEmpty)
        .toList(growable: false);
    AppLogger.log(
      'listExternalVolumes',
      scope: 'extvol',
      details: {
        'allCount': all.length,
        'externalCount': external.length,
        'external': [
          for (final v in external)
            {
              'path': v.path,
              'removable': v.isRemovable,
              'writable': v.writable,
              'state': v.state,
            },
        ],
      },
    );
    return external;
  }

  String rootIdFor(String volumePath) => '$rootIdPrefix${_norm(volumePath)}';

  String? volumePathFromRootId(String rootId) {
    if (!rootId.startsWith(rootIdPrefix)) return null;
    return rootId.substring(rootIdPrefix.length);
  }

  /// [relativePath] 相对卷根；空=卷根。
  Future<List<FileEntry>> listDirectory({
    required String volumePath,
    required String volumeLabel,
    String relativePath = '',
  }) async {
    final root = _norm(volumePath);
    if (root.isEmpty) return const [];
    final dirPath = relativePath.isEmpty
        ? root
        : p.join(root, relativePath.replaceAll('/', p.separator));
    final dir = Directory(dirPath);
    if (!await dir.exists()) return const [];

    final rootId = rootIdFor(root);
    final out = <FileEntry>[];
    try {
      await for (final entity in dir.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (name.startsWith('.')) continue;
        final isDir = entity is Directory;
        if (entity is! File && entity is! Directory) continue;
        final rel = relativePath.isEmpty
            ? name
            : '$relativePath/$name'.replaceAll('\\', '/');
        var size = 0;
        var modified = 0;
        try {
          final st = await entity.stat();
          size = isDir ? 0 : st.size;
          modified = st.modified.millisecondsSinceEpoch;
        } catch (_) {}
        out.add(
          FileEntry(
            name: name,
            relativePath: rel.replaceAll('\\', '/'),
            rootId: rootId,
            rootDisplayName: volumeLabel,
            isDirectory: isDir,
            sizeBytes: size,
            modifiedAtMs: modified,
            absolutePath: entity.path,
          ),
        );
      }
    } catch (e, st) {
      // 典型：无 MES 时 PathAccessException / FileSystemException。
      AppLogger.log(
        'extvol Directory.list failed',
        scope: 'extvol',
        error: e,
        stackTrace: st,
        details: {
          'volumePath': root,
          'relativePath': relativePath,
          'dirPath': dirPath,
        },
      );
      rethrow;
    }
    out.sort((a, b) {
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  Future<bool> deleteEntry({
    required String volumePath,
    required String relativePath,
  }) async {
    final abs = relativePath.isEmpty
        ? volumePath
        : p.join(volumePath, relativePath.replaceAll('/', p.separator));
    final file = File(abs);
    final dir = Directory(abs);
    try {
      if (await file.exists()) {
        await file.delete();
        return true;
      }
      if (await dir.exists()) {
        await dir.delete(recursive: true);
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// 把文件写入卷内某个目录。重名时在主文件名后加序号。不扫进系统相册。
  Future<String?> writeFile({
    required String volumePath,
    required String relativeDir,
    required String fileName,
    required List<int> bytes,
  }) async {
    return writeFileFromStream(
      volumePath: volumePath,
      relativeDir: relativeDir,
      fileName: fileName,
      stream: Stream<List<int>>.value(bytes),
      expectedLength: bytes.length,
    );
  }

  /// 流式写入外置卷目录（边收边写）。
  Future<String?> writeFileFromStream({
    required String volumePath,
    required String relativeDir,
    required String fileName,
    required Stream<List<int>> stream,
    int? expectedLength,
  }) async {
    final root = _norm(volumePath);
    if (root.isEmpty || !await isVolumeMounted(root)) return null;
    final dirRel = relativeDir.replaceAll('\\', '/').trim();
    final baseName = p.basename(fileName.replaceAll('\\', '/')).trim();
    if (baseName.isEmpty ||
        baseName == '.' ||
        baseName == '..' ||
        baseName.contains('\x00')) {
      return null;
    }
    if (dirRel.contains('..') ||
        dirRel.startsWith('/') ||
        dirRel.contains('\x00')) {
      return null;
    }
    final dirAbs = dirRel.isEmpty
        ? root
        : _norm(p.join(root, dirRel.replaceAll('/', p.separator)));
    if (dirAbs != root && !dirAbs.startsWith('$root/')) return null;
    final dir = Directory(dirAbs.replaceAll('/', p.separator));
    if (!await dir.exists()) return null;
    final stored = await _uniqueFileName(dir, baseName);
    final file = File(p.join(dir.path, stored));
    final sink = file.openWrite();
    try {
      await for (final chunk in StreamTransferTuning.bufferUploadStream(stream)) {
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      final len = await file.length();
      if (len <= 0) {
        await discardIncompleteFile(file.path);
        return null;
      }
      return stored;
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      await discardIncompleteFile(file.path);
      rethrow;
    }
  }

  Future<String> _uniqueFileName(Directory dir, String preferred) async {
    if (!await File(p.join(dir.path, preferred)).exists()) return preferred;
    final stem = p.basenameWithoutExtension(preferred);
    final ext = p.extension(preferred);
    for (var i = 1; i < 10000; i++) {
      final name = '$stem ($i)$ext';
      if (!await File(p.join(dir.path, name)).exists()) return name;
    }
    return '$stem (${DateTime.now().millisecondsSinceEpoch})$ext';
  }

  /// 卷是否仍挂载（拔盘检测）。
  Future<bool> isVolumeMounted(String volumePath) async {
    final list = await listExternalVolumes();
    final target = _norm(volumePath);
    return list.any((v) => _norm(v.path) == target);
  }

  /// 解析外置卷上的文件；路径必须落在已挂载的非主卷内。
  Future<File?> resolveFile({
    required String volumePath,
    required String relativePath,
  }) async {
    final root = _norm(volumePath);
    if (root.isEmpty) return null;
    if (!await isVolumeMounted(root)) return null;
    final rel = relativePath.replaceAll('\\', '/').trim();
    if (rel.isEmpty ||
        rel.contains('..') ||
        rel.startsWith('/') ||
        rel.contains('\x00')) {
      return null;
    }
    final abs = _norm(p.join(root, rel.replaceAll('/', p.separator)));
    if (abs != root && !abs.startsWith('$root/')) return null;
    final file = File(abs.replaceAll('/', p.separator));
    if (!await file.exists()) return null;
    return file;
  }

  String _norm(String path) =>
      path.trim().replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
}
