import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'tls_certificate_builder.dart';

/// 身份材料私钥存储（doc/02 core/identity：identity_key_store）。
///
/// flutter_secure_storage 落地（阶段 1 执行口径：Kotlin 私钥桥保留空实现
/// 不接，secure_storage 安全等级足够）。键：证书/私钥/指纹三键一组。
class IdentityKeyStore {
  static const _kCert = 'identity.certificate.pem';
  static const _kKey = 'identity.private_key.pem';
  static const _kFp = 'identity.fingerprint.sha256';

  const IdentityKeyStore({FlutterSecureStorage storage = const FlutterSecureStorage()})
      : _storage = storage;

  final FlutterSecureStorage _storage;

  Future<DeviceTlsMaterial?> load() async {
    final cert = await _storage.read(key: _kCert);
    final key = await _storage.read(key: _kKey);
    final fp = await _storage.read(key: _kFp);
    if (cert == null || key == null || fp == null) return null;
    return DeviceTlsMaterial(
      certificatePem: cert,
      privateKeyPem: key,
      fingerprintSha256: fp,
    );
  }

  Future<void> save(DeviceTlsMaterial material) async {
    await _storage.write(key: _kCert, value: material.certificatePem);
    await _storage.write(key: _kKey, value: material.privateKeyPem);
    await _storage.write(key: _kFp, value: material.fingerprintSha256);
  }
}
