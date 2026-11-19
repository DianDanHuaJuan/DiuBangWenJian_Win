import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

import '../../../../../core/auth/peer_fingerprint_middleware.dart';
import '../../../../../core/common/app_logger.dart';
import '../../../../../core/http/content_disposition.dart';
import '../../../../../core/identity/peer.dart';
import '../../../../../core/protocol/nas_api_paths.dart';
import '../../../../../core/storage/app_paths.dart';
import '../../../../../core/storage/external_volume_browser.dart';
import '../../../../../core/storage/file_chunk_stream.dart';
import '../../../../../core/storage/media_library_service.dart';
import '../../../../../core/storage/mime_types.dart';
import '../../../../../core/storage/share_reader.dart';
import '../../../../../core/storage/storage_access_diagnostics.dart';
import '../../nas_share_scope.dart';
import '../../share_path_resolver.dart';

/// GET /api/v1/storage/volumes 鈥斺€?鍙祻瑙堝嵎鍒楄〃锛堝惈鍏ㄩ儴鐩樼锛夈€?
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
            AppLogger.logVerbose(
              'storage/volumes skipped (custom shareScope)',
              scope: 'extvol_diag',
              details: {
                'peer': peer.fingerprint.length > 12
                    ? '${peer.fingerprint.substring(0, 12)}…'
                    : peer.fingerprint,
              },
            );
            return Response.ok(
              jsonEncode({'count': 0, 'items': <Map<String, dynamic>>[]}),
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          // 鍚叏閮ㄧ洏绗︼細瀵圭鐩綍鏍戙€屾牴鐩綍銆嶉渶杩涘叆纾佺洏鍒楄〃/鍗锋牴銆?
          final vols = await _browser.listBrowsableVolumes();
          final items = [
            for (final v in vols)
              {
                // 缁欏鎴风鐜版垚 rootId锛岄伩鍏嶆墜鏈虹鑷鎷兼帴鐩樼韪╁潙銆?
                'rootId': _browser.rootIdFor(v.path),
                'path': AppPaths.portable(v.path),
                'description': v.description,
                'isPrimary': v.isPrimary,
                'isRemovable': v.isRemovable,
                'writable': v.writable,
                'state': v.state,
                // 鎻愮ず锛氳繖鏄鐩樺嵎锛屼笉鏄櫘閫氭枃浠跺す锛堟棫瀹㈡埛绔彲蹇界暐锛夈€?
                'kind': 'volume',
                'entryKind': 'disk',
              },
          ];
          AppLogger.logVerbose(
            'storage/volumes ok',
            scope: 'extvol_diag',
            details: {
              'count': vols.length,
              'peer': peer.fingerprint.length > 12
                  ? '${peer.fingerprint.substring(0, 12)}…'
                  : peer.fingerprint,
              'items': items,
            },
          );
          return Response.ok(
            jsonEncode({
              'count': vols.length,
              'items': items,
            }),
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        } catch (e, st) {
          AppLogger.log(
            'storage/volumes failed',
            scope: 'extvol_diag',
            error: e,
            stackTrace: st,
          );
          if (AppLogger.verboseExtvol) {
            await StorageAccessDiagnostics.logSnapshot('volumes_handler_500');
          }
          return Response.internalServerError(
            body: 'list volumes failed: $e',
            headers: {'content-type': 'text/plain; charset=utf-8'},
          );
        }
      };
}

