import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../app/di/service_locator.dart';
import '../../../core/file_provider/file_entry.dart';
import '../../../core/protocol/nas_api_paths.dart';
import '../../../core/storage/media_library_service.dart';
import '../../../core/storage/nas_peer_preview_cache.dart';
import '../../../core/storage/share_receive_paths.dart';
import '../presentation/cubit/gallery_original_download_state.dart';

/// 查看原图：本机路径 / MediaStore 物化 / 对端 content 下载到**缓存**。
class ViewOriginalUseCase {
  const ViewOriginalUseCase();

  Future<File> cacheFileFor(FileEntry entry) async {
    final dir = await getTemporaryDirectory();
    final cacheDir = Directory(p.join(dir.path, 'wenjian_original_previews'));
    await cacheDir.create(recursive: true);
    final safe = '${entry.rootId}_${entry.relativePath}'
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return File(p.join(cacheDir.path, safe));
  }

  /// 返回更新后的原图态；失败时 [GalleryOriginalDownloadState.hasFailure]。
  Future<GalleryOriginalDownloadState> call({
    required FileEntry entry,
    required bool isSelf,
    String? peerFingerprint,
    String? knownLocalPath,
    void Function(double progress)? onProgress,
  }) async {
    if (isSelf) {
      final path = knownLocalPath ?? entry.absolutePath;
      if (path != null && path.isNotEmpty && await File(path).exists()) {
        return GalleryOriginalDownloadState(localPath: path);
      }
      if (entry.rootId == MediaLibraryService.rootId ||
          (entry.contentUri != null && entry.contentUri!.isNotEmpty)) {
        final lib = serviceLocator.mediaLibraryService();
        final asset = await lib.findByRelativePath(entry.relativePath);
        if (asset == null) {
          return const GalleryOriginalDownloadState(errorMessage: '原图不可用');
        }
        if (asset.absolutePath != null &&
            asset.absolutePath!.isNotEmpty &&
            await File(asset.absolutePath!).exists()) {
          return GalleryOriginalDownloadState(localPath: asset.absolutePath);
        }
        final dest = await cacheFileFor(entry);
        final bytes = await lib.readBytes(asset);
        if (bytes == null || bytes.isEmpty) {
          return const GalleryOriginalDownloadState(errorMessage: '原图读取失败');
        }
        await dest.writeAsBytes(bytes, flush: true);
        return GalleryOriginalDownloadState(localPath: dest.path);
      }
      return const GalleryOriginalDownloadState(errorMessage: '原图不可用');
    }

    final fp = peerFingerprint;
    if (fp == null || fp.isEmpty) {
      return const GalleryOriginalDownloadState(errorMessage: '原图不可用');
    }
    final dest = await cacheFileFor(entry);
    if (await dest.exists() && await dest.length() > 0) {
      await NasPeerPreviewCache.instance.track(
        peerFingerprint: fp,
        absolutePath: dest.path,
      );
      return GalleryOriginalDownloadState(localPath: dest.path);
    }
    try {
      final n = await serviceLocator.peerApiClient().downloadToFile(
            fp,
            NasApiPaths.filesContent,
            destFile: dest,
            query: {
              'rootId': entry.rootId,
              'path': entry.relativePath,
            },
            onBytes: (c) {
              final total = entry.sizeBytes;
              if (total <= 0) return;
              onProgress?.call((c / total).clamp(0.0, 1.0));
            },
          );
      if (n == null || n <= 0) {
        return const GalleryOriginalDownloadState(errorMessage: '原图下载失败');
      }
    } catch (_) {
      try {
        if (await dest.exists()) await dest.delete();
      } catch (_) {}
      return const GalleryOriginalDownloadState(errorMessage: '原图下载失败');
    }
    await NasPeerPreviewCache.instance.track(
      peerFingerprint: fp,
      absolutePath: dest.path,
    );
    return GalleryOriginalDownloadState(localPath: dest.path);
  }
}

/// 将已就绪原图正式保存到共享根四分类（非系统 Pictures）。
class SaveOriginalUseCase {
  SaveOriginalUseCase();

  Future<GalleryOriginalDownloadState> call({
    required GalleryOriginalDownloadState current,
    required String displayName,
  }) async {
    final path = current.localPath;
    if (path == null || path.isEmpty) {
      return current.copyWith(errorMessage: '原图不可用');
    }
    final src = File(path);
    if (!await src.exists()) {
      return current.copyWith(errorMessage: '原图不可用');
    }
    String? destPath;
    try {
      final name = p.basename(displayName).trim().isEmpty
          ? p.basename(path)
          : p.basename(displayName);
      final root =
          await serviceLocator.storageRootStore().ensureCurrent();
      final opened = await serviceLocator.shareWriter().openWriteSink(
            preferredFileName: name,
            expectedLength: await src.length(),
            relativeDir: ShareReceivePaths.relativeDirForReceive(
              root: root,
              fileName: name,
            ),
          );
      await opened.sink.close();
      destPath = opened.result.absolutePath;
      final dest = File(destPath);
      await src.copy(dest.path);
      if (await dest.length() <= 0) {
        throw StateError('empty save');
      }
      return current.copyWith(
        isSaving: false,
        publicUri: dest.path,
        errorMessage: null,
      );
    } catch (_) {
      try {
        if (destPath != null) {
          final f = File(destPath);
          if (await f.exists()) await f.delete();
        }
      } catch (_) {}
      return current.copyWith(
        isSaving: false,
        errorMessage: '保存失败',
      );
    }
  }
}
