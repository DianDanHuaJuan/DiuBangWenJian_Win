import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

import '../../../../../core/auth/peer_fingerprint_middleware.dart';
import '../../../../../core/common/app_exception.dart';
import '../../../../../core/identity/peer.dart';
import '../../../../../core/protocol/nas_api_paths.dart';
import '../../../../../core/protocol/thumb_image_tier.dart';
import '../../../../../core/storage/external_volume_browser.dart';
import '../../../../../core/storage/incomplete_file.dart';
import '../../../../../core/storage/media_library_service.dart';
import '../../../../../core/storage/share_reader.dart';
import '../../../../../core/storage/share_writer.dart';
import '../../../../../core/storage/thumb_generation_gate.dart';
import '../../../../../core/storage/thumb_pipeline.dart';
import '../../../../../core/transfer/stream_transfer_tuning.dart';
import '../../nas_share_scope.dart';
import '../../share_path_resolver.dart';

/// GET /api/v1/thumbnail?type=grid|preview&rootId=&name=
class ThumbnailHandler {
  static const path = NasApiPaths.thumbnail;

  /// 排队 + 现算总上限；超时 → 404。
  static const generateTimeout = Duration(seconds: 15);

  ThumbnailHandler({
    required this.resolver,
    required this.pipeline,
    required this.mediaLibrary,
    this.shareScope,
  });

  final SharePathResolver resolver;
  final ThumbPipeline pipeline;
  final MediaLibraryService mediaLibrary;
  final NasShareScope? shareScope;

  Handler get handler => (Request request) async {
        final peer = request.context[peerKey] as Peer?;
        if (peer == null) return Response.unauthorized('peer required');
        final rootId = request.url.queryParameters[NasApiQuery.rootId] ?? '';
        final name = request.url.queryParameters[NasApiQuery.name] ?? '';
        final tier = ThumbImageTier.tryParse(
          request.url.queryParameters[NasApiQuery.type],
        );
        if (rootId.isEmpty || name.isEmpty) {
          return Response.badRequest(body: 'rootId and name required');
        }
        if (tier == null) {
          return Response.badRequest(body: 'type must be grid or preview');
        }
        final resolved = await _resolveSource(rootId: rootId, name: name);
        if (resolved == null) {
          return Response.notFound('file not found');
        }

        List<int>? bytes;
        try {
          bytes = await pipeline
              .getOrGenerate(
                file: resolved.file,
                tier: tier,
                rootId: rootId,
                name: name,
                mtimeMs: resolved.mtimeMs,
                sizeBytes: resolved.sizeBytes,
                priority: ThumbGenPriority.remote,
              )
              .timeout(generateTimeout, onTimeout: () => null);
        } catch (_) {
          bytes = null;
        }

        if (bytes == null || bytes.isEmpty) {
          return Response.notFound('no thumbnail');
        }
        return Response.ok(
          bytes,
          headers: {
            'content-type': 'image/jpeg',
            'content-length': '${bytes.length}',
            'cache-control': 'private, max-age=3600',
          },
        );
      };

  Future<({File file, int mtimeMs, int sizeBytes})?> _resolveSource({
    required String rootId,
    required String name,
  }) async {
    if (rootId == MediaLibraryService.rootId) {
      final asset = await mediaLibrary.findByRelativePath(name);
      if (asset == null || !libraryAssetAllowed(shareScope, asset)) {
        return null;
      }
      final path = asset.absolutePath?.trim() ?? '';
      if (path.isEmpty) return null;
      final file = File(path);
      if (!await file.exists()) return null;
      return (
        file: file,
        mtimeMs: asset.modifiedAtMs,
        sizeBytes: asset.sizeBytes,
      );
    }
    final file = await resolveScopedFile(
      scope: shareScope,
      resolver: resolver,
      rootId: rootId,
      name: name,
    );
    if (file == null || !await file.exists()) return null;
    final st = await file.stat();
    return (
      file: file,
      mtimeMs: st.modified.millisecondsSinceEpoch,
      sizeBytes: st.size,
    );
  }
}

/// POST /api/v1/files/batch-delete
class BatchDeleteHandler {
  static const path = NasApiPaths.filesBatchDelete;

  BatchDeleteHandler({
    required this.shareReader,
    required this.mediaLibrary,
    required this.resolver,
    this.shareScope,
  });

  final ShareReader shareReader;
  final MediaLibraryService mediaLibrary;
  final SharePathResolver resolver;
  final NasShareScope? shareScope;

