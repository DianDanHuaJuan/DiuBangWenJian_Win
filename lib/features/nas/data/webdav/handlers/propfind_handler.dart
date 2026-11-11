import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

import '../../../../../core/auth/peer_fingerprint_middleware.dart';
import '../../../../../core/identity/peer.dart';
import '../../../../../core/storage/file_chunk_stream.dart';
import '../../../../../core/storage/share_reader.dart';
import '../../../../../core/storage/storage_root.dart';
import '../../nas_share_scope.dart';
import '../../share_path_resolver.dart';

/// WebDAV 根路径前缀。
const davRootPath = '/dav';

String _xmlEscape(String raw) => raw
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

({String? rootId, String? relative}) _parseDavPath(Request request) {
  final segments =
      request.url.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty || segments.first != 'dav') {
    return (rootId: null, relative: null);
  }
  if (segments.length == 1) {
    return (rootId: null, relative: '');
  }
  if (segments.length == 2) {
    // /dav/<name> —— 相对当前根
    return (rootId: null, relative: Uri.decodeComponent(segments[1]));
  }
  final rootId = Uri.decodeComponent(segments[1]);
  final relative =
      Uri.decodeComponent(segments.sublist(2).join('/'));
  return (rootId: rootId, relative: relative);
}

/// PROPFIND /dav
class PropfindHandler {
  PropfindHandler({required this.shareReader, this.shareScope});

  final ShareReader shareReader;
  final NasShareScope? shareScope;

  Handler get handler => (Request request) async {
        final peer = request.context[peerKey] as Peer?;
        if (peer == null) return Response.unauthorized('peer required');
        if (shareScope?.isCustom == true) {
          return _customListing(shareScope!);
        }
        final entries = await shareReader.listFiles(includeHistory: true);
        final buf = StringBuffer()
          ..writeln('<?xml version="1.0" encoding="utf-8"?>')
          ..writeln('<D:multistatus xmlns:D="DAV:">')
          ..writeln('  <D:response>')
          ..writeln('    <D:href>$davRootPath/</D:href>')
          ..writeln('    <D:propstat>')
          ..writeln('      <D:prop>')
          ..writeln('        <D:resourcetype><D:collection/></D:resourcetype>')
          ..writeln('        <D:displayname>diubangfiles</D:displayname>')
          ..writeln('      </D:prop>')
          ..writeln('      <D:status>HTTP/1.1 200 OK</D:status>')
          ..writeln('    </D:propstat>')
          ..writeln('  </D:response>');
        for (final e in entries) {
          final href =
              '$davRootPath/${Uri.encodeComponent(e.rootId)}/${Uri.encodeComponent(e.fileName)}';
          final modified = HttpDate.format(
            DateTime.fromMillisecondsSinceEpoch(e.modifiedAtMs),
          );
          buf
            ..writeln('  <D:response>')
            ..writeln('    <D:href>$href</D:href>')
            ..writeln('    <D:propstat>')
            ..writeln('      <D:prop>')
            ..writeln('        <D:resourcetype/>')
            ..writeln(
              '        <D:displayname>${_xmlEscape(e.fileName)}</D:displayname>',
            )
            ..writeln(
              '        <D:getcontentlength>${e.sizeBytes}</D:getcontentlength>',
            )
            ..writeln(
              '        <D:getlastmodified>${_xmlEscape(modified)}</D:getlastmodified>',
            )
            ..writeln('      </D:prop>')
            ..writeln('      <D:status>HTTP/1.1 200 OK</D:status>')
            ..writeln('    </D:propstat>')
            ..writeln('  </D:response>');
        }
        buf.writeln('</D:multistatus>');
        return Response(
          207,
          body: buf.toString(),
          headers: {'content-type': 'application/xml; charset=utf-8'},
        );
      };

  Future<Response> _customListing(NasShareScope scope) async {
    final buf = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="utf-8"?>')
      ..writeln('<D:multistatus xmlns:D="DAV:">')
      ..writeln('  <D:response>')
      ..writeln('    <D:href>$davRootPath/</D:href>')
      ..writeln('    <D:propstat>')
      ..writeln('      <D:prop>')
      ..writeln('        <D:resourcetype><D:collection/></D:resourcetype>')
      ..writeln('        <D:displayname>共享范围</D:displayname>')
      ..writeln('      </D:prop>')
      ..writeln('      <D:status>HTTP/1.1 200 OK</D:status>')
      ..writeln('    </D:propstat>')
      ..writeln('  </D:response>');
    final dirs = scope.folders;
    for (var i = 0; i < dirs.length; i++) {
      final children = await scope.list('s$i');
      for (final e in children) {
        if (e.isDirectory) continue;
        final href = '$davRootPath/fs/${_davSlotHref(e.relativePath)}';
        final modified = HttpDate.format(
          DateTime.fromMillisecondsSinceEpoch(e.modifiedAtMs),
        );
        buf
          ..writeln('  <D:response>')
          ..writeln('    <D:href>$href</D:href>')
          ..writeln('    <D:propstat>')
          ..writeln('      <D:prop>')
          ..writeln('        <D:resourcetype/>')
          ..writeln(
            '        <D:displayname>${_xmlEscape(e.name)}</D:displayname>',
          )
          ..writeln('        <D:getcontentlength>${e.sizeBytes}</D:getcontentlength>')
          ..writeln(
            '        <D:getlastmodified>${_xmlEscape(modified)}</D:getlastmodified>',
          )
          ..writeln('      </D:prop>')
          ..writeln('      <D:status>HTTP/1.1 200 OK</D:status>')
          ..writeln('    </D:propstat>')
          ..writeln('  </D:response>');
      }
    }
    buf.writeln('</D:multistatus>');
    return Response(
      207,
      body: buf.toString(),
      headers: {'content-type': 'application/xml; charset=utf-8'},
    );
  }
}

