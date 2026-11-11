import 'package:shelf/shelf.dart';

import '../identity/peer.dart';

/// 认证通过后注入管道的 [Peer]（互传端点从 context 取用）。
const peerKey = 'host.peer';

/// peer 查表回调（PeerRepository.findByFingerprint 满足之）。
typedef PeerLookup = Future<Peer?> Function(String fingerprint);

/// 局域网轻量认证头：
/// - `X-Peer-Fingerprint`：发起方 Device ID（查 peers 表）
/// - `Authorization: Bearer <shared_secret>`：配对时交换的静态共享密钥
const peerFingerprintHeader = 'x-peer-fingerprint';
const authorizationHeader = 'authorization';

/// 应用层认证中间件（局域网轻量：指纹头 + Bearer shared secret）。
///
/// ① `X-Peer-Fingerprint` 头查 peers 表（删行即吊销，不在表/空 secret → 401）；
/// ② `Authorization: Bearer <secret>` 与表内 secret 常数时间比对（不匹配 → 401）。
///
/// TLS 层只做服务端侧加密（客户端 onBadCertificate 验指纹）；dart:io
/// 无 CA 层架构下不请求客户端证书。
///
/// [exemptPaths]：认证前引导路径（配对端点），直接放行。
Middleware peerFingerprintMiddleware({
  required PeerLookup peerLookup,
  Set<String> exemptPaths = const {},
}) {
  final normalizedExempt = {
    for (final p in exemptPaths) _normalizePath(p),
  };
  return (inner) => (request) async {
        final path = _normalizePath('/${request.url.path}');
        if (normalizedExempt.contains(path)) return inner(request);

        final fingerprint = request.headers[peerFingerprintHeader];
        if (fingerprint == null || fingerprint.isEmpty) {
          return _reject(401, 'peer fingerprint required');
        }
        final peer = await peerLookup(fingerprint);
        if (peer == null) {
          return _reject(401, 'peer not trusted');
        }
        if (peer.secret.isEmpty) {
          return _reject(401, 'peer secret missing (re-pair required)');
        }

        final bearer = _extractBearer(request.headers[authorizationHeader]);
        if (bearer == null || !_constantTimeEquals(peer.secret, bearer)) {
          return _reject(401, 'invalid bearer secret');
        }

        return inner(request.change(context: {peerKey: peer}));
      };
}

String _normalizePath(String path) {
  if (path.isEmpty) return '/';
  final withSlash = path.startsWith('/') ? path : '/$path';
  return withSlash.replaceAll(RegExp(r'/+'), '/');
}

String? _extractBearer(String? authorization) {
  if (authorization == null) return null;
  const prefix = 'Bearer ';
  if (!authorization.startsWith(prefix)) return null;
  final token = authorization.substring(prefix.length).trim();
  return token.isEmpty ? null : token;
}

/// 常数时间比较（长度不同时仍扫完较短侧，避免早期返回）。
bool _constantTimeEquals(String expected, String actual) {
  final maxLen =
      expected.length > actual.length ? expected.length : actual.length;
  var diff = expected.length ^ actual.length;
  for (var i = 0; i < maxLen; i++) {
    final a = i < expected.length ? expected.codeUnitAt(i) : 0;
    final b = i < actual.length ? actual.codeUnitAt(i) : 0;
    diff |= a ^ b;
  }
  return diff == 0;
}

Response _reject(int statusCode, String message) => Response(
      statusCode,
      body: message,
      headers: {'content-type': 'text/plain'},
    );
