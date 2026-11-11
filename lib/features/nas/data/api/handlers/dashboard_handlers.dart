import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../../../../../core/auth/peer_fingerprint_middleware.dart';
import '../../../../../core/identity/peer.dart';
import '../../../../../core/protocol/nas_api_paths.dart';
import '../services/video_hls_session_service.dart';

/// GET /api/v1/preview/hls?rootId=&name=
class PreviewHlsHandler {
  static const path = NasApiPaths.previewHls;

  PreviewHlsHandler({required this.sessionService});

  final VideoHlsSessionService sessionService;

  Handler get handler => (Request request) async {
        final peer = request.context[peerKey] as Peer?;
        if (peer == null) return Response.unauthorized('peer required');
        final rootId = request.url.queryParameters['rootId'] ?? '';
        final name = request.url.queryParameters['name'] ?? '';
        if (rootId.isEmpty || name.isEmpty) {
          return Response.badRequest(body: 'rootId and name required');
        }
        final info = await sessionService.resolve(
          rootId: rootId,
          fileName: name,
        );
        return Response.ok(
          jsonEncode(info),
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      };
}