  Handler get handler => (Request request) async {
        final peer = request.context[peerKey] as Peer?;
        if (peer == null) return Response.unauthorized('peer required');
        Map<String, dynamic> body;
        try {
          body =
              jsonDecode(await request.readAsString()) as Map<String, dynamic>;
        } catch (_) {
          return Response.badRequest(body: 'invalid json');
        }
        final items = body['items'] as List<dynamic>? ?? const [];
        var deleted = 0;
        final errors = <String>[];
        for (final rawItem in items) {
          final m = Map<String, dynamic>.from(rawItem as Map);
          var rootId = m['rootId'] as String? ?? '';
          final rel = ((m['relativePath'] as String?) ??
                  (m['name'] as String?) ??
                  '')
              .replaceAll('\\', '/');
          if (rootId.isEmpty || rel.isEmpty) {
            errors.add('$rootId/$rel: bad args');
            continue;
          }
          try {
            final bool ok;
            if (rootId == MediaLibraryService.rootId) {
              final asset = await mediaLibrary.findByRelativePath(rel);
              if (asset == null || !libraryAssetAllowed(shareScope, asset)) {
                ok = false;
              } else {
                ok = await mediaLibrary.deleteByRelativePath(rel);
              }
            } else if (shareScope?.isCustom == true &&
                !rootId.startsWith(ExternalVolumeBrowser.rootIdPrefix)) {
              ok = await shareScope!.deleteRelative(rel);
            } else if (rootId.startsWith(ExternalVolumeBrowser.rootIdPrefix)) {
              final browser = ExternalVolumeBrowser();
              final vol = browser.volumePathFromRootId(rootId);
              if (vol == null) {
                ok = false;
              } else if (shareScope?.isCustom == true) {
                final file = await browser.resolveFile(
                  volumePath: vol,
                  relativePath: rel,
                );
                ok = file != null &&
                    shareScope!.allows(file.path) &&
                    await browser.deleteEntry(
                      volumePath: vol,
                      relativePath: rel,
                    );
              } else {
                ok = await browser.deleteEntry(
                  volumePath: vol,
                  relativePath: rel,
                );
              }
            } else {
              rootId = await resolver.resolveRootId(rootId);
              ok = await shareReader.deleteEntry(
                rootId: rootId,
                relativePath: rel,
              );
            }
            if (ok) {
              deleted++;
            } else {
              errors.add('$rootId/$rel: missing or denied');
            }
          } catch (e) {
            errors.add('$rootId/$rel: $e');
          }
        }
        return Response.ok(
          jsonEncode({'deleted': deleted, 'errors': errors}),
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      };
}

/// POST /api/v1/files/mkdir —— 目录树新建文件夹。
class MkdirHandler {
  static const path = NasApiPaths.filesMkdir;

  MkdirHandler({
    required this.shareReader,
    required this.resolver,
    this.shareScope,
  });

  final ShareReader shareReader;
  final SharePathResolver resolver;
  final NasShareScope? shareScope;

  Handler get handler => (Request request) async {
        final peer = request.context[peerKey] as Peer?;
        if (peer == null) return Response.unauthorized('peer required');
        Map<String, dynamic> body;
        try {
          body =
              jsonDecode(await request.readAsString()) as Map<String, dynamic>;
        } catch (_) {
          return Response.badRequest(body: 'invalid json');
        }
        var rootId = (body['rootId'] as String? ?? '').trim();
        final path = ((body['path'] as String?) ?? '')
            .replaceAll('\\', '/')
            .trim();
        final name = ((body['name'] as String?) ?? '').trim();
        if (rootId.isEmpty || name.isEmpty) {
          return Response.badRequest(body: 'rootId and name required');
        }
        if (SharePathResolver.isUnsafeName(name) ||
            name.contains('/') ||
            name == '.' ||
            name == '..') {
          return Response.badRequest(body: 'invalid name');
        }
        if (path.isNotEmpty && SharePathResolver.isUnsafeName(path)) {
          return Response.forbidden('invalid path');
        }

        try {
          if (rootId.startsWith(ExternalVolumeBrowser.rootIdPrefix)) {
            final browser = ExternalVolumeBrowser();
            final vol = browser.volumePathFromRootId(rootId);
            if (vol == null || vol.isEmpty) {
              return Response.badRequest(body: 'invalid external root');
            }
            if (shareScope?.isCustom == true) {
              final parentPath = path.isEmpty
                  ? vol
                  : p.join(vol, path.replaceAll('/', p.separator));
              if (!shareScope!.allows(parentPath)) {
                return Response.forbidden('denied');
              }
            }
            final result = await browser.createDirectory(
              volumePath: vol,
              parentRelativePath: path,
              name: name,
            );
            return _mkdirResult(result, rootId: rootId);
          }

          if (shareScope?.isCustom == true) {
            final result = await shareScope!.createDirectory(
              parentRelativePath: path,
              name: name,
            );
            return _mkdirResult(result, rootId: rootId);
          }

          rootId = await resolver.resolveRootId(rootId);
          final result = await shareReader.createDirectory(
            rootId: rootId,
            parentRelativePath: path,
            name: name,
          );
          return _mkdirResult(result, rootId: rootId);
        } catch (e) {
          return Response.internalServerError(
            body: '$e',
            headers: {'content-type': 'text/plain; charset=utf-8'},
          );
        }
      };

