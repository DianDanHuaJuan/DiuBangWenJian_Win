import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:diubangwenjian/core/common/key_value_store.dart';
import 'package:diubangwenjian/core/identity/device_identity_service.dart';
import 'package:diubangwenjian/core/identity/tls_certificate_manager.dart';
import 'package:diubangwenjian/core/identity/identity_key_store.dart';
import 'package:diubangwenjian/core/pairing/pairing_services.dart';
import 'package:diubangwenjian/features/devices/data/datasources/pairing_remote_data_source.dart';
import 'package:diubangwenjian/features/devices/data/host_endpoints/pairing_endpoint.dart';
import 'package:diubangwenjian/features/devices/presentation/cubits/pairing_flow_cubit.dart';

void main() {
  late KeyValueStore kvs;
  late PairingHostService host;
  late PairingClientService client;
  late DeviceIdentityService identityService;
  late _FakeTransport transport;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    kvs = KeyValueStore(sharedPreferences: await SharedPreferences.getInstance());

    host = PairingHostService(
      peerRepository: _FakeRepo(),
      keyValueStore: kvs,
      identity: () async => (
            fingerprint: '11' * 32,
            name: '被扫机',
            model: 'M2',
            stableIdHash: 'sid-host',
          ),
      localAddress: () => '192.168.1.10',
      port: () => 5244,
    );
    client = PairingClientService(peerRepository: _FakeRepo());

    identityService = DeviceIdentityService(
      certificateManager: TlsCertificateManager(
        keyStore: const IdentityKeyStore(),
      ),
      keyValueStore: kvs,
    );
    transport = _FakeTransport();
  });

  PairingFlowCubit buildCubit() => PairingFlowCubit(
        hostService: Future.value(host),
        clientService: Future.value(client),
        deviceIdentityService: identityService,
        transport: transport,
      );

  group('配对弹层状态机①（doc/04 §4.2）', () {
    test('密码路径成功：idle → running → success', () async {
      final cubit = buildCubit();
      expect(cubit.state, isA<PairingFlowIdle>());

      cubit.startPassword();
      expect(cubit.state, isA<PairingFlowRunning>());
      expect((cubit.state as PairingFlowRunning).mode, PairingMode.password);

      transport.responder = (path, sealed, expectedFingerprint, extra) async {
        expect(path, PairPasswordEndpoint.path);
        expect(expectedFingerprint, isNull);
        return host.handlePasswordEnroll(sealed: sealed);
      };

      final password = (await host.beginDisplayRound()).password;
      await cubit.submitPassword(
        password: password,
        host: '192.168.1.10',
        port: 5244,
      );

      expect(cubit.state, isA<PairingFlowSuccess>());
      expect((cubit.state as PairingFlowSuccess).peerName, '被扫机');
      expect((cubit.state as PairingFlowSuccess).peerFingerprint, isNotEmpty);
    });

    test('密码错误/网络拒绝：→ failed，retry 回 idle', () async {
      final cubit = buildCubit();
      cubit.startPassword();

      transport.responder = (_, _, _, _) async => null;
      await cubit.submitPassword(
        password: 'wrong-password',
        host: '192.168.1.10',
        port: 5244,
      );

      expect(cubit.state, isA<PairingFlowFailed>());
      expect((cubit.state as PairingFlowFailed).message, contains('无法连接'));

      cubit.retry();
      expect(cubit.state, isA<PairingFlowIdle>());
    });

    test('扫码路径成功：scan → enroll → success（X25519 + 指纹固定）', () async {
      final cubit = buildCubit();
      cubit.startScan();
      expect((cubit.state as PairingFlowRunning).mode, PairingMode.scan);

      final round = await host.beginDisplayRound();
      final payload = round.payload;
      transport.responder = (path, sealed, expectedFingerprint, extra) async {
        expect(path, PairingEndpoint.path);
        expect(expectedFingerprint, payload.fingerprint);
        expect(extra?['client_pub'], isNotNull);
        expect(extra?['ticket'], payload.ticket);
        return host.handleQrEnroll(
          sealed: sealed,
          clientPublicKey: extra!['client_pub'] as String,
          ticket: extra['ticket'] as String,
        );
      };

      await cubit.handleScanned(payload.encode());

      expect(cubit.state, isA<PairingFlowSuccess>());
      expect((cubit.state as PairingFlowSuccess).peerName, '被扫机');
      expect((cubit.state as PairingFlowSuccess).peerFingerprint, isNotEmpty);
    });

    test('扫码无效格式：忽略不转移（继续取景）', () async {
      final cubit = buildCubit();
      cubit.startScan();

      await cubit.handleScanned('https://example.com/not-pairing');

      expect(cubit.state, isA<PairingFlowRunning>());
      expect((cubit.state as PairingFlowRunning).mode, PairingMode.scan);
    });
  });
}

class _FakeRepo implements PeerWriter {
  final List<dynamic> saved = [];

  @override
  Future<void> upsert(peer) async => saved.add(peer);
}

class _FakeTransport implements PairingEnrollTransport {
  Future<String?> Function(
    String path,
    String sealed,
    String? expectedFp,
    Map<String, dynamic>? extraBody,
  ) responder = (_, _, _, _) async => null;

  @override
  Future<String?> postEnroll({
    required String host,
    required int port,
    required String path,
    required String sealed,
    String? expectedFingerprint,
    Map<String, dynamic>? extraBody,
  }) =>
      responder(path, sealed, expectedFingerprint, extraBody);
}
