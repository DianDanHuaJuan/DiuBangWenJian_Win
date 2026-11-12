import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../common/app_logger.dart';
import '../common/key_value_store.dart';
import '../identity/peer.dart';
import '../network/peer_address.dart';
import 'pair_password_service.dart';
import 'pairing_payload.dart';
import 'qr_crypto.dart';

/// 配对落表最小接口（peer_repository 实现之；测试可注入内存版）。
abstract class PeerWriter {
  Future<void> upsert(Peer peer);
}

/// 连接码展示轮次（二维码 + 配对密码，同寿同期）。
class PairingDisplayRound {
  const PairingDisplayRound({
    required this.payload,
    required this.password,
    required this.expiresAt,
  });

  final PairingPayload payload;
  final String password;
  final DateTime expiresAt;
}

/// enroll 请求体（两条引导路径共用，加密后传输）。
class EnrollRequest {
  const EnrollRequest({
    required this.ticket,
    required this.fingerprint,
    required this.deviceName,
    required this.model,
    this.brand = '',
    this.listenPort,
    this.stableIdHash,
  });

  /// 被扫方签发的一次性票据（扫码路径）；密码路径为空串。
  final String ticket;

  /// 发起方（扫码/输密码方）证书指纹。
  final String fingerprint;

  final String deviceName;
  final String brand;
  final String model;

  /// 发起方常驻宿主监听端口（被扫方写 lastSeenAddress 用）。
  final int? listenPort;

  /// 发起方稳定物理线索哈希（重装认旧；可选）。
  final String? stableIdHash;

  Map<String, Object?> toJson() => {
        'ticket': ticket,
        'fp': fingerprint,
        'name': deviceName,
        'brand': brand,
        'model': model,
        'listenPort': listenPort,
        if (stableIdHash != null && stableIdHash!.isNotEmpty)
          'sid': stableIdHash,
      };

  static EnrollRequest fromJson(Map<String, dynamic> json) {
    final sid = json['sid'] as String?;
    return EnrollRequest(
      ticket: json['ticket'] as String? ?? '',
      fingerprint: json['fp'] as String,
      deviceName: json['name'] as String,
      brand: json['brand'] as String? ?? '',
      model: json['model'] as String,
      listenPort: (json['listenPort'] as num?)?.toInt(),
      stableIdHash: (sid != null && sid.isNotEmpty) ? sid : null,
    );
  }
}

/// enroll 应答体（服务方回写自己的身份 + 共享 secret）。
class EnrollResponse {
  const EnrollResponse({
    required this.fingerprint,
    required this.deviceName,
    required this.model,
    required this.secret,
    this.brand = '',
    this.stableIdHash,
  });

  final String fingerprint;
  final String deviceName;
  final String brand;
  final String model;

  /// 配对时签发的 Bearer 共享密钥（hex 64 字符），仅在加密应答通道内回传。
  final String secret;

  /// 服务方稳定物理线索哈希（重装认旧；可选）。
  final String? stableIdHash;

  Map<String, Object?> toJson() => {
        'fp': fingerprint,
        'name': deviceName,
        'brand': brand,
        'model': model,
        'secret': secret,
        if (stableIdHash != null && stableIdHash!.isNotEmpty)
          'sid': stableIdHash,
      };

  static EnrollResponse fromJson(Map<String, dynamic> json) {
    final sid = json['sid'] as String?;
    return EnrollResponse(
      fingerprint: json['fp'] as String,
      deviceName: json['name'] as String,
      brand: json['brand'] as String? ?? '',
      model: json['model'] as String,
      secret: json['secret'] as String? ?? '',
      stableIdHash: (sid != null && sid.isNotEmpty) ? sid : null,
    );
  }
}

/// 配对结果（client 侧落表用）。
class PairingResult {
  const PairingResult({
    required this.peer,
    required this.host,
    required this.port,
  });

  final Peer peer;
  final String host;
  final int port;
}

/// 扫码方构造的加密 enroll 包（含己方临时公钥，供宿主协商）。
class QrEnrollPackage {
  const QrEnrollPackage({
    required this.sealed,
    required this.clientPublicKey,
    required this.sessionKey,
  });

  final String sealed;
  final String clientPublicKey;
  final List<int> sessionKey;
}

