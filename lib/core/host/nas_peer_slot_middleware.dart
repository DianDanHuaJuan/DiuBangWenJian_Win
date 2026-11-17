import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../auth/peer_fingerprint_middleware.dart';
import '../identity/peer.dart';
import '../protocol/nas_api_paths.dart';
import 'nas_peer_slot_registry.dart';

/// NAS 业务路径上的在线设备槽闸（须挂在 [peerFingerprintMiddleware] 之后）。
///
/// 配对等豁免路径不占槽；`/ws` 入站由 registry 在 attach 时另行 tryAcquire。
Middleware nasPeerSlotMiddleware({
  required NasPeerSlotRegistry slots,
  Set<String> guardedPrefixes = const {
    '/api/v1/files',
    '/api/v1/storage',
    '/api/v1/thumbnail',
    '/api/v1/backup',
    '/api/v1/preview',
    '/dav',
  },
}) {
  final prefixes = {
    for (final p in guardedPrefixes) _normalizePath(p),
  };
  return (inner) => (request) async {
        final path = _normalizePath('/${request.url.path}');
        if (!_isGuarded(path, prefixes)) {
          return inner(request);
        }
        final peer = request.context[peerKey] as Peer?;
        if (peer == null) {
          return inner(request);
        }
        if (!slots.tryAcquire(peer.fingerprint)) {
          return Response(
            503,
            body: jsonEncode({
              'ok': false,
              'code': NasApiErrorCodes.peerLimit,
              'message': '同时连接已满',
              'limit': slots.limit,
            }),
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return inner(request);
      };
}

bool _isGuarded(String path, Set<String> prefixes) {
  for (final prefix in prefixes) {
    if (path == prefix || path.startsWith('$prefix/')) return true;
  }
  return false;
}

String _normalizePath(String path) {
  if (path.isEmpty) return '/';
  final withSlash = path.startsWith('/') ? path : '/$path';
  return withSlash.replaceAll(RegExp(r'/+'), '/');
}
