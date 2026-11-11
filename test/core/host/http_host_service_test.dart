import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';

import 'package:diubangwenjian/core/auth/peer_fingerprint_middleware.dart';
import 'package:diubangwenjian/core/auth/request_signer.dart';
import 'package:diubangwenjian/core/host/http_host_service.dart';
import 'package:diubangwenjian/core/identity/peer.dart';
import 'package:diubangwenjian/core/identity/tls_certificate_builder.dart';

void main() {
  /// 局域网轻量认证宿主集成（真 TLS + 真网络）：
  /// ① TLS 只做服务端加密（客户端钉指纹）
  /// ② 受信端点验 Bearer shared secret + 指纹头
  test('Bearer 通过 + 伪造 secret 401 + 豁免端点放行', () async {
    final builder = TlsCertificateBuilder();
    final serverTls = builder.generate(deviceLabel: 'server-test');

    final clientFingerprint = 'ab' * 32;
    final clientSecret = 'cd' * 32;
    final trustedPeers = <String, Peer>{
      clientFingerprint: Peer(
        fingerprint: clientFingerprint,
        name: '客户端测试机',
        model: 'K60',
        pairedAt: 0,
        secret: clientSecret,
      ),
    };

    const signer = RequestSigner();

    final router = Router()
      ..get('/api/v1/who', (request) async {
        final peer = request.context[peerKey] as Peer?;
        return Response.ok(peer?.fingerprint ?? 'ANON');
      })
      ..post('/api/v1/pair/enroll', (request) async => Response.ok('enroll'));

    final host = HttpHostService(
      port: 0,
      securityContext: Future.value(SecurityContext()
        ..useCertificateChainBytes(utf8.encode(serverTls.certificatePem))
        ..usePrivateKeyBytes(utf8.encode(serverTls.privateKeyPem))),
      publicRoutes: router,
      middlewares: [
        peerFingerprintMiddleware(
          peerLookup: (fingerprint) async => trustedPeers[fingerprint],
          exemptPaths: {'/api/v1/pair/enroll'},
        ),
      ],
    );
    await host.start();
    final port = host.boundPort!;

    final client = HttpClient();
    client.badCertificateCallback = (cert, host, port) => true;

    Future<String> get(Uri uri, Map<String, String> headers) async {
      final request = await client.getUrl(uri);
      headers.forEach(request.headers.set);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      return '${response.statusCode} $body';
    }

    try {
      final base = Uri.parse('https://127.0.0.1:$port');

      expect(
        await get(
          base.resolve('/api/v1/who'),
          signer
              .sign(
                fingerprint: clientFingerprint,
                secret: clientSecret,
              )
              .toMap(),
        ),
        '200 $clientFingerprint',
      );

      final forged = signer.sign(
        fingerprint: clientFingerprint,
        secret: 'ef' * 32,
      );
      expect(
        await get(base.resolve('/api/v1/who'), forged.toMap()),
        startsWith('401'),
      );

      final request = await client.postUrl(base.resolve('/api/v1/pair/enroll'));
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 200);
    } finally {
      client.close();
      await host.stop();
    }
  });
}
