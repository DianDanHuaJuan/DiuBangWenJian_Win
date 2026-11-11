import 'package:shelf/shelf.dart';

/// NAS 路由集守卫：开关关闭时对守卫路径返回 503，路由本身常驻不卸载。
Middleware nasRouteGuard({
  required bool Function() isEnabled,
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
        if (!isEnabled()) {
          return Response(
            503,
            body: 'nas service off',
            headers: {'content-type': 'text/plain; charset=utf-8'},
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
