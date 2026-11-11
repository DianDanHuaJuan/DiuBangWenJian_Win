import 'peer_fingerprint_middleware.dart' as auth;

/// 受信请求认证头（指纹 + Bearer shared secret）。
class AuthHeaders {
  const AuthHeaders({
    required this.fingerprint,
    required this.secret,
  });

  final String fingerprint;
  final String secret;

  Map<String, String> toMap() => {
        auth.peerFingerprintHeader: fingerprint,
        auth.authorizationHeader: 'Bearer $secret',
      };
}

/// 客户端侧认证头构造器（与 peer_fingerprint_middleware 同构）。
///
/// [secret] 为配对时经加密 enroll 应答获得的 hex 密钥（peers 表）。
class RequestSigner {
  const RequestSigner();

  AuthHeaders sign({
    required String fingerprint,
    required String secret,
  }) =>
      AuthHeaders(fingerprint: fingerprint, secret: secret);
}
