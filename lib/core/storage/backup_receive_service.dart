import 'dart:io';

import 'package:path/path.dart' as p;

import 'backup_category.dart';
import 'media_library_service.dart';
import 'media_scanner.dart';
import 'share_writer.dart';
import 'storage_path_policy.dart';
import 'storage_root_store.dart';

/// 备份接收：共享根下四分类目录写入（与正式下载落点一致：图片/视频/文档/其他）。
class BackupReceiveService {
  BackupReceiveService({
    required this.rootStore,
    required this.shareWriter,
    MediaScanner? mediaScanner,
    MediaLibraryService? mediaLibrary,
  })  : _scanner = mediaScanner ?? MediaScanner(),
        _mediaLibrary = mediaLibrary;

  final StorageRootStore rootStore;
  final ShareWriter shareWriter;
  final MediaScanner _scanner;
  final MediaLibraryService? _mediaLibrary;

  /// 确保四分类目录存在。
  Future<void> ensureCategoryFolders() async {
    final root = await rootStore.ensureCurrent();
    if (root.revoked || !root.isPath) {
      throw StateError('share root unavailable');
    }
    for (final cat in BackupCategory.values) {
      await Directory(p.join(root.uriOrPath, cat.folderName))
          .create(recursive: true);
    }
  }

  /// 目标分类下是否已有同名文件（文件名去重，不做内容哈希）。
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
    final file = File(p.join(root.uriOrPath, category.folderName, base));
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
    await ensureCategoryFolders();
    final written = await shareWriter.writeBytes(
      preferredFileName: p.basename(preferredFileName),
      bytes: bytes,
      relativeDir: category.folderName,
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
    await ensureCategoryFolders();
    return shareWriter.openWriteSink(
      preferredFileName: p.basename(preferredFileName),
      expectedLength: expectedLength,
      relativeDir: category.folderName,
      numericCollisionSuffix: true,
    );
  }

  Future<void> notifyWritten(String absolutePath) => _afterWrite(absolutePath);

  Future<void> _afterWrite(String absolutePath) async {
    if (await shouldScanIntoMediaStore(absolutePath)) {
      await _scanner.scanPath(absolutePath);
      _mediaLibrary?.invalidateCache();
    }
  }
}
