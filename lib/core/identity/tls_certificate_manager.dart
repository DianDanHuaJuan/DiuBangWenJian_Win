import 'dart:convert';
import 'dart:io';

import '../common/app_logger.dart';
import 'identity_key_store.dart';
import 'tls_certificate_builder.dart';

/// 证书加载/缓存；Device ID = [CertificateFingerprint.fromPem]。
class TlsCertificateManager {
  TlsCertificateManager({required this.keyStore})
      : _builder = TlsCertificateBuilder();

  final IdentityKeyStore keyStore;
  final TlsCertificateBuilder _builder;

  Future<DeviceTlsMaterial>? _materialFuture;

  Future<DeviceTlsMaterial> get material =>
      _materialFuture ??= _loadOrGenerate();

  Future<String> get fingerprint async => (await material).fingerprintSha256;

  Future<SecurityContext> clientSecurityContext() async =>
      _securityContext(await material);

  Future<SecurityContext> serverSecurityContext() async =>
      _securityContext(await material);

  SecurityContext _securityContext(DeviceTlsMaterial m) {
    final context = SecurityContext(withTrustedRoots: false);
    context.useCertificateChainBytes(utf8.encode(m.certificatePem));
    context.usePrivateKeyBytes(utf8.encode(m.privateKeyPem));
    return context;
  }

  Future<DeviceTlsMaterial> _loadOrGenerate() async {
    final stored = await keyStore.load();
    if (stored != null) {
      try {
        final fp = _builder.fingerprintOf(stored.certificatePem);
        if (fp == stored.fingerprintSha256) {
          return stored;
        }
        // 指纹算法统一后：以 PEM 复算为准写回
        final fixed = DeviceTlsMaterial(
          certificatePem: stored.certificatePem,
          privateKeyPem: stored.privateKeyPem,
          fingerprintSha256: fp,
        );
        await keyStore.save(fixed);
        AppLogger.log(
          'fingerprint refreshed from PEM',
          scope: 'identity',
          details: {'was': stored.fingerprintSha256, 'now': fp},
        );
        return fixed;
      } catch (_) {
        // 损坏则重新生成
      }
    }

    final generated = _builder.generate(deviceLabel: _randomLabel());
    await keyStore.save(generated);
    return generated;
  }

  String _randomLabel() {
    final r = DateTime.now().microsecondsSinceEpoch % 1000000;
    return 'D$r';
  }
}
