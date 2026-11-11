import 'dart:async';

import '../common/key_value_store.dart';
import 'qr_crypto.dart';

/// 密码配对服务（决策 #15：与扫码引导等效的对等信任）。
///
/// 密码为**展示轮次**凭证：打开连接码时 [beginRound]，关窗/过期 [endRound]。
/// 不再持久化为长期密码。失败限速：连错 [maxFailures] 次锁 [lockout]。
class PairPasswordService {
  static const _kLegacyPassword = 'pairing.password';

  /// 展示轮次默认有效期（与二维码 ticket 对齐）。
  static const roundValidity = Duration(minutes: 3);

  /// 限速：连续失败 [maxFailures] 次锁定 [lockout]。
  static const maxFailures = 5;
  static const lockout = Duration(seconds: 60);

  PairPasswordService({required this.keyValueStore})
      : _crypto = PairingCrypto();

  final KeyValueStore keyValueStore;
  final PairingCrypto _crypto;

  int _failures = 0;
  DateTime? _lockedUntil;

  String? _roundPassword;
  DateTime? _roundExpiresAt;

  /// 开启一轮展示密码；覆盖上一轮。返回新密码。
  String beginRound({Duration validity = roundValidity}) {
    // 清除旧版长期密码，避免误用。
    unawaited(keyValueStore.remove(_kLegacyPassword));
    _roundPassword = _crypto.generatePassword();
    _roundExpiresAt = DateTime.now().add(validity);
    _resetFailures();
    _clearKeyCache();
    // 展示时就算好，对方输完码再来时直接用缓存。
    unawaited(deriveKey(_roundPassword!));
    return _roundPassword!;
  }

  /// 结束当前轮次（关窗 / 过期 / 刷新前）。
  void endRound() {
    _roundPassword = null;
    _roundExpiresAt = null;
    _clearKeyCache();
  }

  /// 当前轮次是否仍有效。
  bool get hasActiveRound {
    final exp = _roundExpiresAt;
    final pwd = _roundPassword;
    if (pwd == null || exp == null) return false;
    if (!DateTime.now().isBefore(exp)) {
      endRound();
      return false;
    }
    return true;
  }

  /// 当前轮次密码；无效时为 null。
  String? get currentPassword => hasActiveRound ? _roundPassword : null;

  /// 当前轮次过期时刻。
  DateTime? get roundExpiresAt => hasActiveRound ? _roundExpiresAt : null;

  /// 服务侧校验：无活跃轮次或锁定中直接拒绝。
  Future<bool> verify(String candidate) async {
    if (isLocked) return false;
    if (!hasActiveRound) return false;

    final expected = _roundPassword!;
    if (candidate == expected) {
      _resetFailures();
      return true;
    }

    _failures++;
    if (_failures >= maxFailures) {
      _lockedUntil = DateTime.now().add(lockout);
    }
    return false;
  }

  /// 当前是否处于锁定窗口。
  bool get isLocked {
    final until = _lockedUntil;
    if (until == null) return false;
    if (DateTime.now().isAfter(until)) {
      _lockedUntil = null;
      return false;
    }
    return true;
  }

  /// 剩余锁定秒数（UI 提示用；未锁定返回 0）。
  int get remainingLockSeconds {
    final until = _lockedUntil;
    if (until == null || !isLocked) return 0;
    return until.difference(DateTime.now()).inSeconds;
  }

  /// 客户侧 / 宿主侧：密码派生密钥（PBKDF2 较慢，按密码缓存）。
  Future<List<int>> deriveKey(String password) async {
    if (_cachedPassword == password && _cachedKey != null) {
      return _cachedKey!;
    }
    final key = await _crypto.deriveKeyFromPassword(password);
    if (_roundPassword == password) {
      _cachedPassword = password;
      _cachedKey = key;
    }
    return key;
  }

  void _resetFailures() {
    _failures = 0;
    _lockedUntil = null;
  }

  void _clearKeyCache() {
    _cachedPassword = null;
    _cachedKey = null;
    _crypto.clearPasswordKey();
  }

  String? _cachedPassword;
  List<int>? _cachedKey;
}

/// 一次性票据 + X25519 会话私钥（配对会话防重放）。
class PairingTicketRegistry {
  /// 票据有效期（与连接码展示轮次对齐）。
  static const validity = Duration(minutes: 3);

  final PairingCrypto _crypto;
  final Map<String, _TicketSession> _issued = {};

  PairingTicketRegistry({PairingCrypto? crypto})
      : _crypto = crypto ?? PairingCrypto();

  /// 签发新票据并绑定宿主临时私钥（生成二维码时）。
  String issue({required List<int> privateKeyBytes}) {
    final ticket = _crypto.generateTicket();
    _issued[ticket] = _TicketSession(
      issuedAt: DateTime.now(),
      privateKeyBytes: List<int>.from(privateKeyBytes),
    );
    _sweepExpired();
    return ticket;
  }

  /// 主动会话私钥（不消费；解密前用）。
  List<int>? peekPrivateKey(String ticket) {
    _sweepExpired();
    return _issued[ticket]?.privateKeyBytes;
  }

  /// 消费票据（enroll 校验时）：有效且未用 → 消费成功并移除。
  bool consume(String ticket) {
    _sweepExpired();
    final session = _issued.remove(ticket);
    return session != null;
  }

  /// 主动展示轮次票据（关窗 / 过期 / 刷新）。
  void revoke(String ticket) {
    _issued.remove(ticket);
  }

  void _sweepExpired() {
    final now = DateTime.now();
    _issued.removeWhere((_, s) => now.difference(s.issuedAt) > validity);
  }
}

class _TicketSession {
  const _TicketSession({
    required this.issuedAt,
    required this.privateKeyBytes,
  });

  final DateTime issuedAt;
  final List<int> privateKeyBytes;
}
