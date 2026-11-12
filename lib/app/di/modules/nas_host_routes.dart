import 'dart:io';

import '../../../core/host/http_host_service.dart';
import '../../../core/storage/backup_receive_service.dart';
import '../../../core/storage/external_volume_browser.dart';
import '../../../core/storage/inbox_catalog_service.dart';
import '../../../core/storage/local_system_stats.dart';
import '../../../core/storage/media_library_service.dart';
import '../../../core/storage/share_reader.dart';
import '../../../core/storage/storage_constants.dart';
import '../../../features/nas/data/api/handlers/backup_handlers.dart';
import '../../../features/nas/data/api/handlers/dashboard_handlers.dart';
import '../../../features/nas/data/api/handlers/file_list_handler.dart';
import '../../../features/nas/data/api/handlers/media_and_mgmt_handlers.dart';
import '../../../features/nas/data/api/services/thumbnail_service.dart';
import '../../../features/nas/data/api/services/video_hls_session_service.dart';
import '../../../features/nas/data/nas_share_scope.dart';
import '../../../features/nas/data/share_path_resolver.dart';
import '../../../features/nas/data/webdav/handlers/propfind_handler.dart';

/// NAS 域路由装配（doc/01 §七 期 D · registerNas）。
///
/// 从 [ServiceLocator] 抽出，便于按域浏览；开关关时仍由 nas_route_guard 返回 503。
void mountNasHostRoutes({
  required Router router,
  required ShareReader shareReader,
  required SharePathResolver sharePathResolver,
  required ThumbnailService thumbnailService,
  required MediaLibraryService mediaLibrary,
  required InboxCatalogService inboxCatalog,
  required BackupReceiveService backupReceive,
  required NasShareScope shareScope,
}) {
  final externalBrowser = ExternalVolumeBrowser();
  final hls = VideoHlsSessionService(
    resolver: ({required String rootId, required String relativePath}) async {
      if (shareScope.isCustom) {
        final file = shareScope.resolveFile(relativePath);
        if (file == null || !shareScope.allows(file.path)) return null;
        return file;
      }
      if (rootId == MediaLibraryService.rootId) {
        final asset = await mediaLibrary.findByRelativePath(relativePath);
        final abs = asset?.absolutePath?.trim();
        if (abs == null || abs.isEmpty) return null;
        final file = File(abs);
        return await file.exists() ? file : null;
      }
      if (rootId.startsWith(ExternalVolumeBrowser.rootIdPrefix)) {
        final vol = externalBrowser.volumePathFromRootId(rootId);
        if (vol == null) return null;
        return externalBrowser.resolveFile(
          volumePath: vol,
          relativePath: relativePath,
        );
      }
      return sharePathResolver.resolveFile(
        rootId: rootId,
        relativePath: relativePath,
      );
    },
    ffmpeg: FfmpegLocator(),
  );

  Future<({String fileName, String rootId})> receivePeerFile({
    required String preferredFileName,
    required List<int> bytes,
    required String peerFingerprint,
  }) async {
    final r = await inboxCatalog.receiveFile(
      preferredFileName: preferredFileName,
      bytes: bytes,
    );
    return (fileName: r.fileName, rootId: r.rootId);
  }

  router.get(
    StorageVolumesHandler.path,
    StorageVolumesHandler(shareScope: shareScope).handler,
  );
  router.get(
    FileListHandler.path,
    FileListHandler(
      shareReader: shareReader,
      resolver: sharePathResolver,
      mediaLibrary: mediaLibrary,
      shareScope: shareScope,
    ).handler,
  );
  router.get(
    FileContentHandler.path,
    FileContentHandler(
      resolver: sharePathResolver,
      mediaLibrary: mediaLibrary,
      shareScope: shareScope,
    ).handler,
  );
  router.put(
    FileUploadHandler.path,
    FileUploadHandler(
      openReceiveSink: ({
        required String preferredFileName,
        int? expectedLength,
      }) =>
          inboxCatalog.openReceiveSink(
            preferredFileName: preferredFileName,
            expectedLength: expectedLength,
          ),
      notifyWritten: inboxCatalog.notifyWritten,
    ).handler,
  );
  router.get(
    ThumbnailHandler.path,
    ThumbnailHandler(
      resolver: sharePathResolver,
      thumbnails: thumbnailService,
      mediaLibrary: mediaLibrary,
      shareScope: shareScope,
    ).handler,
  );
  router.post(
    BatchDeleteHandler.path,
    BatchDeleteHandler(
      shareReader: shareReader,
      mediaLibrary: mediaLibrary,
      shareScope: shareScope,
    ).handler,
  );
  router.post(
    BackupPreflightHandler.path,
    BackupPreflightHandler(
      freeBytesForCurrentRoot: () async {
        final stats = await LocalSystemStatsSource().read();
        return stats.storageAvailBytes > 0 ? stats.storageAvailBytes : null;
      },
      reserveBytes: StorageConstants.reserveBytes,
    ).handler,
  );
  router.post(
    BackupExistsHandler.path,
    BackupExistsHandler(receive: backupReceive).handler,
  );
  router.put(
    BackupUploadHandler.path,
    BackupUploadHandler(receive: backupReceive).handler,
  );
  router.get(
    PreviewHlsHandler.path,
    PreviewHlsHandler(sessionService: hls).handler,
  );

  router.add(
    'PROPFIND',
    davRootPath,
    PropfindHandler(shareReader: shareReader, shareScope: shareScope).handler,
  );
  router.get(
    davRootPath,
    DavGetHandler(resolver: sharePathResolver, shareScope: shareScope).handler,
    prefix: true,
  );
  router.add(
    'HEAD',
    davRootPath,
    DavGetHandler(resolver: sharePathResolver, shareScope: shareScope).handler,
    prefix: true,
  );
  router.put(
    davRootPath,
    DavPutHandler(receiveFile: receivePeerFile).handler,
    prefix: true,
  );
  router.add(
    'DELETE',
    davRootPath,
    DavDeleteHandler(resolver: sharePathResolver, shareScope: shareScope).handler,
    prefix: true,
  );
  router.add(
    'MKCOL',
    davRootPath,
    DavMkcolHandler(resolver: sharePathResolver).handler,
    prefix: true,
  );

}
