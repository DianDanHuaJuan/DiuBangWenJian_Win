import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 物理设备稳定线索（重装后用于配对合并，不参与授权）。
///
/// Windows：优先 `WindowsDeviceInfo.deviceId`；失败则 Secure Storage 兜底。
class StableDeviceIdService {
  StableDeviceIdService({
    DeviceInfoPlugin? deviceInfo,
    FlutterSecureStorage? secureStorage,
    Future<String?> Function()? windowsIdResolver,
  })  : _deviceInfo = deviceInfo ?? DeviceInfoPlugin(),
        _secureStorage = secureStorage ?? const FlutterSecureStorage(),
        _windowsIdResolver = windowsIdResolver;

  static const _fallbackKey = 'identity.stable_device_id.fallback';
  static const _hashSalt = 'diubangwenjian.stable.v1';

  final DeviceInfoPlugin _deviceInfo;
  final FlutterSecureStorage _secureStorage;
  final Future<String?> Function()? _windowsIdResolver;

  String? _cachedHash;

  /// 对外交换用的稳定 ID 哈希（hex SHA-256），永不回传明文物理 ID。
  Future<String> stableIdHash() async {
    if (_cachedHash != null) return _cachedHash!;
    final raw = await _resolveRawId();
    final hash = hashStableId(raw);
    _cachedHash = hash;
    return hash;
  }

  /// 纯函数：明文 → 哈希（单测 / 对端比对用同一算法）。
  static String hashStableId(String rawId) {
    final bytes = utf8.encode('$_hashSalt|$rawId');
    return sha256.convert(bytes).toString();
  }

  Future<String> _resolveRawId() async {
    final id = await _resolveWindowsId();
    if (id != null && id.isNotEmpty) return id;
    return _loadOrCreateFallback();
  }

  Future<String?> _resolveWindowsId() async {
    try {
      if (_windowsIdResolver != null) {
        final custom = await _windowsIdResolver();
        final n = custom?.trim().toLowerCase();
        if (n != null && n.isNotEmpty) return n;
      }
      final info = await _deviceInfo.windowsInfo;
      final id = info.deviceId.trim().toLowerCase();
      return id.isEmpty ? null : id;
    } catch (_) {
      return null;
    }
  }

  Future<String> _loadOrCreateFallback() async {
    try {
      final existing = await _secureStorage.read(key: _fallbackKey);
      if (existing != null && existing.isNotEmpty) return existing;
      final created =
          'fb-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}'
          '-${Object().hashCode.toRadixString(16)}';
      await _secureStorage.write(key: _fallbackKey, value: created);
      return created;
    } catch (_) {
      return 'fb-ephemeral-${DateTime.now().microsecondsSinceEpoch}';
    }
  }
}