  Response _mkdirResult(
    ({bool ok, String? relativePath, String? error}) result, {
    required String rootId,
  }) {
    if (result.ok) {
      return Response.ok(
        jsonEncode({
          'ok': true,
          'rootId': rootId,
          'relativePath': result.relativePath,
        }),
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    switch (result.error) {
      case 'exists':
        return Response(
          409,
          body: jsonEncode({
            'ok': false,
            'error': 'exists',
            'relativePath': result.relativePath,
          }),
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      case 'parent missing':
        return Response.notFound('parent missing');
      case 'denied':
      case 'out of scope':
        return Response.forbidden(result.error);
      case 'invalid name':
      case 'invalid path':
      case 'parent required':
        return Response.badRequest(body: result.error);
      default:
        return Response(
          400,
          body: result.error ?? 'mkdir failed',
          headers: {'content-type': 'text/plain; charset=utf-8'},
        );
    }
  }
}

/// PUT /api/v1/files/upload?name= —— 流式写入共享根四分类（按文件名归类）。
class FileUploadHandler {
  static const path = NasApiPaths.filesUpload;

  FileUploadHandler({
    required this.openReceiveSink,
    required this.notifyWritten,
  });

  /// 打开共享根落盘 sink（本机作为接收方边收边写）。
  final Future<({IOSink sink, ShareWriteResult result})> Function({
    required String preferredFileName,
    int? expectedLength,
  }) openReceiveSink;

  final Future<void> Function(String absolutePath) notifyWritten;

  Handler get handler => (Request request) async {
        final peer = request.context[peerKey] as Peer?;
        if (peer == null) return Response.unauthorized('peer required');
        final name = request.url.queryParameters['name'] ?? '';
        if (name.isEmpty ||
            SharePathResolver.isUnsafeName(name) ||
            name.contains('/')) {
          return Response.badRequest(body: 'name required');
        }
        final fileName = p.basename(name);
        final rootId = request.url.queryParameters['rootId'] ?? '';
        final expectedLength =
            request.contentLength != null && request.contentLength! > 0
                ? request.contentLength
                : null;

        if (rootId.startsWith(ExternalVolumeBrowser.rootIdPrefix)) {
          final browser = ExternalVolumeBrowser();
          final vol = browser.volumePathFromRootId(rootId);
          if (vol == null || vol.isEmpty) {
            return Response.badRequest(body: 'invalid external root');
          }
          try {
            final stored = await browser.writeFileFromStream(
              volumePath: vol,
              relativeDir: request.url.queryParameters['dir'] ?? '',
              fileName: fileName,
              stream: request.read(),
              expectedLength: expectedLength,
            );
            if (stored == null) {
              return Response.notFound('external directory not found');
            }
            return Response.ok(
              jsonEncode({
                'ok': true,
                'name': stored,
                'rootId': rootId,
              }),
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          } catch (e) {
            return Response.internalServerError(
              body: '$e',
              headers: {'content-type': 'text/plain; charset=utf-8'},
            );
          }
        }

        IOSink? sink;
        ShareWriteResult? written;
        try {
          final opened = await openReceiveSink(
            preferredFileName: fileName,
            expectedLength: expectedLength,
          );
          sink = opened.sink;
          written = opened.result;
          await for (final chunk in StreamTransferTuning.bufferUploadStream(
            request.read(),
          )) {
            sink.add(chunk);
          }
          await sink.flush();
          await sink.close();
          sink = null;
          final len = await File(written.absolutePath).length();
          if (len <= 0) {
            await discardIncompleteFile(written.absolutePath);
            return Response.badRequest(body: 'empty upload');
          }
          await notifyWritten(written.absolutePath);
          return Response.ok(
            jsonEncode({
              'ok': true,
              'name': written.fileName,
              'rootId': written.rootId,
            }),
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        } on AppException catch (e) {
          await _abortUpload(sink, written?.absolutePath);
          final code = e.code == 'storage_no_space' ? 507 : 400;
          return Response(
            code,
            body: e.message,
            headers: {'content-type': 'text/plain; charset=utf-8'},
          );
        } catch (e) {
          await _abortUpload(sink, written?.absolutePath);
          return Response(
            500,
            body: '$e',
            headers: {'content-type': 'text/plain; charset=utf-8'},
          );
        }
      };

  Future<void> _abortUpload(IOSink? sink, String? path) async {
    try {
      await sink?.close();
    } catch (_) {}
    await discardIncompleteFile(path);
  }
}

bool libraryAssetAllowed(NasShareScope? scope, MediaLibraryAsset asset) {
  if (scope?.isCustom != true) return true;
  final path = asset.absolutePath;
  if (path == null || path.isEmpty) return false;
  return scope!.allows(path);
}

Future<File?> resolveScopedFile({
  required NasShareScope? scope,
  required SharePathResolver resolver,
  required String rootId,
  required String name,
}) async {
  if (scope?.isCustom == true) {
    final file = scope!.resolveFile(name);
    if (file == null || !scope.allows(file.path)) return null;
    return file;
  }
  var id = rootId;
  if (id == 'fs') {
    id = (await resolver.currentRoot()).id;
  }
  return resolver.resolveFile(rootId: id, relativePath: name);
}