/// GET /api/v1/files?rootId=&path=
///
/// - `rootId` 绌烘垨 `library`锛歁ediaStore 濯掍綋锛坧ath 鍙€?image|video|audio锛?
/// - `rootId=fs`锛氬綋鍓嶅叡浜牴鐩綍鏍?
/// - `rootId=extvol:鈥锛氬缃嵎鏂囦欢澶规祻瑙?
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
        final relPath =
            AppPaths.portable(request.url.queryParameters['path'] ?? '');
        final isExtvol =
            rootId.startsWith(ExternalVolumeBrowser.rootIdPrefix);
        AppLogger.logVerbose(
          'GET /files',
          scope: isExtvol ? 'extvol_diag' : 'nas_files',
          details: {
            'rootId': rootId,
            'path': relPath,
            'isExtvol': isExtvol,
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

          // 榛樿瀵瑰濯掍綋澧欙紱鏂囦欢鏍戣鏄惧紡 rootId=fs銆?
          if (rootId.isEmpty || rootId == MediaLibraryService.rootId) {
            return _libraryResponse(relPath, offset: offset, limit: limit);
          }

          if (isExtvol) {
            return _externalResponse(rootId, relPath);
          }

          if (shareScope?.isCustom == true) {
            return _scopeResponse(relPath);
          }

          String? rootAbsolutePath;
          if (rootId == 'fs') {
            final current = await resolver.currentRoot();
            rootId = current.id;
            rootAbsolutePath = AppPaths.portable(current.uriOrPath);
          } else {
            try {
              final current = await resolver.currentRoot();
              if (current.id == rootId) {
                rootAbsolutePath = AppPaths.portable(current.uriOrPath);
              }
            } catch (_) {}
          }

          final entries = await shareReader.listDirectory(
            rootId: rootId,
            relativePath: relPath,
          );
          AppLogger.logVerbose(
            'files fs/share list ok',
            scope: 'nas_files',
            details: {
              'rootId': rootId,
              'path': relPath,
              'count': entries.length,
              'rootAbsolutePath': rootAbsolutePath ?? '',
            },
          );
          return Response.ok(
            jsonEncode({
              'rootId': rootId,
              'path': relPath,
              if (rootAbsolutePath != null && rootAbsolutePath.isNotEmpty)
                'rootAbsolutePath': rootAbsolutePath,
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
          if (AppLogger.verboseExtvol) {
            await StorageAccessDiagnostics.logSnapshot(
              'files_list_500:$rootId',
            );
          }
          return Response.internalServerError(
            body: 'file list failed: $e',
            headers: {'content-type': 'text/plain; charset=utf-8'},
          );
        }
      };

  Future<Response> _externalResponse(String rootId, String relPath) async {
    final volPath = externalBrowser.volumePathFromRootId(rootId);
    AppLogger.logVerbose(
      'extvol _externalResponse',
      scope: 'extvol_diag',
      details: {
        'rootId': rootId,
        'decodedVolPath': volPath ?? '',
        'relPath': relPath,
      },
    );
    if (volPath == null || volPath.isEmpty) {
      AppLogger.log(
        'extvol bad rootId',
        scope: 'extvol_diag',
        details: {'rootId': rootId},
      );
      return Response.badRequest(body: 'invalid external rootId');
    }
    final mounted = await externalBrowser.isVolumeMounted(volPath);
    if (!mounted) {
      AppLogger.log(
        'extvol not mounted',
        scope: 'extvol_diag',
        details: {'volPath': volPath, 'rootId': rootId},
      );
      if (AppLogger.verboseExtvol) {
        await StorageAccessDiagnostics.logSnapshot('extvol_not_mounted');
      }
      return Response.notFound('external volume not mounted');
    }
    if (relPath.isNotEmpty &&
        (relPath.contains('..') || relPath.startsWith('/'))) {
      AppLogger.log(
        'extvol forbidden path',
        scope: 'extvol_diag',
        details: {'relPath': relPath},
      );
      return Response.forbidden('invalid path');
    }
    final vols = await externalBrowser.listBrowsableVolumes();
    var label = '澶栫疆瀛樺偍';
    var matchedVol = false;
    for (final v in vols) {
      if (externalBrowser.isSameVolumePath(v.path, volPath)) {
        matchedVol = true;
        if (v.description.isNotEmpty) label = v.description;
        break;
      }
    }
    AppLogger.logVerbose(
      'extvol before listDirectory',
      scope: 'extvol_diag',
      details: {
        'volPath': volPath,
        'matchedVol': matchedVol,
        'label': label,
        'knownVols': [for (final v in vols) v.path],
        'shareScopeCustom': shareScope?.isCustom == true,
      },
    );
    try {
      var entries = await externalBrowser.listDirectory(
        volumePath: volPath,
        volumeLabel: label.isEmpty ? '澶栫疆瀛樺偍' : label,
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
      AppLogger.logVerbose(
        'extvol list ok',
        scope: 'extvol_diag',
        details: {
          'volPath': volPath,
          'path': relPath,
          'count': entries.length,
          'label': label,
          'sample': [
            for (final e in entries.take(5))
              {'name': e.name, 'dir': e.isDirectory, 'rel': e.relativePath},
          ],
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
        scope: 'extvol_diag',
        error: e,
        stackTrace: st,
        details: {'volPath': volPath, 'path': relPath, 'rootId': rootId},
      );
      if (AppLogger.verboseExtvol) {
        await StorageAccessDiagnostics.logSnapshot('extvol_list_failed');
      }
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
              'rootDisplayName': '鍏变韩鑼冨洿',
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
      // limit<=0锛氬吋瀹规棫瀹㈡埛绔叏閲忥紱鍚﹀垯鍒嗛〉锛堥粯璁ら〉 120锛夈€?
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
      // 鐩稿唽鏌ヨ澶辫触鏃朵粛杩斿洖 200 绌哄垪琛紝閬垮厤瀵圭璇垽銆孨AS 鏈紑銆嶃€?
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

/// GET /api/v1/files/content?rootId=&path=  锛堝吋瀹?name=锛涙敮鎸?Range锛?
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
        final rel = AppPaths.portable(
          request.url.queryParameters['path'] ??
              request.url.queryParameters['name'] ??
              '',
        );
        final range = request.headers['range'] ?? '';
        AppLogger.logVerbose(
          'GET /files/content',
          scope: 'video_diag',
          details: {
            'rootId': rootId,
            'path': rel,
            'range': range,
            'peer': peer.fingerprint.length > 12
                ? '${peer.fingerprint.substring(0, 12)}…'
                : peer.fingerprint,
          },
        );
        if (rootId.isEmpty || rel.isEmpty) {
          AppLogger.log(
            'content bad request (empty rootId/path)',
            scope: 'video_diag',
            details: {'rootId': rootId, 'path': rel},
          );
          return Response.badRequest(body: 'rootId and path required');
        }
        if (rootId == MediaLibraryService.rootId) {
          return _libraryContent(request, rel);
        }
        if (rootId.startsWith(ExternalVolumeBrowser.rootIdPrefix)) {
          final volPath = externalBrowser.volumePathFromRootId(rootId);
          if (volPath == null) {
            AppLogger.log(
              'content bad extvol rootId',
              scope: 'video_diag',
              details: {'rootId': rootId},
            );
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
                scope: 'video_diag',
                details: {'volPath': volPath, 'path': rel, 'rootId': rootId},
              );
              return Response.notFound('file not found');
            }
            if (shareScope?.isCustom == true && !shareScope!.allows(file.path)) {
              AppLogger.log(
                'extvol content denied by shareScope',
                scope: 'video_diag',
                details: {'file': file.path},
              );
              return Response.notFound('file not found');
            }
            final length = await file.length();
            final name = p.basename(file.path);
            final mime = MimeTypes.fromFileNameOrOctet(name);
            AppLogger.logVerbose(
              'extvol content resolve ok',
              scope: 'video_diag',
              details: {
                'volPath': volPath,
                'file': file.path,
                'length': length,
                'mime': mime,
                'range': range,
              },
            );
            return fileRangeResponse(
              request: request,
              file: file,
              length: length,
              fileName: name,
              mimeType: mime,
            );
          } catch (e, st) {
            AppLogger.log(
              'extvol content failed',
              scope: 'video_diag',
              error: e,
              stackTrace: st,
              details: {'volPath': volPath, 'path': rel},
            );
            if (AppLogger.verboseExtvol) {
              await StorageAccessDiagnostics.logSnapshot(
                'extvol_content_failed',
              );
            }
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
    if (asset == null) {
      AppLogger.log(
        'library content not found',
        scope: 'video_diag',
        details: {'path': rel},
      );
      return Response.notFound('file not found');
    }
    if (shareScope?.isCustom == true && !_inShareScope(asset)) {
      AppLogger.log(
        'library content denied by shareScope',
        scope: 'video_diag',
        details: {'path': rel},
      );
      return Response.notFound('file not found');
    }
    final path = asset.absolutePath;
    if (path != null && path.isNotEmpty) {
      final file = File(path);
      if (await file.exists()) {
        final length = await file.length();
        final mime = asset.mimeType.isEmpty
            ? 'application/octet-stream'
            : asset.mimeType;
        AppLogger.logVerbose(
          'library content resolve ok',
          scope: 'video_diag',
          details: {
            'path': rel,
            'file': path,
            'length': length,
            'mime': mime,
            'range': request.headers['range'] ?? '',
          },
        );
        return fileRangeResponse(
          request: request,
          file: file,
          length: length,
          fileName: asset.displayName.isEmpty ? asset.id : asset.displayName,
          mimeType: mime,
        );
      }
    }
    final bytes = await mediaLibrary.readBytes(asset);
    if (bytes == null) {
      AppLogger.log(
        'library content bytes null',
        scope: 'video_diag',
        details: {'path': rel},
      );
      return Response.notFound('file not found');
    }
    AppLogger.logVerbose(
      'library content bytes ok',
      scope: 'video_diag',
      details: {'path': rel, 'length': bytes.length},
    );
    return Response.ok(
      bytes,
      headers: {
        'content-type':
            asset.mimeType.isEmpty ? 'application/octet-stream' : asset.mimeType,
        'content-length': '${bytes.length}',
        'accept-ranges': 'bytes',
        'content-disposition':
            ContentDisposition.attachment(asset.displayName),
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
  // 鎾祦鐢?inline銆佷笉甯?filename锛岄伩鍏嶉潪 ASCII 鏂囦欢鍚嶇偢 dart:io 澶存牎楠屻€?
  const disposition = ContentDisposition.inline;
  final rangeHeader = request.headers['range'];
  if (rangeHeader == null || !rangeHeader.startsWith('bytes=')) {
    AppLogger.logVerbose(
      'fileRangeResponse 200 full',
      scope: 'video_diag',
      details: {
        'file': file.path,
        'length': length,
        'mime': mimeType,
        'name': fileName,
      },
    );
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
    AppLogger.log(
      'fileRangeResponse 416 bad range',
      scope: 'video_diag',
      details: {'range': rangeHeader, 'length': length},
    );
    return Response(416, headers: {'content-range': 'bytes */$length'});
  }
  final startStr = spec.substring(0, dash);
  final endStr = spec.substring(dash + 1);
  var start = int.tryParse(startStr) ?? 0;
  var end = endStr.isEmpty ? length - 1 : (int.tryParse(endStr) ?? length - 1);
  if (start < 0) start = 0;
  if (end >= length) end = length - 1;
  if (start > end || start >= length) {
    AppLogger.log(
      'fileRangeResponse 416 out of range',
      scope: 'video_diag',
      details: {'range': rangeHeader, 'length': length},
    );
    return Response(416, headers: {'content-range': 'bytes */$length'});
  }
  final chunkLen = end - start + 1;
  AppLogger.logVerbose(
    'fileRangeResponse 206',
    scope: 'video_diag',
    details: {
      'file': file.path,
      'start': start,
      'end': end,
      'chunkLen': chunkLen,
      'total': length,
      'mime': mimeType,
    },
  );
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