/// 本机身份回调（避免 PairingHostService 依赖 DeviceIdentityService 具体类）。
typedef LocalIdentityProvider = Future<
    ({
      String fingerprint,
      String name,
      String brand,
      String model,
      String stableIdHash,
    })> Function();

/// 被配对侧（服务方）：生成二维码 + 处理 enroll + 写 peer 表。
///
/// 扫码与密码两条引导共用 enroll 落表路径（决策 #15：等效信任）。
class PairingHostService {
  PairingHostService({
    required this.peerRepository,
    required this.keyValueStore,
    required this.identity,
    required this.localAddress,
    required this.port,
    this.onPeerWritten,
    PairingTicketRegistry? ticketRegistry,
    PairPasswordService? passwordService,
    PairingCrypto? crypto,
  })  : _ticketRegistry = ticketRegistry ?? PairingTicketRegistry(),
        _passwordService =
            passwordService ?? PairPasswordService(),
        _crypto = crypto ?? PairingCrypto();

  final PeerWriter peerRepository;
  final KeyValueStore keyValueStore;
  final LocalIdentityProvider identity;

  /// 本机局域网地址（每次展码读取，支持换网 / 用户改选网卡）。
  final String Function() localAddress;

  /// 监听端口（每次展码读取，支持概览改端口即时生效）。
  final int Function() port;

  /// enroll 落表后钩子（刷新 UI / 组播宣告）。
  final Future<void> Function(Peer peer)? onPeerWritten;

  final PairingTicketRegistry _ticketRegistry;
  final PairPasswordService _passwordService;
  final PairingCrypto _crypto;

  /// 当前连接码展示轮次绑定的 ticket（关窗/过期时撤销）。
  String? _activeDisplayTicket;

  /// 打开连接码：开启一轮（密码 + QR ticket），约 3 分钟；覆盖上一轮。
  Future<PairingDisplayRound> beginDisplayRound() async {
    endDisplayRound();
    final password = _passwordService.beginRound();
    final payload = await buildQrPayload();
    _activeDisplayTicket = payload.ticket;
    return PairingDisplayRound(
      payload: payload,
      password: password,
      expiresAt: _passwordService.roundExpiresAt!,
    );
  }

  /// 结束展示轮次（关窗 / 过期 / 刷新前）：密码与 ticket 立刻作废。
  void endDisplayRound() {
    final ticket = _activeDisplayTicket;
    if (ticket != null) {
      _ticketRegistry.revoke(ticket);
      _activeDisplayTicket = null;
    }
    _passwordService.endRound();
  }

  /// 生成二维码载荷（展示给对方扫；含 X25519 临时公钥）。
  Future<PairingPayload> buildQrPayload() async {
    final self = await identity();
    final keyPair = await _crypto.generateEphemeralKeyPair();
    final publicKey = await _crypto.publicKeyBytes(keyPair);
    final privateKey = await keyPair.extractPrivateKeyBytes();
    final ticket = _ticketRegistry.issue(privateKeyBytes: privateKey);
    // name/model/sid 不进二维码（瘦身 A）；enroll 回包再交换。
    return PairingPayload(
      version: PairingPayload.supportedVersion,
      host: localAddress(),
      port: port(),
      deviceName: self.name,
      model: self.model,
      fingerprint: self.fingerprint,
      ticket: ticket,
      serverPublicKey: base64Url.encode(publicKey).replaceAll('=', ''),
      stableIdHash: null,
    );
  }

  /// 密码校验（pair_password_endpoint 用，含限速；须有活跃展示轮次）。
  Future<bool> verifyPassword(String candidate) =>
      _passwordService.verify(candidate);

