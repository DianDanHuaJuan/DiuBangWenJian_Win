import 'dart:io';

import 'package:path/path.dart' as p;

import 'media_library_service.dart';
import 'media_scanner.dart';
import 'share_receive_paths.dart';
import 'share_writer.dart';
import 'storage_path_policy.dart';
import 'storage_root_store.dart';

/// 对端正式写入编目：落当前共享根下四分类，并触发 MediaStore 扫描。
///
/// 归属 core/storage（doc/01 §五 E3）：devices 互传与 nas 上传共用。
/// 历史 `inbox/<fingerprint>/` 不再作为新写入目标。
class InboxCatalogService {
  InboxCatalogService({
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
    for (final dirName in const ['图片', '视频', '文档', '其他']) {
      await Directory(p.join(root.uriOrPath, dirName)).create(recursive: true);
    }
  }

  Future<ShareWriteResult> receiveFile({
    required String preferredFileName,
    required List<int> bytes,
    String? mimeType,
  }) async {
    await ensureCategoryFolders();
    final name = p.basename(preferredFileName);
    final written = await shareWriter.writeBytes(
      preferredFileName: name,
      bytes: bytes,
      relativeDir: ShareReceivePaths.relativeDirFor(
        mimeType: mimeType,
        fileName: name,
      ),
    );
    await _afterWrite(written.absolutePath);
    return written;
  }

  /// 大文件流式落盘到四分类；调用方负责写入并 close sink，完成后应调用 [notifyWritten]。
  Future<({IOSink sink, ShareWriteResult result})> openReceiveSink({
    required String preferredFileName,
    int? expectedLength,
    String? mimeType,
  }) async {
    await ensureCategoryFolders();
    final name = p.basename(preferredFileName);
    return shareWriter.openWriteSink(
      preferredFileName: name,
      expectedLength: expectedLength,
      relativeDir: ShareReceivePaths.relativeDirFor(
        mimeType: mimeType,
        fileName: name,
      ),
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
