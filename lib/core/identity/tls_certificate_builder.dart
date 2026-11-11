import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';

/// 全项目统一的证书指纹算法（Device ID / QR / TLS 钉扎同一套）。
///
/// 算法：证书二进制（DER）→ SHA-256 → 小写 hex。
/// PEM 只是把 DER 包了一层 Base64；先撕开再哈希。
///
/// 实测（logA/logB）：本机 PEM 解码字节与握手 `cert.der` 逐字节相同，
/// 故 [fromPem] 与 [fromDer] 结果一致。
abstract final class CertificateFingerprint {
  /// 从证书 PEM 计算指纹（身份生成、二维码、落库）。
  static String fromPem(String certificatePem) =>
      fromDer(CryptoUtils.getBytesFromPEMString(certificatePem));

  /// 从 DER 字节计算指纹（握手 `X509Certificate.der` 钉扎）。
  static String fromDer(List<int> derBytes) =>
      sha256.convert(derBytes).toString();
}

/// 生成的设备 TLS 材料（EC P-256 自签单证书，无 CA 层——doc/01 §六）。
class DeviceTlsMaterial {
  const DeviceTlsMaterial({
    required this.certificatePem,
    required this.privateKeyPem,
    required this.fingerprintSha256,
  });

  /// PEM 编码证书（自签，subject=issuer）。
  final String certificatePem;

  /// PEM 编码私钥（PKCS#8）。
  final String privateKeyPem;

  /// Device ID = [CertificateFingerprint.fromPem]。
  final String fingerprintSha256;
}

/// EC P-256 自签证书生成器（决策 #2：无 CA 层，每设备一张身份证书）。
class TlsCertificateBuilder {
  static const _validityDays = 3650; // 10 年：设备身份，不轮换

  /// 生成一套全新身份材料。
  DeviceTlsMaterial generate({required String deviceLabel}) {
    final keyPair = CryptoUtils.generateEcKeyPair();
    final privateKey = keyPair.privateKey as ECPrivateKey;
    final publicKey = keyPair.publicKey as ECPublicKey;

    final attributes = <String, String>{
      'CN': 'DiuBangWenJian $deviceLabel',
      'O': 'DiuBangWenJian',
    };

    final csrPem = X509Utils.generateEccCsrPem(
      attributes,
      privateKey,
      publicKey,
    );
    final certificatePem = X509Utils.generateSelfSignedCertificate(
      privateKey,
      csrPem,
      _validityDays,
    );

    return DeviceTlsMaterial(
      certificatePem: certificatePem,
      privateKeyPem: CryptoUtils.encodePrivateEcdsaKeyToPkcs8(privateKey),
      fingerprintSha256: CertificateFingerprint.fromPem(certificatePem),
    );
  }

  /// 从 PEM 复算指纹（加载已有证书时复核）。
  String fingerprintOf(String certificatePem) =>
      CertificateFingerprint.fromPem(certificatePem);
}
