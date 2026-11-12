import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:diubangwenjian/core/auth/peer_fingerprint_middleware.dart';
import 'package:diubangwenjian/core/common/key_value_store.dart';
import 'package:diubangwenjian/core/host/http_host_service.dart';
import 'package:diubangwenjian/core/identity/peer.dart';
import 'package:diubangwenjian/core/identity/tls_certificate_builder.dart';
import 'package:diubangwenjian/core/pairing/pairing_services.dart';
import 'package:diubangwenjian/features/devices/data/datasources/pairing_remote_data_source.dart';
import 'package:diubangwenjian/features/devices/data/host_endpoints/pairing_endpoint.dart';

/// 真 TLS + 真 Dio enroll。
void main() {
  test('密码配对：PairingRemoteDataSource → Host enroll 闭环', () async {
    final serverTls = TlsCertificateBuilder().generate(deviceLabel: 'host');
    final hostRepo = _MemRepo();
    SharedPreferences.setMockInitialValues({});
    final kvs = KeyValueStore(
      sharedPreferences: await SharedPreferences.getInstance(),
    );
    final pairing = PairingHostService(
      peerRepository: hostRepo,
      keyValueStore: kvs,
      identity: () async => (
            fingerprint: serverTls.fingerprintSha256,
            name: '被配对',
            model: 'M',
            stableIdHash: 'sid-host',
          ),
      localAddress: () => '127.0.0.1',
      port: () => 0,
    );

    final router = Router()
      ..post(
        PairPasswordEndpoint.path,
        PairPasswordEndpoint(hostService: pairing).handler,
      );

    final ctx = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(serverTls.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(serverTls.privateKeyPem));

    final host = HttpHostService(
      port: 0,
      securityContext: Future.value(ctx),
      publicRoutes: router,
      middlewares: [
        peerFingerprintMiddleware(
          peerLookup: (_) async => null,
          exemptPaths: {PairPasswordEndpoint.path},
        ),
      ],
    );
    await host.start();
    addTearDown(host.stop);
    final port = host.boundPort!;

    final client = PairingClientService(peerRepository: _MemRepo());
    final password = (await pairing.beginDisplayRound()).password;
    final sealed = await client.buildPasswordEnroll(
      password: password,
      fingerprint: 'aa' * 32,
      deviceName: '发起',
      model: 'K',
      listenPort: 5244,
    );

    final transport = const PairingRemoteDataSource();
    final sealedResponse = await transport.postEnroll(
      host: '127.0.0.1',
      port: port,
      path: PairPasswordEndpoint.path,
      sealed: sealed,
    );

    expect(sealedResponse, isNotNull);
    final result = await client.consumePasswordResponse(
      password: password,
      sealedResponse: sealedResponse!,
      host: '127.0.0.1',
      port: port,
    );
    expect(result, isNotNull);
    expect(hostRepo.saved, isNotEmpty);
  }, timeout: const Timeout(Duration(seconds: 60)));
}

class _MemRepo implements PeerWriter {
  final saved = <Peer>[];
  @override
  Future<void> upsert(Peer peer) async => saved.add(peer);
}