String _davSlotHref(String relativePath) {
  return relativePath
      .split('/')
      .where((s) => s.isNotEmpty)
      .map(Uri.encodeComponent)
      .join('/');
}

/// GET|HEAD /dav/...
class DavGetHandler {
  DavGetHandler({required this.resolver, this.shareScope});

  final SharePathResolver resolver;
  final NasShareScope? shareScope;

  Handler get handler => (Request request) async {
        final peer = request.context[peerKey] as Peer?;
        if (peer == null) return Response.unauthorized('peer required');
        final parsed = _parseDavPath(request);
        if (parsed.rootId == null ||
            parsed.relative == null ||
            parsed.relative!.isEmpty) {
          return Response.notFound('not found');
        }
        final File? file;
        if (shareScope?.isCustom == true) {
          final scoped = shareScope!.resolveFile(parsed.relative!);
          file = scoped != null && shareScope!.allows(scoped.path)
              ? scoped
              : null;
        } else {
          file = await resolver.resolveFile(
            rootId: parsed.rootId!,
            relativePath: parsed.relative!,
          );
        }
        if (file == null || !await file.exists()) {
          return Response.notFound('file not found');
        }
        final length = await file.length();
        final headers = {
          'content-type': 'application/octet-stream',
          'content-length': '$length',
          'content-disposition':
              'attachment; filename="${p.basename(file.path)}"',
        };
        if (request.method.toUpperCase() == 'HEAD') {
          return Response.ok(null, headers: headers);
        }
        return Response.ok(
          openFileChunked(file, chunkSize: kNasFileReadChunkBytes),
          headers: headers,
        );
      };
}

/// PUT /dav/name 或 /dav/rootId/name —— 写入共享根四分类（rootId 忽略）。
class DavPutHandler {
  DavPutHandler({required this.receiveFile});

  final Future<({String fileName, String rootId})> Function({
    required String preferredFileName,
    required List<int> bytes,
    required String peerFingerprint,
  }) receiveFile;

  Handler get handler => (Request request) async {
        final peer = request.context[peerKey] as Peer?;
        if (peer == null) return Response.unauthorized('peer required');
        final parsed = _parseDavPath(request);
        final name = parsed.relative;
        if (name == null || name.isEmpty || SharePathResolver.isUnsafeName(name)) {
          return Response.badRequest(body: 'name required');
        }
        final bytes = await request.read().fold<List<int>>(
          <int>[],
          (prev, chunk) => prev..addAll(chunk),
        );
        try {
          final result = await receiveFile(
            preferredFileName: p.basename(name),
            bytes: bytes,
            peerFingerprint: peer.fingerprint,
          );
          return Response(
            201,
            body: jsonEncode({
              'ok': true,
              'name': result.fileName,
              'rootId': result.rootId,
            }),
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        } catch (e) {
          return Response(507, body: '$e');
        }
      };
}

/// DELETE /dav/rootId/name
class DavDeleteHandler {
  DavDeleteHandler({required this.resolver, this.shareScope});

  final SharePathResolver resolver;
  final NasShareScope? shareScope;

  Handler get handler => (Request request) async {
        final peer = request.context[peerKey] as Peer?;
        if (peer == null) return Response.unauthorized('peer required');
        final parsed = _parseDavPath(request);
        if (parsed.rootId == null ||
            parsed.relative == null ||
            parsed.relative!.isEmpty) {
          return Response.badRequest(body: 'path required');
        }
        if (shareScope?.isCustom == true) {
          final deleted = await shareScope!.deleteRelative(parsed.relative!);
          if (!deleted) return Response.notFound('not found');
          return Response(204);
        }
        final file = await resolver.resolveFile(
          rootId: parsed.rootId!,
          relativePath: parsed.relative!,
        );
        if (file == null || !await file.exists()) {
          return Response.notFound('not found');
        }
        await file.delete();
        return Response(204);
      };
}

/// MKCOL /dav/folderName —— 在当前根创建子目录。
class DavMkcolHandler {
  DavMkcolHandler({required this.resolver});

  final SharePathResolver resolver;

  Handler get handler => (Request request) async {
        final peer = request.context[peerKey] as Peer?;
        if (peer == null) return Response.unauthorized('peer required');
        final parsed = _parseDavPath(request);
        final name = parsed.relative;
        if (name == null || name.isEmpty || SharePathResolver.isUnsafeName(name)) {
          return Response.badRequest(body: 'name required');
        }
        final root = await resolver.currentRoot();
        if (root.revoked || root.kind != StorageRootKind.path) {
          return Response(503, body: 'root unavailable');
        }
        final dir = Directory(p.join(root.uriOrPath, p.basename(name)));
        if (await dir.exists()) {
          return Response(405, body: 'already exists');
        }
        await dir.create(recursive: true);
        return Response(201);
      };
}