  /// 扫码 enroll（X25519；明文 ticket 用于取回宿主临时私钥）。
  ///
  /// [remoteIp]：TCP 连接远端 IP；与 enroll.listenPort 拼成 lastSeenAddress。
  Future<String?> handleQrEnroll({
    required String sealed,
    required String clientPublicKey,
    required String ticket,
    String? remoteIp,
  }) async {
    final privateKeyBytes = _ticketRegistry.peekPrivateKey(ticket);
    if (privateKeyBytes == null) {
      AppLogger.log(
        'QR enroll reject: ticket unknown/expired',
        scope: 'pairing',
        details: {
          'ticket': ticket.length >= 8 ? '${ticket.substring(0, 8)}…' : ticket,
        },
      );
      return null;
    }

    List<int> peerPublic;
    try {
      peerPublic = base64Url.decode(base64Url.normalize(clientPublicKey));
    } catch (error) {
      AppLogger.log(
        'QR enroll reject: bad client_pub',
        scope: 'pairing',
        error: error,
      );
      return null;
    }

    final hostKeyPair =
        await _crypto.keyPairFromPrivateBytes(privateKeyBytes);
    final key = await _crypto.deriveSharedKey(
      ephemeralPrivate: hostKeyPair,
      peerPublicKeyBytes: peerPublic,
    );
    final opened = await _crypto.open(key: key, sealed: sealed);
    if (opened == null) {
      AppLogger.log('QR enroll reject: decrypt failed', scope: 'pairing');
      return null;
    }
    final request = EnrollRequest.fromJson(opened);

    if (request.ticket != ticket || !_ticketRegistry.consume(ticket)) {
      AppLogger.log(
        'QR enroll reject: ticket mismatch or replay',
        scope: 'pairing',
      );
      return null;
    }

    final response = await _writePeer(request, remoteIp: remoteIp);
    if (response == null) {
      AppLogger.log('QR enroll reject: writePeer failed', scope: 'pairing');
      return null;
    }
    return _crypto.seal(key: key, plaintext: response.toJson());
  }

  /// 处理加密 enroll（密码路径：密码派生密钥）。
  Future<String?> handlePasswordEnroll({
    required String sealed,
    String? remoteIp,
  }) async {
    final sw = Stopwatch()..start();
    final roundPassword = _passwordService.currentPassword;
    if (roundPassword == null) {
      AppLogger.log(
        'password enroll reject: no active display round',
        scope: 'pairing',
      );
      return null;
    }
    final key = await _passwordService.deriveKey(roundPassword);
    final opened = await _crypto.open(key: key, sealed: sealed);
    if (opened == null) {
      AppLogger.log(
        'password enroll reject: decrypt failed (wrong password?)',
        scope: 'pairing',
        details: {'elapsedMs': sw.elapsedMilliseconds},
      );
      return null;
    }
    final request = EnrollRequest.fromJson(opened);

    final response = await _writePeer(request, remoteIp: remoteIp);
    if (response == null) {
      AppLogger.log('password enroll reject: writePeer failed', scope: 'pairing');
      return null;
    }
    return _crypto.seal(key: key, plaintext: response.toJson());
  }

  /// listenPort 必填；地址用 PeerAddress 规范化。缺端口则拒绝 enroll。
  Future<EnrollResponse?> _writePeer(
    EnrollRequest request, {
    String? remoteIp,
  }) async {
    final listenPort = request.listenPort;
    if (listenPort == null || listenPort <= 0 || listenPort > 65535) {
      AppLogger.log(
        'enroll rejected: missing/invalid listenPort',
        scope: 'pairing',
        details: {'listenPort': listenPort},
      );
      return null;
    }

    final self = await identity();
    final secret = _generateSecret();
    final dialAddress = PeerAddress.format(remoteIp, listenPort);
    if (dialAddress == null) {
      AppLogger.log(
        'enroll: peer written without dial address (remoteIp unusable)',
        scope: 'pairing',
        details: {'remoteIp': remoteIp, 'listenPort': listenPort},
      );
    }

    final peer = Peer(
      fingerprint: request.fingerprint,
      name: request.deviceName,
      brand: request.brand,
      model: request.model,
      pairedAt: DateTime.now().millisecondsSinceEpoch,
      secret: secret,
      lastSeenAddress: dialAddress,
      stableIdHash: request.stableIdHash,
    );
    await peerRepository.upsert(peer);
    // 收尾不阻塞 enroll HTTP 应答（避免 PBKDF2 拖垮客户端超时）
    final hook = onPeerWritten;
    if (hook != null) {
      unawaited(Future(() => hook(peer)));
    }
    return EnrollResponse(
      fingerprint: self.fingerprint,
      deviceName: self.name,
      brand: self.brand,
      model: self.model,
      secret: secret,
      stableIdHash: self.stableIdHash,
    );
  }

