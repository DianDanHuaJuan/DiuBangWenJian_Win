/// peer 实体（doc/01 §五 peers 表）：指纹=主键，删行即吊销（决策 #2）。
class Peer {
  const Peer({
    required this.fingerprint,
    required this.name,
    required this.model,
    required this.pairedAt,
    required this.secret,
    this.brand = '',
    this.emoji = '',
    this.lastSeenAddress,
    this.stableIdHash,
  });

  /// 对端证书 SHA-256 指纹（Device ID，主键；重装会变）。
  final String fingerprint;

  /// 配对时经加密 enroll 通道交换的 Bearer 共享密钥（hex，32 字节）。
  /// 空串 = 无 secret（未完成新协议配对），认证中间件拒绝。
  final String secret;

  /// 显示名（配对时带入，可改名）。
  final String name;

  /// 品牌（announce / enroll / WS 首帧写入；持久化）。
  final String brand;

  /// 设备型号（配对时带入）。
  final String model;

  /// 展示用 emoji（announce / WS static；本机别名体系，非身份主键）。
  final String emoji;

  /// 配对时间（Unix 毫秒）；同物理设备合并时保留首次配对时间。
  final int pairedAt;

  /// 最近一次已知地址（host:port，announce/enroll 更新）。
  final String? lastSeenAddress;

  /// 对端稳定物理线索哈希（重装认旧用；空=未知，不做合并）。
  final String? stableIdHash;

  Peer copyWith({
    String? name,
    String? brand,
    String? model,
    String? emoji,
    String? lastSeenAddress,
    String? secret,
    int? pairedAt,
    String? stableIdHash,
    bool clearStableIdHash = false,
  }) =>
      Peer(
        fingerprint: fingerprint,
        name: name ?? this.name,
        brand: brand ?? this.brand,
        model: model ?? this.model,
        emoji: emoji ?? this.emoji,
        pairedAt: pairedAt ?? this.pairedAt,
        secret: secret ?? this.secret,
        lastSeenAddress: lastSeenAddress ?? this.lastSeenAddress,
        stableIdHash:
            clearStableIdHash ? null : (stableIdHash ?? this.stableIdHash),
      );

  Map<String, Object?> toMap() => {
        'fingerprint': fingerprint,
        'name': name,
        'brand': brand,
        'model': model,
        'emoji': emoji,
        'paired_at': pairedAt,
        'last_seen_address': lastSeenAddress,
        'secret': secret,
        'stable_id_hash': stableIdHash,
      };

  static Peer fromMap(Map<String, Object?> map) => Peer(
        fingerprint: map['fingerprint']! as String,
        name: map['name']! as String,
        brand: map['brand'] as String? ?? '',
        model: map['model']! as String,
        emoji: map['emoji'] as String? ?? '',
        pairedAt: map['paired_at']! as int,
        secret: map['secret'] as String? ?? '',
        lastSeenAddress: map['last_seen_address'] as String?,
        stableIdHash: map['stable_id_hash'] as String?,
      );
}
