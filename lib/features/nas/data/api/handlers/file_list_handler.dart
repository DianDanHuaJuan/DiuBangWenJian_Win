import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

import '../../../../../core/auth/peer_fingerprint_middleware.dart';
import '../../../../../core/common/app_logger.dart';
import '../../../../../core/identity/peer.dart';
import '../../../../../core/protocol/nas_api_paths.dart';
import '../../../../../core/storage/external_volume_browser.dart';
import '../../../../../core/storage/file_chunk_stream.dart';
import '../../../../../core/storage/media_library_service.dart';
import '../../../../../core/storage/mime_types.dart';
import '../../../../../core/storage/share_reader.dart';
import '../../../../../core/storage/storage_access_diagnostics.dart';
import '../../nas_share_scope.dart';
import '../../share_path_resolver.dart';

/// GET /api/v1/storage/volumes —— 非主卷（OTG/SD）列表。
class StorageVolumesHandler {
  static const path = NasApiPaths.storageVolumes;

  StorageVolumesHandler({ExternalVolumeBrowser? browser, this.shareScope})
      : _browser = browser ?? ExternalVolumeBrowser();

  final ExternalVolumeBrowser _browser;
  final NasShareScope? shareScope;

  Handler get handler => (Request request) async {
        final peer = request.context[peerKey] as Peer?;
        if (peer == null) {
          return Response.unauthorized('peer required');
        }
        try {
          if (shareScope?.isCustom == true) {
            return Response.ok(
              jsonEncode({'count': 0, 'items': <Map<String, dynamic>>[]}),
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          final vols = await _browser.listExternalVolumes();
          AppLogger.log(
            'storage/volumes ok',
            scope: 'nas_files',
            details: {
              'count': vols.length,
              'paths': [for (final v in vols) v.path],
            },
          );
          return Response.ok(
            jsonEncode({
              'count': vols.length,
              'items': [
                for (final v in vols)
                  {
                    'path': v.path,
                    'description': v.description,
                    'isPrimary': v.isPrimary,
                    'isRemovable': v.isRemovable,
                    'writable': v.writable,
                    'state': v.state,
                  },
              ],
            }),
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        } catch (e, st) {
          AppLogger.log(
            'storage/volumes failed',
            scope: 'nas_files',
            error: e,
            stackTrace: st,
          );
          await StorageAccessDiagnostics.logSnapshot('volumes_handler_500');
          return Response.internalServerError(
            body: 'list volumes failed: $e',
            headers: {'content-type': 'text/plain; charset=utf-8'},
          );
        }
      };
}

/// GET /api/v1/files?rootId=&path=
///
/// - `rootId` 空或 `library`：MediaStore 媒体（path 可选 image|video|audio）
/// - `rootId=fs`：当前共享根目录树
/// - `rootId=extvol:…`：外置卷文件夹浏览
class FileListHandler {
  static const path = NasApiPaths.files;

  FileListHandler({
    required this.shareReader,
    required this.resolver,
    required this.mediaLibrary,
    this.shareScope,
    ExternalVolumeBrowser? externalBrowser,
  }) : externalBrowser = externalBrowser ?? ExternalVolumeBrowser();

  final ShareReader shareReader;
  final SharePathResolver resolver;
  final MediaLibraryService mediaLibrary;
  final NasShareScope? shareScope;
  final ExternalVolumeBrowser externalBrowser;

  Handler get handler => (Request request) async {
        final peer = request.context[peerKey] as Peer?;
        if (peer == null) {
          return Response.unauthorized('peer required');
        }

        var rootId = request.url.queryParameters['rootId'] ?? '';
        final relPath = (request.url.queryParameters['path'] ?? '')
            .replaceAll('\\', '/');
        AppLogger.log(
          'GET /files',
          scope: 'nas_files',
          details: {
            'rootId': rootId,
            'path': relPath,
            'peer': peer.fingerprint.length > 12
                ? '${peer.fingerprint.substring(0, 12)}…'
                : peer.fingerprint,
          },
        );
        try {
          if (relPath.isNotEmpty &&
              rootId != MediaLibraryService.rootId &&
              rootId.isNotEmpty &&
              rootId != 'library' &&
              !rootId.startsWith(ExternalVolumeBrowser.rootIdPrefix) &&
              SharePathResolver.isUnsafeName(relPath)) {
            return Response.forbidden('invalid path');
          }

          final offset =
              int.tryParse(request.url.queryParameters['offset'] ?? '') ?? 0;
          final limit =
              int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 0;

          // 默认对外媒体墙；文件树请显式 rootId=fs。
          if (rootId.isEmpty || rootId == MediaLibraryService.rootId) {
            return _libraryResponse(relPath, offset: offset, limit: limit);
          }

          if (rootId.startsWith(ExternalVolumeBrowser.rootIdPrefix)) {
            return _externalResponse(rootId, relPath);
          }

          if (shareScope?.isCustom == true) {
            return _scopeResponse(relPath);
          }

          if (rootId == 'fs') {
            final current = await resolver.currentRoot();
            rootId = current.id;
          }

          final entries = await shareReader.listDirectory(
            rootId: rootId,
            relativePath: relPath,
          );
          AppLogger.log(
            'files fs/share list ok',
            scope: 'nas_files',
            details: {
              'rootId': rootId,
              'path': relPath,
              'count': entries.length,
            },
          );
          return Response.ok(
            jsonEncode({
              'rootId': rootId,
              'path': relPath,
              'count': entries.length,
              'items': [
                for (final e in entries)
                  {
                    'name': e.fileName,
                    'relativePath': e.relativePath,
                    'isDirectory': e.isDirectory,
                    'sizeBytes': e.sizeBytes,
                    'modifiedAtMs': e.modifiedAtMs,
                    'rootId': e.rootId,
                    'rootDisplayName': e.rootDisplayName,
                  },
              ],
            }),
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        } catch (e, st) {
          AppLogger.log(
            'files list 500',
            scope: 'nas_files',
            error: e,
            stackTrace: st,
            details: {'rootId': rootId, 'path': relPath},
          );
          await StorageAccessDiagnostics.logSnapshot(
            'files_list_500:$rootId',
          );
          return Response.internalServerError(
            body: 'file list failed: $e',
            headers: {'content-type': 'text/plain; charset=utf-8'},
          );
        }
      };

  Future<Response> _externalResponse(String rootId, String relPath) async {
    final volPath = externalBrowser.volumePathFromRootId(rootId);
    if (volPath == null || volPath.isEmpty) {
      AppLogger.log(
        'extvol bad rootId',
        scope: 'nas_files',
        details: {'rootId': rootId},
      );
      return Response.badRequest(body: 'invalid external rootId');
    }
    final mounted = await externalBrowser.isVolumeMounted(volPath);
    if (!mounted) {
      AppLogger.log(
        'extvol not mounted',
        scope: 'nas_files',
        details: {'volPath': volPath},
      );
      await StorageAccessDiagnostics.logSnapshot('extvol_not_mounted');
      return Response.notFound('external volume not mounted');
    }
    if (relPath.isNotEmpty &&
        (relPath.contains('..') || relPath.startsWith('/'))) {
      return Response.forbidden('invalid path');
    }
    final vols = await externalBrowser.listExternalVolumes();
    var label = '外置存储';
    for (final v in vols) {
      if (v.path == volPath && v.description.isNotEmpty) {
        label = v.description;
        break;
      }
    }
    try {
      var entries = await externalBrowser.listDirectory(
        volumePath: volPath,
        volumeLabel: label.isEmpty ? '外置存储' : label,
        relativePath: relPath,
      );
      if (shareScope?.isCustom == true) {
        entries = [
          for (final e in entries)
            if (e.absolutePath != null &&
                e.absolutePath!.isNotEmpty &&
                shareScope!.allows(e.absolutePath!))
              e,
        ];
      }
      AppLogger.log(
        'extvol list ok',
        scope: 'nas_files',
        details: {
          'volPath': volPath,
          'path': relPath,
          'count': entries.length,
          'label': label,
        },
      );
      return Response.ok(
        jsonEncode({
          'rootId': rootId,
          'path': relPath,
          'count': entries.length,
          'items': [
            for (final e in entries)
              {
                'name': e.name,
                'relativePath': e.relativePath,
                'isDirectory': e.isDirectory,
                'sizeBytes': e.sizeBytes,
                'modifiedAtMs': e.modifiedAtMs,
                'rootId': e.rootId,
                'rootDisplayName': e.rootDisplayName,
              },
          ],
        }),
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    } catch (e, st) {
      AppLogger.log(
        'extvol list failed',
        scope: 'nas_files',
        error: e,
        stackTrace: st,
        details: {'volPath': volPath, 'path': relPath},
      );
      await StorageAccessDiagnostics.logSnapshot('extvol_list_failed');
      rethrow;
    }
  }

  bool _inShareScope(MediaLibraryAsset asset) {
    final path = asset.absolutePath;
    if (path == null || path.isEmpty) return false;
    return shareScope!.allows(path);
  }

  Future<Response> _scopeResponse(String relPath) async {
    final nodes = await shareScope!.list(relPath);
    return Response.ok(
      jsonEncode({
        'rootId': 'fs',
        'path': relPath,
        'count': nodes.length,
        'items': [
          for (final e in nodes)
            {
              'name': e.name,
              'relativePath': e.relativePath,
              'isDirectory': e.isDirectory,
              'sizeBytes': e.sizeBytes,
              'modifiedAtMs': e.modifiedAtMs,
              'rootId': 'fs',
              'rootDisplayName': '共享范围',
            },
        ],
      }),
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }

  Future<Response> _libraryResponse(
    String pathFilter, {
    int offset = 0,
    int limit = 0,
  }) async {
    try {
      // limit<=0：兼容旧客户端全量；否则分页（默认页 120）。
      final pageLimit = limit <= 0 ? 0 : limit.clamp(1, 500);
      final MediaLibraryPage page;
      if (shareScope?.isCustom == true) {
        final assets = await mediaLibrary
            .listFiltered(path: pathFilter)
            .timeout(const Duration(seconds: 45));
        final kept = [
          for (final asset in assets)
            if (_inShareScope(asset)) asset,
        ];
        final start = offset < 0 ? 0 : offset;
        final size = pageLimit == 0 ? kept.length : pageLimit;
        final slice = kept.skip(start).take(size).toList();
        page = MediaLibraryPage(
          items: slice,
          total: kept.length,
          offset: start,
          limit: size,
          hasMore: start + slice.length < kept.length,
        );
      } else if (pageLimit == 0) {
        final assets = await mediaLibrary
            .listFiltered(path: pathFilter)
            .timeout(const Duration(seconds: 45));
        page = MediaLibraryPage(
          items: assets,
          total: assets.length,
          offset: 0,
          limit: assets.length,
          hasMore: false,
        );
      } else {
        page = await mediaLibrary
            .listPage(
              path: pathFilter,
              offset: offset < 0 ? 0 : offset,
              limit: pageLimit,
            )
            .timeout(const Duration(seconds: 45));
      }
      return Response.ok(
        jsonEncode({
          'rootId': MediaLibraryService.rootId,
          'path': pathFilter,
          'count': page.items.length,
          'total': page.total,
          'offset': page.offset,
          'limit': page.limit,
          'hasMore': page.hasMore,
          'items': [
            for (final a in page.items)
              {
                'name': a.displayName.isEmpty ? a.id : a.displayName,
                'relativePath': a.relativePath,
                'isDirectory': false,
                'sizeBytes': a.sizeBytes,
                'modifiedAtMs': a.modifiedAtMs,
                'rootId': MediaLibraryService.rootId,
                'rootDisplayName': MediaLibraryService.rootDisplayName,
                'contentUri': a.contentUri,
                'mediaKind': a.mediaKind,
              },
          ],
        }),
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    } catch (e) {
      // 相册查询失败时仍返回 200 空列表，避免对端误判「NAS 未开」。
      return Response.ok(
        jsonEncode({
          'rootId': MediaLibraryService.rootId,
          'path': pathFilter,
          'count': 0,
          'total': 0,
          'offset': 0,
          'limit': 0,
          'hasMore': false,
          'items': <Map<String, dynamic>>[],
          'warning': '$e',
        }),
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
  }
}

/// GET /api/v1/files/content?rootId=&path=  （兼容 name=；支持 Range）
class FileContentHandler {
  static const path = NasApiPaths.filesContent;

  FileContentHandler({
    required this.resolver,
    required this.mediaLibrary,
    this.shareScope,
    ExternalVolumeBrowser? externalBrowser,
  }) : externalBrowser = externalBrowser ?? ExternalVolumeBrowser();

  final SharePathResolver resolver;
  final MediaLibraryService mediaLibrary;
  final NasShareScope? shareScope;
  final ExternalVolumeBrowser externalBrowser;

  Handler get handler => (Request request) async {
        final peer = request.context[peerKey] as Peer?;
        if (peer == null) {
          return Response.unauthorized('peer required');
        }
        var rootId = request.url.queryParameters['rootId'] ?? '';
        final rel = (request.url.queryParameters['path'] ??
                request.url.queryParameters['name'] ??
                '')
            .replaceAll('\\', '/');
        if (rootId.isEmpty || rel.isEmpty) {
          return Response.badRequest(body: 'rootId and path required');
        }
        if (rootId == MediaLibraryService.rootId) {
          return _libraryContent(request, rel);
        }
        if (rootId.startsWith(ExternalVolumeBrowser.rootIdPrefix)) {
          final volPath = externalBrowser.volumePathFromRootId(rootId);
          if (volPath == null) {
            return Response.badRequest(body: 'invalid external rootId');
          }
          try {
            final file = await externalBrowser.resolveFile(
              volumePath: volPath,
              relativePath: rel,
            );
            if (file == null) {
              AppLogger.log(
                'extvol content not found',
                scope: 'nas_files',
                details: {'volPath': volPath, 'path': rel},
              );
              return Response.notFound('file not found');
            }
            if (shareScope?.isCustom == true && !shareScope!.allows(file.path)) {
              return Response.notFound('file not found');
            }
            final length = await file.length();
            final name = p.basename(file.path);
            return fileRangeResponse(
              request: request,
              file: file,
              length: length,
              fileName: name,
              mimeType: MimeTypes.fromFileNameOrOctet(name),
            );
          } catch (e, st) {
            AppLogger.log(
              'extvol content failed',
              scope: 'nas_files',
              error: e,
              stackTrace: st,
              details: {'volPath': volPath, 'path': rel},
            );
            await StorageAccessDiagnostics.logSnapshot('extvol_content_failed');
            rethrow;
          }
        }
        if (shareScope?.isCustom == true) {
          final file = shareScope!.resolveFile(rel);
          if (file == null ||
              !await file.exists() ||
              !shareScope!.allows(file.path)) {
            return Response.notFound('file not found');
          }
          final length = await file.length();
          final name = p.basename(file.path);
          return fileRangeResponse(
            request: request,
            file: file,
            length: length,
            fileName: name,
            mimeType: MimeTypes.fromFileNameOrOctet(name),
          );
        }
        if (SharePathResolver.isUnsafeName(rel)) {
          return Response.forbidden('invalid path');
        }
        if (rootId == 'fs') {
          rootId = (await resolver.currentRoot()).id;
        }

        final file =
            await resolver.resolveFile(rootId: rootId, relativePath: rel);
        if (file == null || !await file.exists()) {
          return Response.notFound('file not found');
        }

        final length = await file.length();
        final name = p.basename(file.path);
        return fileRangeResponse(
          request: request,
          file: file,
          length: length,
          fileName: name,
          mimeType: MimeTypes.fromFileNameOrOctet(name),
        );
      };

  bool _inShareScope(MediaLibraryAsset asset) {
    final path = asset.absolutePath;
    if (path == null || path.isEmpty) return false;
    return shareScope!.allows(path);
  }

  Future<Response> _libraryContent(Request request, String rel) async {
    final asset = await mediaLibrary.findByRelativePath(rel);
    if (asset == null) return Response.notFound('file not found');
    if (shareScope?.isCustom == true && !_inShareScope(asset)) {
      return Response.notFound('file not found');
    }
    final path = asset.absolutePath;
    if (path != null && path.isNotEmpty) {
      final file = File(path);
      if (await file.exists()) {
        final length = await file.length();
        return fileRangeResponse(
          request: request,
          file: file,
          length: length,
          fileName: asset.displayName.isEmpty ? asset.id : asset.displayName,
          mimeType: asset.mimeType.isEmpty
              ? 'application/octet-stream'
              : asset.mimeType,
        );
      }
    }
    final bytes = await mediaLibrary.readBytes(asset);
    if (bytes == null) return Response.notFound('file not found');
    return Response.ok(
      bytes,
      headers: {
        'content-type':
            asset.mimeType.isEmpty ? 'application/octet-stream' : asset.mimeType,
        'content-length': '${bytes.length}',
        'accept-ranges': 'bytes',
        'content-disposition': 'attachment; filename="${asset.displayName}"',
      },
    );
  }
}

Response fileRangeResponse({
  required Request request,
  required File file,
  required int length,
  required String fileName,
  required String mimeType,
}) {
  final disposition = 'inline; filename="$fileName"';
  final rangeHeader = request.headers['range'];
  if (rangeHeader == null || !rangeHeader.startsWith('bytes=')) {
    return Response.ok(
      openFileChunked(file, chunkSize: kNasFileReadChunkBytes),
      headers: {
        'content-type': mimeType,
        'content-length': '$length',
        'accept-ranges': 'bytes',
        'content-disposition': disposition,
      },
    );
  }
  final spec = rangeHeader.substring(6);
  final dash = spec.indexOf('-');
  if (dash < 0) {
    return Response(416, headers: {'content-range': 'bytes */$length'});
  }
  final startStr = spec.substring(0, dash);
  final endStr = spec.substring(dash + 1);
  var start = int.tryParse(startStr) ?? 0;
  var end = endStr.isEmpty ? length - 1 : (int.tryParse(endStr) ?? length - 1);
  if (start < 0) start = 0;
  if (end >= length) end = length - 1;
  if (start > end || start >= length) {
    return Response(416, headers: {'content-range': 'bytes */$length'});
  }
  final chunkLen = end - start + 1;
  return Response(
    206,
    body: openFileChunked(
      file,
      start: start,
      endExclusive: end + 1,
      chunkSize: kNasFileReadChunkBytes,
    ),
    headers: {
      'content-type': mimeType,
      'content-length': '$chunkLen',
      'content-range': 'bytes $start-$end/$length',
      'accept-ranges': 'bytes',
      'content-disposition': disposition,
    },
  );
}
