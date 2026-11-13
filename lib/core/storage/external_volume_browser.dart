import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../common/app_logger.dart';
import '../file_provider/file_entry.dart';
import '../transfer/stream_transfer_tuning.dart';
import 'app_paths.dart';
import 'incomplete_file.dart';
import 'storage_volumes.dart';

/// 外置卷文件夹浏览（定案：不做分类墙、不做自建媒体索引）。
class ExternalVolumeBrowser {
  ExternalVolumeBrowser({StorageVolumes? volumes})
      : _volumes = volumes ?? StorageVolumes();

  static const rootIdPrefix = 'extvol:';

  final StorageVolumes _volumes;

  /// 可浏览卷：含全部盘符/主卷与可移动卷（定案：目录树整机可访问存储）。
  Future<List<StorageVolumeInfo>> listBrowsableVolumes() async {
    final all = await _volumes.list();
    final list =
        all.where((v) => v.path.isNotEmpty).toList(growable: false);
    AppLogger.log(
      'listBrowsableVolumes',
      scope: 'extvol',
      details: {
        'allCount': all.length,
        'count': list.length,
        'items': [
          for (final v in list)
            {
              'path': v.path,
              'primary': v.isPrimary,
              'removable': v.isRemovable,
              'writable': v.writable,
              'state': v.state,
            },
        ],
      },
    );
    return list;
  }

  /// 非主卷（OTG/SD）；部分机型 isRemovable 不可靠，以 !isPrimary 为准。
  Future<List<StorageVolumeInfo>> listExternalVolumes() async {
    final all = await listBrowsableVolumes();
    final external =
        all.where((v) => !v.isPrimary).toList(growable: false);
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

  String rootIdFor(String volumePath) =>
      '$rootIdPrefix${normalizePath(volumePath)}';

  String? volumePathFromRootId(String rootId) {
    if (!rootId.startsWith(rootIdPrefix)) return null;
    final raw = rootId.substring(rootIdPrefix.length);
    if (raw.isEmpty) return null;
    return normalizePath(raw);
  }

  /// 路径是否指向同一卷。
  bool isSameVolumePath(String a, String b) => AppPaths.equals(a, b);

  /// 卷路径 portable 形式（委托 [AppPaths.portable]）。
  static String normalizePath(String path) => AppPaths.portable(path);

  /// [relativePath] 相对卷根；空=卷根。
  Future<List<FileEntry>> listDirectory({
    required String volumePath,
    required String volumeLabel,
    String relativePath = '',
  }) async {
    final root = normalizePath(volumePath);
    if (root.isEmpty) return const [];
    final relPortable = AppPaths.portable(relativePath);
    final dirPath = relPortable.isEmpty
        ? AppPaths.native(root)
        : AppPaths.native(AppPaths.joinPortable(root, relPortable));
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
        final rel = relPortable.isEmpty
            ? AppPaths.portable(name)
            : AppPaths.joinPortable(relPortable, name);
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
            relativePath: rel,
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
    final root = normalizePath(volumePath);
    if (root.isEmpty) return false;
    final relPortable = AppPaths.portable(relativePath);
    final abs = relPortable.isEmpty
        ? AppPaths.native(root)
        : AppPaths.native(AppPaths.joinPortable(root, relPortable));
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
    final root = normalizePath(volumePath);
    if (root.isEmpty || !await isVolumeMounted(root)) return null;
    final dirRel = AppPaths.portable(relativeDir);
    final baseName = p.basename(AppPaths.portable(fileName)).trim();
    if (baseName.isEmpty ||
        baseName == '.' ||
        baseName == '..' ||
        baseName.contains('\x00')) {
      return null;
    }
    if (dirRel.contains('..') || dirRel.startsWith('/') || dirRel.contains('\x00')) {
      return null;
    }
    final dirAbsPortable =
        dirRel.isEmpty ? root : AppPaths.joinPortable(root, dirRel);
    if (!AppPaths.isWithinPortable(root, dirAbsPortable)) return null;
    final dir = Directory(AppPaths.native(dirAbsPortable));
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
    final list = await listBrowsableVolumes();
    return list.any((v) => isSameVolumePath(v.path, volumePath));
  }

  /// 解析外置卷上的文件；路径必须落在已挂载的非主卷内。
  Future<File?> resolveFile({
    required String volumePath,
    required String relativePath,
  }) async {
    final root = normalizePath(volumePath);
    if (root.isEmpty) return null;
    if (!await isVolumeMounted(root)) return null;
    final rel = AppPaths.portable(relativePath);
    if (rel.isEmpty ||
        rel.contains('..') ||
        rel.startsWith('/') ||
        rel.contains('\x00')) {
      return null;
    }
    final absPortable = AppPaths.joinPortable(root, rel);
    if (!AppPaths.isWithinPortable(root, absPortable)) return null;
    final file = File(AppPaths.native(absPortable));
    if (!await file.exists()) return null;
    return file;
  }
}
