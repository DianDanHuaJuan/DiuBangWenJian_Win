import 'dart:io';

import 'package:path/path.dart' as p;

import 'media_library_service.dart';
import 'share_receive_paths.dart';
import 'share_writer.dart';
import 'storage_path_policy.dart';
import 'storage_root_store.dart';

/// 对端正式写入编目：落当前共享根（默认根四分类 / 换根后顶层 / 有 dir 则当前目录）。
///
/// 归属 core/storage（doc/01 §五 E3）：devices 互传与 nas 上传共用。
/// 历史 `inbox/<fingerprint>/` 不再作为新写入目标。
class InboxCatalogService {
  InboxCatalogService({
    required this.rootStore,
    required this.shareWriter,
    MediaLibraryService? mediaLibrary,
  }) : _mediaLibrary = mediaLibrary;

  final StorageRootStore rootStore;
  final ShareWriter shareWriter;
  final MediaLibraryService? _mediaLibrary;

  Future<ShareWriteResult> receiveFile({
    required String preferredFileName,
    required List<int> bytes,
    String? mimeType,
    String directory = '',
  }) async {
    final name = p.basename(preferredFileName);
    final root = await rootStore.ensureCurrent();
    if (root.revoked || !root.isPath) {
      throw StateError('share root unavailable');
    }
    final written = await shareWriter.writeBytes(
      preferredFileName: name,
      bytes: bytes,
      relativeDir: ShareReceivePaths.relativeDirForReceive(
        root: root,
        directory: directory,
        mimeType: mimeType,
        fileName: name,
      ),
    );
    await _afterWrite(written.absolutePath);
    return written;
  }

  /// 大文件流式落盘；调用方负责写入并 close sink，完成后应调用 [notifyWritten]。
  Future<({IOSink sink, ShareWriteResult result})> openReceiveSink({
    required String preferredFileName,
    int? expectedLength,
    String? mimeType,
    String directory = '',
  }) async {
    final name = p.basename(preferredFileName);
    final root = await rootStore.ensureCurrent();
    if (root.revoked || !root.isPath) {
      throw StateError('share root unavailable');
    }
    return shareWriter.openWriteSink(
      preferredFileName: name,
      expectedLength: expectedLength,
      relativeDir: ShareReceivePaths.relativeDirForReceive(
        root: root,
        directory: directory,
        mimeType: mimeType,
        fileName: name,
      ),
    );
  }

  Future<void> notifyWritten(String absolutePath) => _afterWrite(absolutePath);

  Future<void> _afterWrite(String absolutePath) async {
    if (await shouldScanIntoMediaStore(absolutePath)) {
      _mediaLibrary?.invalidateCache();
    }
  }
}
