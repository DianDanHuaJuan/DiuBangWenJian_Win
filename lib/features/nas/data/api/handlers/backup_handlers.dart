import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

import '../../../../../core/auth/peer_fingerprint_middleware.dart';
import '../../../../../core/common/app_exception.dart';
import '../../../../../core/identity/peer.dart';
import '../../../../../core/protocol/nas_api_paths.dart';
import '../../../../../core/storage/backup_category.dart';
import '../../../../../core/storage/backup_receive_service.dart';
import '../../../../../core/storage/incomplete_file.dart';
import '../../../../../core/storage/share_writer.dart';
import '../../share_path_resolver.dart';

/// POST /api/v1/backup/preflight  { needBytes | sizeBytes }
///
/// 仅空间预检（施工方案：与文件名存在性分离）。
class BackupPreflightHandler {
  static const path = NasApiPaths.backupPreflight;

  BackupPreflightHandler({
    required this.freeBytesForCurrentRoot,
    required this.reserveBytes,
  });

  final Future<int?> Function() freeBytesForCurrentRoot;
  final int reserveBytes;

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
        final needBytes = (body['needBytes'] as num?)?.toInt() ??
            (body['sizeBytes'] as num?)?.toInt() ??
            0;
        final free = await freeBytesForCurrentRoot();
        // free 未知时 ok=true，避免误杀整次备份；明确不足才拒绝。
        final ok = free == null || free > needBytes + reserveBytes;
        return Response.ok(
          jsonEncode({
            'ok': ok,
            'freeBytes': free,
            'reserveBytes': reserveBytes,
            'needBytes': needBytes,
          }),
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      };
}

/// POST /api/v1/backup/exists  { category, fileName }
class BackupExistsHandler {
  static const path = NasApiPaths.backupExists;

  BackupExistsHandler({required this.receive});

  final BackupReceiveService receive;

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
        final category = BackupCategory.tryParse(body['category'] as String?);
        final fileName = (body['fileName'] as String? ?? '').trim();
        if (category == null ||
            fileName.isEmpty ||
            SharePathResolver.isUnsafeName(fileName) ||
            fileName.contains('/')) {
          return Response.badRequest(body: 'category and fileName required');
        }
        final result = await receive.exists(
          category: category,
          fileName: p.basename(fileName),
        );
        return Response.ok(
          jsonEncode({
            'exists': result.exists,
            'storedName': result.storedName,
            'category': category.apiName,
          }),
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      };
}

/// PUT /api/v1/backup/upload?category=&name= —— 流式写入四分类目录（非 inbox）。
class BackupUploadHandler {
  static const path = NasApiPaths.backupUpload;

  BackupUploadHandler({required this.receive});

  final BackupReceiveService receive;

  Handler get handler => (Request request) async {
        final peer = request.context[peerKey] as Peer?;
        if (peer == null) return Response.unauthorized('peer required');
        final category = BackupCategory.tryParse(
          request.url.queryParameters['category'],
        );
        final name = request.url.queryParameters['name'] ?? '';
        if (category == null ||
            name.isEmpty ||
            SharePathResolver.isUnsafeName(name) ||
            name.contains('/')) {
          return Response.badRequest(body: 'category and name required');
        }

        IOSink? sink;
        ShareWriteResult? written;
        try {
          final opened = await receive.openReceiveSink(
            category: category,
            preferredFileName: p.basename(name),
            expectedLength: request.contentLength,
          );
          sink = opened.sink;
          written = opened.result;
          await for (final chunk in request.read()) {
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
          await receive.notifyWritten(written.absolutePath);
          return Response.ok(
            jsonEncode({
              'ok': true,
              'storedName': written.fileName,
              'category': category.apiName,
              'rootId': written.rootId,
            }),
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        } on AppException catch (e) {
          await _abort(sink, written?.absolutePath);
          final code = e.code == 'storage_no_space' ? 507 : 400;
          return Response(
            code,
            body: e.message,
            headers: {'content-type': 'text/plain; charset=utf-8'},
          );
        } catch (e) {
          await _abort(sink, written?.absolutePath);
          return Response(
            500,
            body: '$e',
            headers: {'content-type': 'text/plain; charset=utf-8'},
          );
        }
      };

  Future<void> _abort(IOSink? sink, String? path) async {
    try {
      await sink?.close();
    } catch (_) {}
    await discardIncompleteFile(path);
  }
}
