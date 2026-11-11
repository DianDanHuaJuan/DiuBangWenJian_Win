import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:diubangwenjian/core/auth/peer_fingerprint_middleware.dart';
import 'package:diubangwenjian/core/host/http_host_service.dart';
import 'package:diubangwenjian/core/identity/migrations.dart' as identity;
import 'package:diubangwenjian/core/identity/peer.dart';
import 'package:diubangwenjian/core/identity/peer_repository.dart';
import 'package:diubangwenjian/core/identity/tls_certificate_builder.dart';
import 'package:diubangwenjian/core/database/app_database.dart';
import 'package:diubangwenjian/core/network/peer_api_client.dart';

/// ping 信任链路端到端集成（真 TLS 宿主 + Bearer + 证书固定客户端）。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('ping 信任链路：成功闭环 + 无 Bearer 裸请求拒绝', () async {
    final serverMaterial =
        TlsCertificateBuilder().generate(deviceLabel: 'server');
    final serverFp = serverMaterial.fingerprintSha256;
    final serverContext = SecurityContext()
      ..useCertificateChainBytes(serverMaterial.certificatePem.codeUnits)
      ..usePrivateKeyBytes(serverMaterial.privateKeyPem.codeUnits);

    final clientFp = 'aa' * 32;
    final secret = '11' * 32;

    final db =
        await AppDatabase(migrations: identity.identityMigrations).database;
    final repo = PeerRepository(db: () => db);
    await repo.upsert(Peer(
      fingerprint: clientFp,
      name: 'client-device',
      model: 'test-model',
      pairedAt: 0,
      secret: secret,
    ));

    final router = Router();
    router.get(
      '/api/v1/ping',
      (Request request) async {
        final peer = request.context[peerKey] as Peer?;
        return Response.ok(
          '{"pong":true,"server":{"name":"server-device",'
          '"fingerprint":"$serverFp"},'
          '"peer":"${peer?.name ?? ""}"}',
          headers: {'content-type': 'application/json'},
        );
      },
    );
    final host = HttpHostService(
      port: 0,
      securityContext: Future.value(serverContext),
      publicRoutes: router,
      middlewares: [
        peerFingerprintMiddleware(peerLookup: repo.findByFingerprint),
      ],
    );
    await host.start();
    final port = host.boundPort!;

    await repo.upsert(Peer(
      fingerprint: serverFp,
      name: 'server-device',
      model: 'server-model',
      pairedAt: 0,
      secret: secret,
      lastSeenAddress: '127.0.0.1:$port',
    ));

    final client = PeerApiClient(
      peerRepository: () async => repo,
      selfFingerprint: clientFp,
    );
    final response = await client.get(serverFp, '/api/v1/ping');

    expect(response, isNotNull);
    expect(response!.statusCode, 200);
    final body = response.data as Map<String, dynamic>;
    expect(body['pong'], isTrue);
    expect(body['server']?['name'], 'server-device');
    expect(body['peer'], 'client-device');

    final bareClient = HttpClient()
      ..badCertificateCallback = (cert, _, _) => true;
    try {
      final request = await bareClient
          .getUrl(Uri.parse('https://127.0.0.1:$port/api/v1/ping'));
      final bareResponse = await request.close();
      expect(bareResponse.statusCode, 401);
    } finally {
      bareClient.close();
    }

    await host.stop();
    await db.close();
  }, timeout: const Timeout(Duration(seconds: 60)));
}
