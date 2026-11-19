import 'dart:io';

import 'package:path/path.dart' as p;

import 'backup_category.dart';
import 'media_library_service.dart';
import 'share_receive_paths.dart';
import 'share_writer.dart';
import 'storage_path_policy.dart';
import 'storage_root_store.dart';

/// 备份接收：默认安装根写入对应分类目录；换根后写共享根顶层。
class BackupReceiveService {
  BackupReceiveService({
    required this.rootStore,
    required this.shareWriter,
    MediaLibraryService? mediaLibrary,
  }) : _mediaLibrary = mediaLibrary;

  final StorageRootStore rootStore;
  final ShareWriter shareWriter;
  final MediaLibraryService? _mediaLibrary;

  Future<String> _relativeDir(BackupCategory category) async {
    final root = await rootStore.ensureCurrent();
    if (root.revoked || !root.isPath) {
      throw StateError('share root unavailable');
    }
    return ShareReceivePaths.relativeDirForBackup(
      root: root,
      category: category,
    );
  }

  /// 目标目录下是否已有同名文件（文件名去重，不做内容哈希）。
  Future<({bool exists, String? storedName})> exists({
    required BackupCategory category,
    required String fileName,
  }) async {
    final root = await rootStore.ensureCurrent();
    if (root.revoked || !root.isPath) {
      return (exists: false, storedName: null);
    }
    final base = p.basename(fileName).trim();
    if (base.isEmpty) return (exists: false, storedName: null);
    final rel = ShareReceivePaths.relativeDirForBackup(
      root: root,
      category: category,
    );
    final file = File(
      rel.isEmpty
          ? p.join(root.uriOrPath, base)
          : p.join(root.uriOrPath, rel, base),
    );
    if (await file.exists()) {
      return (exists: true, storedName: base);
    }
    return (exists: false, storedName: null);
  }

  Future<ShareWriteResult> receiveBytes({
    required BackupCategory category,
    required String preferredFileName,
    required List<int> bytes,
  }) async {
    final written = await shareWriter.writeBytes(
      preferredFileName: p.basename(preferredFileName),
      bytes: bytes,
      relativeDir: await _relativeDir(category),
      numericCollisionSuffix: true,
    );
    await _afterWrite(written.absolutePath);
    return written;
  }

  /// 流式落盘；调用方写入并 close 后须 [notifyWritten]。
  Future<({IOSink sink, ShareWriteResult result})> openReceiveSink({
    required BackupCategory category,
    required String preferredFileName,
    int? expectedLength,
  }) async {
    return shareWriter.openWriteSink(
      preferredFileName: p.basename(preferredFileName),
      expectedLength: expectedLength,
      relativeDir: await _relativeDir(category),
      numericCollisionSuffix: true,
    );
  }

  Future<void> notifyWritten(String absolutePath) => _afterWrite(absolutePath);

  Future<void> _afterWrite(String absolutePath) async {
    if (await shouldScanIntoMediaStore(absolutePath)) {
      _mediaLibrary?.invalidateCache();
    }
  }
}
