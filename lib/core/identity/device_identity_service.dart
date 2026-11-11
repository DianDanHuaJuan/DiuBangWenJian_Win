import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

import '../common/key_value_store.dart';
import 'device_emoji_presets.dart';
import 'tls_certificate_manager.dart';

/// 本机身份自省（doc/02 core/identity：device_identity_service）。
/// 汇集：TLS 指纹（Device ID）、显示名、型号、展示 emoji。
/// 显示名 / emoji 仅为别名展示，不参与身份主键。
class DeviceIdentity {
  const DeviceIdentity({
    required this.fingerprint,
    required this.deviceName,
    required this.model,
    this.brand = '',
    this.emoji = '',
  });

  final String fingerprint;
  final String deviceName;
  final String model;
  final String brand;

  /// 展示用 emoji（UDP announce / WS static 对外广播）。
  final String emoji;
}

class DeviceIdentityService {
  DeviceIdentityService({
    required this.certificateManager,
    KeyValueStore? keyValueStore,
  })  : _keyValueStore = keyValueStore,
        _deviceInfo = DeviceInfoPlugin();

  static const _kNameOverride = 'identity.name_override';
  static const _kEmoji = 'identity.emoji';

  /// 单项采集上限（平台通道无响应/极慢时兜底，不让概览卡永久等待）。
  static const _collectTimeout = Duration(seconds: 5);

  /// 指纹失败时最多再试几次（不把失败结果永久写进缓存）。
  static const _fingerprintAttempts = 3;

  final TlsCertificateManager certificateManager;
  final KeyValueStore? _keyValueStore;
  final DeviceInfoPlugin _deviceInfo;

  DeviceIdentity? _cached;
  String? _nameOverride;
  String? _emoji;
  String? _cachedModel;
  String? _cachedBrand;
  String? _cachedDefaultName;

  /// 同步缓存视图（发现服务 announce 快照用；未就绪为 null）。
  DeviceIdentity? get cachedIdentity => _cached;

  /// 当前身份。指纹未就绪时不写入永久缓存，下次调用会重试。
  Future<DeviceIdentity> get identity async {
    if (_cached != null) return _cached!;

    final fingerprint = await _loadFingerprint();

    await _ensureDeviceInfo();
    _nameOverride ??= _keyValueStore?.getString(_kNameOverride);
    await _ensureEmojiAssigned();

    final identity = DeviceIdentity(
      fingerprint: fingerprint ?? 'unavailable',
      deviceName: _nameOverride ?? _cachedDefaultName ?? '未知设备',
      model: _cachedModel ?? 'unknown',
      brand: _cachedBrand ?? '',
      emoji: _emoji ?? '',
    );

    // 只有拿到合法 Device ID 才缓存，避免把 unavailable 冻死一整次进程
    if (fingerprint != null) {
      _cached = identity;
    }
    return identity;
  }

  /// 强制下次重新采集指纹（例如证书刚写回后）。
  void invalidateCache() {
    _cached = null;
  }

  Future<String?> _loadFingerprint() async {
    for (var i = 0; i < _fingerprintAttempts; i++) {
      try {
        final fp = await certificateManager.fingerprint.timeout(
          _collectTimeout,
        );
        if (_isValidFingerprint(fp)) return fp;
      } catch (_) {}
    }
    return null;
  }

  Future<void> _ensureDeviceInfo() async {
    if (_cachedModel != null && _cachedDefaultName != null) return;
    // 对齐旧 Windows NAS：本机名用 hostname；品牌/型号取 Windows 产品信息。
    try {
      final hostname = Platform.localHostname.trim();
      final win = await _deviceInfo.windowsInfo.timeout(_collectTimeout);
      final product = win.productName.trim();
      final computer = win.computerName.trim();
      _cachedBrand = 'Windows';
      _cachedModel = product.isNotEmpty
          ? product
          : (computer.isNotEmpty ? computer : Platform.operatingSystemVersion);
      _cachedDefaultName = hostname.isNotEmpty
          ? hostname
          : (computer.isNotEmpty ? computer : '铥棒文件');
    } catch (_) {
      final hostname = Platform.localHostname.trim();
      _cachedBrand ??= 'Windows';
      _cachedModel ??= Platform.operatingSystemVersion;
      _cachedDefaultName ??=
          hostname.isNotEmpty ? hostname : '铥棒文件';
    }
  }

  /// 首次安装（prefs 无 emoji 键）随机分配一个并持久化。
  Future<void> _ensureEmojiAssigned() async {
    if (_emoji != null) return;
    final store = _keyValueStore;
    if (store == null) {
      _emoji = '';
      return;
    }
    if (store.containsKey(_kEmoji)) {
      _emoji = store.getString(_kEmoji) ?? '';
      return;
    }
    final picked = DeviceEmojiPresets.random();
    _emoji = picked;
    await store.setString(_kEmoji, picked);
  }

  static bool _isValidFingerprint(String fp) =>
      RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(fp);

  /// 冷总线 apply：prefs 已 reload 后重读展示字段并打补丁缓存。
  void reloadDisplayFromStore() {
    final store = _keyValueStore;
    if (store == null) return;
    _nameOverride = store.getString(_kNameOverride);
    _emoji = store.containsKey(_kEmoji) ? (store.getString(_kEmoji) ?? '') : '';
    _patchCache(
      deviceName: _nameOverride ?? _cachedDefaultName,
      emoji: _emoji,
    );
  }

  /// 改显示名（别名；持久化到 KeyValueStore）。
  Future<void> rename(String newName) async {
    final name = newName.trim();
    if (name.isEmpty) return;
    _nameOverride = name;
    await _keyValueStore?.setString(_kNameOverride, name);
    _patchCache(deviceName: name);
  }

  /// 设置展示 emoji（别名；空串表示清除）。
  Future<void> setEmoji(String emoji) async {
    final value = emoji.trim();
    _emoji = value;
    if (value.isEmpty) {
      await _keyValueStore?.remove(_kEmoji);
    } else {
      await _keyValueStore?.setString(_kEmoji, value);
    }
    _patchCache(emoji: value);
  }

  void _patchCache({String? deviceName, String? emoji}) {
    final old = _cached;
    if (old == null) return;
    _cached = DeviceIdentity(
      fingerprint: old.fingerprint,
      deviceName: deviceName ?? old.deviceName,
      model: old.model,
      brand: old.brand,
      emoji: emoji ?? old.emoji,
    );
  }

  /// 服务端 SecurityContext 直通（宿主 bindSecure 用）。
  Future<SecurityContext> serverSecurityContext() =>
      certificateManager.serverSecurityContext();
}
