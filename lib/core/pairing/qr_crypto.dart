import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// 配对 enroll 载荷加密（doc/02 core/pairing：qr_crypto）。
///
/// 扫码：X25519 临时密钥协商 → HKDF-SHA256 派生 AES-256-GCM 会话密钥。
/// 密码：PBKDF2-SHA256 派生同一长度密钥，复用 seal/open。
class PairingCrypto {
  static const _pairingInfo = 'diubangwenjian/pairing/v1';

  /// X25519 密钥对（临时，仅配对会话期间存活）。
  Future<SimpleKeyPair> generateEphemeralKeyPair() => X25519().newKeyPair();

  /// 提取公钥字节（二维码 / enroll 请求携带）。
  Future<List<int>> publicKeyBytes(SimpleKeyPair keyPair) async {
    final publicKey = await keyPair.extractPublicKey();
    return publicKey.bytes;
  }

  /// 从原始私钥字节重建密钥对（宿主侧按 ticket 取回会话私钥）。
  Future<SimpleKeyPair> keyPairFromPrivateBytes(List<int> privateKeyBytes) =>
      X25519().newKeyPairFromSeed(privateKeyBytes);

  /// 生成 8 位纯数字配对密码（局域网场景，便于口述/手输）。
  String generatePassword() {
    final random = Random.secure();
    return List.generate(8, (_) => random.nextInt(10).toString()).join();
  }

  /// X25519 协商 + HKDF 派生共享密钥。
  Future<List<int>> deriveSharedKey({
    required SimpleKeyPair ephemeralPrivate,
    required List<int> peerPublicKeyBytes,
  }) async {
    final sharedSecret = await X25519().sharedSecretKey(
      keyPair: ephemeralPrivate,
      remotePublicKey: SimplePublicKey(
        peerPublicKeyBytes,
        type: KeyPairType.x25519,
      ),
    );
    final secretBytes = await sharedSecret.extractBytes();
    final derived = await Hkdf(
      hmac: Hmac.sha256(),
      outputLength: 32,
    ).deriveKey(
      secretKey: SecretKey(secretBytes),
      info: utf8.encode(_pairingInfo),
      nonce: const <int>[],
    );
    return derived.extractBytes();
  }

  /// 一轮 8 位配对码的工作因子。不是长期存库密码，局域网里 4096 轮足够。
  static const passwordKdfIterations = 4096;

  /// 密码派生密钥（PBKDF2-SHA256）。同一密码只算一次，进行中的计算会共用。
  Future<List<int>> deriveKeyFromPassword(String password) {
    if (_cachedPassword == password && _cachedPasswordKey != null) {
      return Future<List<int>>.value(_cachedPasswordKey!);
    }
    final pending = _pendingKey;
    if (pending != null && _pendingPassword == password) return pending;
    final future = _computePasswordKey(password);
    _pendingPassword = password;
    _pendingKey = future;
    return future;
  }

  void clearPasswordKey() {
    _cachedPassword = null;
    _cachedPasswordKey = null;
    _pendingPassword = null;
  }

  Future<List<int>> _computePasswordKey(String password) async {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: passwordKdfIterations,
      bits: 256,
    );
    final key = await kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: utf8.encode('diubangwenjian/pair-password'),
    );
    final bytes = await key.extractBytes();
    if (_pendingPassword == password) {
      _cachedPassword = password;
      _cachedPasswordKey = bytes;
      _pendingPassword = null;
      _pendingKey = null;
    }
    return bytes;
  }

  String? _cachedPassword;
  List<int>? _cachedPasswordKey;
  String? _pendingPassword;
  Future<List<int>>? _pendingKey;

  /// AES-256-GCM 加密（enroll 载荷）。
  Future<String> seal({
    required List<int> key,
    required Map<String, Object?> plaintext,
  }) async {
    final nonce = Uint8List.fromList(
      List.generate(12, (_) => Random.secure().nextInt(256)),
    );
    final secretBox = await AesGcm.with256bits().encrypt(
      utf8.encode(jsonEncode(plaintext)),
      secretKey: SecretKey(key),
      nonce: nonce,
    );
    final combined = [...nonce, ...secretBox.cipherText, ...secretBox.mac.bytes];
    return base64Url.encode(combined);
  }

  /// AES-256-GCM 解密（配对端点收到 enroll 时）。
  Future<Map<String, dynamic>?> open({
    required List<int> key,
    required String sealed,
  }) async {
    try {
      final combined = base64Url.decode(sealed);
      final nonce = combined.sublist(0, 12);
      final mac = combined.sublist(combined.length - 16);
      final cipherText = combined.sublist(12, combined.length - 16);
      final clear = await AesGcm.with256bits().decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(key),
      );
      return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// 一次性票据：随机 16 字节 → base64url（无填充，约 22 字符，短于旧 hex）。
  String generateTicket() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}
