import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';

import 'package:diubangwenjian/core/auth/peer_fingerprint_middleware.dart';
import 'package:diubangwenjian/core/auth/request_signer.dart';
import 'package:diubangwenjian/core/identity/peer.dart';

void main() {
  final testFingerprint = 'ab' * 32;
  final testSecret = 'cd' * 32;
  const defaultAuth = Object();
  const defaultFingerprint = Object();
  final testPeer = Peer(
    fingerprint: testFingerprint,
    name: '测试机',
    model: 'K60',
    pairedAt: 0,
    secret: testSecret,
  );

  var trustedPeers = <String, Peer>{testFingerprint: testPeer};

  Handler buildApp() {
    final middleware = peerFingerprintMiddleware(
      peerLookup: (fingerprint) async => trustedPeers[fingerprint],
      exemptPaths: {'/api/v1/pair/enroll'},
    );
    return const Pipeline()
        .addMiddleware(middleware)
        .addHandler((request) async {
      final peer = request.context[peerKey] as Peer?;
      return Response.ok(
        peer?.fingerprint ?? 'ANON',
        headers: {'content-type': 'text/plain'},
      );
    });
  }

  Request buildRequest({
    String path = '/api/v1/files',
    String method = 'GET',
    Object? fingerprint = defaultFingerprint,
    Object? secret = defaultAuth,
  }) {
    final fp = identical(fingerprint, defaultFingerprint)
        ? testFingerprint
        : fingerprint as String?;
    final effectiveSecret = identical(secret, defaultAuth)
        ? testSecret
        : secret as String?;
    return Request(
      method,
      Uri.parse('http://localhost$path'),
      headers: <String, String>{
        if (fp != null) peerFingerprintHeader: fp,
        if (effectiveSecret != null)
          authorizationHeader: 'Bearer $effectiveSecret',
      },
    );
  }

  group('peer_fingerprint_middleware（Bearer shared secret）', () {
    setUp(() {
      trustedPeers = {testFingerprint: testPeer};
    });

    test('豁免路径直接放行（配对端点，无任何认证头）', () async {
      final response = await buildApp()(buildRequest(
        path: '/api/v1/pair/enroll',
        fingerprint: null,
        secret: null,
      ));
      expect(response.statusCode, 200);
      expect(await response.readAsString(), 'ANON');
    });

    test('无指纹头 → 401', () async {
      final response = await buildApp()(
        buildRequest(fingerprint: null),
      );
      expect(response.statusCode, 401);
    });

    test('指纹不在表（陌生/吊销）→ 401', () async {
      final response = await buildApp()(
        buildRequest(fingerprint: 'ef' * 32),
      );
      expect(response.statusCode, 401);
    });

    test('表内但 secret 空（旧记录未重新配对）→ 401', () async {
      trustedPeers[testFingerprint] = Peer(
        fingerprint: testFingerprint,
        name: '旧配对',
        model: 'K60',
        pairedAt: 0,
        secret: '',
      );
      final response = await buildApp()(buildRequest());
      expect(response.statusCode, 401);
    });

    test('无 Authorization → 401', () async {
      final response = await buildApp()(buildRequest(secret: null));
      expect(response.statusCode, 401);
    });

    test('错误 Bearer secret → 401', () async {
      final response = await buildApp()(
        buildRequest(secret: 'ff' * 32),
      );
      expect(response.statusCode, 401);
    });

    test('RequestSigner 同构闭环：Bearer → 中间件通过 + 注入 peer',
        () async {
      final headers = const RequestSigner().sign(
        fingerprint: testFingerprint,
        secret: testSecret,
      );
      final response = await buildApp()(Request(
        'GET',
        Uri.parse('http://localhost/api/v1/files'),
        headers: headers.toMap(),
      ));
      expect(response.statusCode, 200);
      expect(await response.readAsString(), testFingerprint);
    });

    test('删行即吊销：表移除后原有效 Bearer → 401', () async {
      trustedPeers.remove(testFingerprint);
      final response = await buildApp()(buildRequest());
      expect(response.statusCode, 401);
    });
  });
}
