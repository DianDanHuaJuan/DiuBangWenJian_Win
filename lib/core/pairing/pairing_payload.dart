import 'dart:convert';

/// NASPAIR4 配对载荷（doc/02 core/pairing：pairing_payload）。
///
/// 二维码内容（瘦身 A）：`NASPAIR4:<json>`，**不再**套一层 base64。
/// 线上仅保留连接与密码学必要字段：`v/host/port/fp/t/pk`。
/// - `fp`：证书指纹，线上为 32 字节的 base64url（内存/库表仍为 hex）
/// - `t`：一次性票据（短 base64url）
/// - `name`/`model`/`sid`：不进二维码，由 enroll 回包交换
///
/// [decode] 仍兼容旧版 `NASPAIR4:<base64url(json)>`（含 name/model/sid）。
class PairingPayload {
  const PairingPayload({
    required this.version,
    required this.host,
    required this.port,
    required this.deviceName,
    required this.model,
    required this.fingerprint,
    required this.ticket,
    required this.serverPublicKey,
    this.stableIdHash,
  });

  static const supportedVersion = 4;
  static const _prefix = 'NASPAIR4:';

  /// 协议版本（向后不兼容时递增）。
  final int version;

  /// 被扫方地址（IP 或主机名）。
  final String host;

  /// 被扫方配对端点端口。
  final int port;

  /// 被扫方设备名（仅内存/旧码；新码不编码，靠 enroll 回包）。
  final String deviceName;

  /// 被扫方设备型号（仅内存/旧码；新码不编码）。
  final String model;

  /// 被扫方证书指纹（hex SHA-256；扫码方校验 enroll 回包一致才入表）。
  final String fingerprint;

  /// 一次性票据（enroll 时带回，防重放）。
  final String ticket;

  /// 被扫方 X25519 临时公钥（base64url），扫码方用来协商会话密钥。
  final String serverPublicKey;

  /// 被扫方稳定物理线索哈希（可选；新码不进二维码）。
  final String? stableIdHash;

  /// 线上精简 JSON（供二维码）；不含 name/model/sid。
  Map<String, Object?> toWireJson() => {
        'v': version,
        'host': host,
        'port': port,
        'fp': fingerprintToWire(fingerprint),
        't': ticket,
        'pk': serverPublicKey,
      };

  /// 编码为二维码字符串（紧凑 JSON，无外层 base64）。
  String encode() => '$_prefix${jsonEncode(toWireJson())}';

  /// 解析二维码字符串；版本不符/格式错误返回 null。
  static PairingPayload? decode(String raw) {
    if (!raw.startsWith(_prefix)) return null;
    final body = raw.substring(_prefix.length);
    final json = _parseBody(body);
    if (json == null) return null;
    try {
      final sid = json['sid'] as String?;
      final ticket = (json['t'] as String?) ?? (json['ticket'] as String?) ?? '';
      final payload = PairingPayload(
        version: json['v'] as int,
        host: json['host'] as String,
        port: json['port'] as int,
        deviceName: (json['name'] as String?) ?? '',
        model: (json['model'] as String?) ?? '',
        fingerprint: fingerprintFromWire(json['fp'] as String? ?? ''),
        ticket: ticket,
        serverPublicKey: json['pk'] as String? ?? '',
        stableIdHash: (sid != null && sid.isNotEmpty) ? sid : null,
      );
      if (payload.version != supportedVersion) return null;
      if (payload.host.isEmpty) return null;
      if (payload.fingerprint.isEmpty) return null;
      if (payload.ticket.isEmpty) return null;
      if (payload.serverPublicKey.isEmpty) return null;
      return payload;
    } catch (_) {
      return null;
    }
  }

  /// 先按新格式（裸 JSON）解析，失败再试旧 base64url(JSON)。
  static Map<String, dynamic>? _parseBody(String body) {
    try {
      final direct = jsonDecode(body);
      if (direct is Map<String, dynamic>) return direct;
    } catch (_) {}
    try {
      final decoded = utf8.decode(base64Url.decode(base64Url.normalize(body)));
      final legacy = jsonDecode(decoded);
      if (legacy is Map<String, dynamic>) return legacy;
    } catch (_) {}
    return null;
  }

  /// hex SHA-256 → 线上 base64url（无填充）；已是短 base64 则原样返回。
  static String fingerprintToWire(String fingerprint) {
    final hex = fingerprint.trim().toLowerCase();
    if (hex.length == 64 && _isHex(hex)) {
      final bytes = _hexToBytes(hex);
      return base64Url.encode(bytes).replaceAll('=', '');
    }
    return fingerprint;
  }

  /// 线上 fp → 内存 hex；已是 64 位 hex 则规范化小写。
  static String fingerprintFromWire(String wire) {
    final s = wire.trim();
    if (s.length == 64 && _isHex(s)) return s.toLowerCase();
    try {
      final bytes = base64Url.decode(base64Url.normalize(s));
      if (bytes.length == 32) return _bytesToHex(bytes);
    } catch (_) {}
    return s;
  }

  static bool _isHex(String s) => RegExp(r'^[0-9a-fA-F]+$').hasMatch(s);

  static List<int> _hexToBytes(String hex) {
    final out = List<int>.filled(hex.length ~/ 2, 0);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
