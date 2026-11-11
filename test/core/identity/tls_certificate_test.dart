import 'package:flutter_test/flutter_test.dart';

import 'package:diubangwenjian/core/identity/tls_certificate_builder.dart';

void main() {
  final builder = TlsCertificateBuilder();

  test('生成身份材料：PEM 可解析、指纹 64 位十六进制', () {
    final m = builder.generate(deviceLabel: 'TEST-01');

    expect(m.certificatePem, startsWith('-----BEGIN CERTIFICATE'));
    expect(m.privateKeyPem, startsWith('-----BEGIN PRIVATE KEY'));
    expect(
      RegExp(r'^[0-9a-f]{64}$').hasMatch(m.fingerprintSha256),
      isTrue,
      reason: '指纹应为 SHA-256 hex',
    );
  });

  test('指纹可从 PEM 复算且一致（加载缓存复核路径）', () {
    final m = builder.generate(deviceLabel: 'TEST-02');
    expect(builder.fingerprintOf(m.certificatePem), m.fingerprintSha256);
    expect(
      CertificateFingerprint.fromPem(m.certificatePem),
      m.fingerprintSha256,
    );
  });

  test('两次生成指纹不同（随机身份）', () {
    final a = builder.generate(deviceLabel: 'A');
    final b = builder.generate(deviceLabel: 'B');
    expect(a.fingerprintSha256, isNot(b.fingerprintSha256));
  });
}