  String _generateSecret() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// 发起侧（客户端）：扫码/输密码 → 加密 enroll 上报 → 写 peer 表。
class PairingClientService {
  PairingClientService({required this.peerRepository, PairingCrypto? crypto})
      : _crypto = crypto ?? PairingCrypto();

  final PeerWriter peerRepository;
  final PairingCrypto _crypto;

  /// 密码配对：构造加密 enroll 载荷。
  Future<String> buildPasswordEnroll({
    required String password,
    required String fingerprint,
    required String deviceName,
    required String model,
    required int listenPort,
    String brand = '',
    String? stableIdHash,
  }) async {
    final key = await _crypto.deriveKeyFromPassword(password);
    return _crypto.seal(
      key: key,
      plaintext: EnrollRequest(
        ticket: '',
        fingerprint: fingerprint,
        deviceName: deviceName,
        brand: brand,
        model: model,
        listenPort: listenPort,
        stableIdHash: stableIdHash,
      ).toJson(),
    );
  }

  /// 扫码配对：X25519 协商 + 加密 enroll。
  Future<QrEnrollPackage> buildQrEnroll({
    required PairingPayload payload,
    required String fingerprint,
    required String deviceName,
    required String model,
    required int listenPort,
    String brand = '',
    String? stableIdHash,
  }) async {
    final clientKeyPair = await _crypto.generateEphemeralKeyPair();
    final clientPublic = await _crypto.publicKeyBytes(clientKeyPair);
    final serverPublic =
        base64Url.decode(base64Url.normalize(payload.serverPublicKey));
    final sessionKey = await _crypto.deriveSharedKey(
      ephemeralPrivate: clientKeyPair,
      peerPublicKeyBytes: serverPublic,
    );
    final sealed = await _crypto.seal(
      key: sessionKey,
      plaintext: EnrollRequest(
        ticket: payload.ticket,
        fingerprint: fingerprint,
        deviceName: deviceName,
        brand: brand,
        model: model,
        listenPort: listenPort,
        stableIdHash: stableIdHash,
      ).toJson(),
    );
    return QrEnrollPackage(
      sealed: sealed,
      clientPublicKey: base64Url.encode(clientPublic),
      sessionKey: sessionKey,
    );
  }

  /// 扫码配对：解密应答并落表（指纹一致性校验后入表）。
  Future<PairingResult?> consumeQrResponse({
    required PairingPayload payload,
    required String sealedResponse,
    required List<int> sessionKey,
  }) async {
    final opened = await _crypto.open(
      key: sessionKey,
      sealed: sealedResponse,
    );
    if (opened == null) return null;
    final response = EnrollResponse.fromJson(opened);
    if (response.fingerprint != payload.fingerprint) return null;

    final peer = Peer(
      fingerprint: response.fingerprint,
      name: response.deviceName,
      brand: response.brand,
      model: response.model,
      pairedAt: DateTime.now().millisecondsSinceEpoch,
      secret: response.secret,
      lastSeenAddress: PeerAddress.format(payload.host, payload.port),
      stableIdHash: response.stableIdHash ?? payload.stableIdHash,
    );
    await peerRepository.upsert(peer);
    return PairingResult(
      peer: peer,
      host: payload.host,
      port: payload.port,
    );
  }

  /// 密码配对：解密应答并落表。
  Future<PairingResult?> consumePasswordResponse({
    required String password,
    required String sealedResponse,
    required String host,
    required int port,
  }) async {
    final key = await _crypto.deriveKeyFromPassword(password);
    final opened = await _crypto.open(key: key, sealed: sealedResponse);
    if (opened == null) return null;
    final response = EnrollResponse.fromJson(opened);

    final peer = Peer(
      fingerprint: response.fingerprint,
      name: response.deviceName,
      brand: response.brand,
      model: response.model,
      pairedAt: DateTime.now().millisecondsSinceEpoch,
      secret: response.secret,
      lastSeenAddress: PeerAddress.format(host, port),
      stableIdHash: response.stableIdHash,
    );
    await peerRepository.upsert(peer);
    return PairingResult(peer: peer, host: host, port: port);
  }
}
