import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../common/app_logger.dart';

/// 组播地址/端口（doc/01 §五 局域网发现）。
const discoveryMulticastAddress = '239.255.255.250';
const discoveryPort = 5245;

/// announce 心跳间隔与离线判定（2×心跳：两拍未见即标灰）。
const announceInterval = Duration(seconds: 5);
const offlineTimeout = Duration(seconds: 10);

/// 在线扫地周期：短于心跳，使 10s 超时不必再等一轮 5s。
const presenceSweepInterval = Duration(seconds: 1);

/// 方案 A：UDP 超时后对已配对短 ping；成功则续 lastSeen，失败再标灰。
const presencePingGateTimeout = Duration(milliseconds: 1200);

/// ping 失败后的冷静期：期内再超时直接标灰，避免每秒重 ping。
const presencePingFailCooldown = Duration(seconds: 40);

/// 同时进行的 presence ping 上限（防局域网风暴）。
const presencePingGateMaxConcurrent = 3;

/// 前台组播 ensure 最多尝试次数（含第一次）。
const discoveryEnsureMaxAttempts = 3;

/// 前台组播失败后的重试间隔（第 2、3 次尝试之前）。
const discoveryEnsureRetryDelays = <Duration>[
  Duration(milliseconds: 500),
  Duration(seconds: 2),
];

/// 同一指纹单播回声最短间隔（防风暴）。
const unicastReplyMinInterval = Duration(seconds: 2);

/// announce 载荷（UDP JSON；**只当线索**——身份以 TLS 钉扎 + Bearer 为准）。
class AnnouncePayload {
  const AnnouncePayload({
    required this.version,
    required this.fingerprint,
    required this.name,
    required this.model,
    required this.host,
    required this.port,
    this.brand = '',
    this.emoji = '',
    this.wantReply = true,
    this.pend = false,
    this.nas = false,
  });

  final int version;
  final String fingerprint;
  final String name;
  final String brand;
  final String model;

  /// 展示用 emoji（可选；旧包缺省为空）。
  final String emoji;
  final String host;
  final int port;

  /// true=组播宣告，对端应单播回声；false=回声本身，不再触发回声。
  final bool wantReply;

  /// 粗提示：本机 outbox 仍有 offered（角标真相源仍是 pending 端点）。
  final bool pend;

  /// 本机 NAS 服务是否开启（对端据此落地文件预览页）。
  final bool nas;

  Map<String, Object?> toJson() => {
        'v': version,
        'fp': fingerprint,
        'name': name,
        'brand': brand,
        'model': model,
        if (emoji.isNotEmpty) 'emoji': emoji,
        'host': host,
        'port': port,
        'r': wantReply ? 1 : 0,
        'pend': pend ? 1 : 0,
        'nas': nas ? 1 : 0,
      };

  /// 解析失败返回 null（乱包/异版本静默丢弃）。
  static AnnouncePayload? decode(String raw) {
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final version = json['v'] as int?;
      if (version != 1) return null;
      return AnnouncePayload(
        version: 1,
        fingerprint: json['fp'] as String,
        name: json['name'] as String,
        brand: json['brand'] as String? ?? '',
        model: json['model'] as String,
        emoji: json['emoji'] as String? ?? '',
        host: json['host'] as String,
        port: json['port'] as int,
        wantReply: (json['r'] as int?) != 0,
        pend: (json['pend'] as int?) == 1 || json['pend'] == true,
        nas: (json['nas'] as int?) == 1 || json['nas'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  AnnouncePayload copyWith({
    String? host,
    bool? wantReply,
    bool? pend,
    bool? nas,
  }) =>
      AnnouncePayload(
        version: version,
        fingerprint: fingerprint,
        name: name,
        brand: brand,
        model: model,
        emoji: emoji,
        host: host ?? this.host,
        port: port,
        wantReply: wantReply ?? this.wantReply,
        pend: pend ?? this.pend,
        nas: nas ?? this.nas,
      );
}

abstract class MulticastLock {
  Future<void> acquire();
  Future<void> release();
}

class NoopMulticastLock implements MulticastLock {
  @override
  Future<void> acquire() async {}
  @override
  Future<void> release() async {}
}

/// UDP 组播发现：周期组播 + 收到 wantReply 时立刻单播回声（秒级互见）。
class DiscoveryService {
  DiscoveryService({
    required this.self,
    MulticastLock? multicastLock,
    Future<RawDatagramSocket> Function(
      InternetAddress address,
      int port,
    )? socketFactory,
    this.nowMillis,
  })  : _lock = multicastLock ?? NoopMulticastLock(),
        _socketFactory = socketFactory ?? RawDatagramSocket.bind;

  final AnnouncePayload Function() self;

  final MulticastLock _lock;
  final Future<RawDatagramSocket> Function(InternetAddress, int) _socketFactory;
  final int Function()? nowMillis;

  RawDatagramSocket? _socket;
  Timer? _heartbeat;
  Timer? _statsPulse;
  bool _starting = false;
  bool _announceEnabled = true;
  bool _transportFailed = false;

  /// fingerprint → 上次单播回声时刻（毫秒）。
  final Map<String, int> _lastUnicastReplyMs = {};

  /// 调试计数（长时间放置对照掉线）。
  int _txOk = 0;
  int _txFail = 0;
  int _rxOk = 0;
  int _unicastOk = 0;
  int _lastStatsLogMs = 0;
  /// fingerprint → 上次打印 RX 日志的时刻。
  final Map<String, int> _lastRxLogMs = {};

  final _announceController = StreamController<AnnouncePayload>.broadcast();
  Stream<AnnouncePayload> get announceStream => _announceController.stream;

  bool get isRunning => _socket != null;

  /// 发送失败 / 网卡抖动后需 stop+start 才能恢复 JOIN（仅 isRunning 不够）。
  bool get needsRebuild => _transportFailed || _socket == null;

  /// 组播真正可用：已 JOIN 且近期未判定传输失败。
  bool get isHealthy => isRunning && !_transportFailed;

  /// 是否对外宣告（false=隐身：仍收组播，不发 announce/回声）。
  bool get announceEnabled => _announceEnabled;

  void setAnnounceEnabled(bool enabled) {
    if (_announceEnabled == enabled) return;
    _announceEnabled = enabled;
    if (enabled) {
      _sendMulticastAnnounce();
    }
  }

  /// 加入组播。已在跑且 [rebuild] 为 false 时直接成功。
  /// 返回是否已 listen + 心跳就绪。
  Future<bool> start({bool rebuild = false}) async {
    final forceRebuild = rebuild || _transportFailed;
    if (forceRebuild) {
      await stop();
    }
    if (_socket != null) return true;
    if (_starting) return false;
    _starting = true;
    RawDatagramSocket? socket;
    try {
      await _lock.acquire();
      final bindAddress = _bindAddress();
      try {
        socket = await _socketFactory(
          bindAddress,
          discoveryPort,
        ).timeout(const Duration(seconds: 5));
      } catch (error) {
        if (bindAddress.address == InternetAddress.anyIPv4.address) rethrow;
        AppLogger.log(
          'UDP bind preferred address failed, fallback any',
          scope: 'discovery',
          error: error,
          details: {'address': bindAddress.address},
        );
        socket = await _socketFactory(
          InternetAddress.anyIPv4,
          discoveryPort,
        ).timeout(const Duration(seconds: 5));
      }
      final joined = await _joinLanMulticast(socket);
      if (joined.isEmpty && !Platform.isWindows) {
        socket.joinMulticast(InternetAddress(discoveryMulticastAddress));
      }
      _pinMulticastInterface(socket);
      socket.listen((event) {
        final live = _socket;
        if (live == null || event != RawSocketEvent.read) return;
        final datagram = live.receive();
        if (datagram == null) return;
        final raw = utf8.decode(datagram.data, allowMalformed: true);
        final payload = AnnouncePayload.decode(raw);
        if (payload == null) return;
        if (payload.fingerprint.isEmpty) return;
        final selfFp = self().fingerprint;
        if (selfFp.isNotEmpty && payload.fingerprint == selfFp) return;

        // 载荷 host 若为空/占位，用报文源 IP（更可靠的拨号线索）
        final sourceHost = datagram.address.address;
        final normalized = _isUsableHost(payload.host)
            ? payload
            : payload.copyWith(host: sourceHost);

        _announceController.add(normalized);
        _noteRx(normalized, sourceHost);

        if (normalized.wantReply) {
          _maybeUnicastReply(to: datagram.address);
        }
      });
      _transportFailed = false;
      final boundAddress = socket.address.address;
      _socket = socket;
      socket = null;

      AppLogger.log(
        'UDP discovery started',
        scope: 'discovery',
        details: {
          'port': discoveryPort,
          'multicast': discoveryMulticastAddress,
          'selfHost': self().host,
          'selfPort': self().port,
          'bind': boundAddress,
          'joined': joined,
          'announceEnabled': _announceEnabled,
        },
      );
      _sendMulticastAnnounce();
      _heartbeat =
          Timer.periodic(announceInterval, (_) => _sendMulticastAnnounce());
      _statsPulse?.cancel();
      _statsPulse = Timer.periodic(const Duration(seconds: 60), (_) {
        _logStatsPulse(force: true);
      });
      socket = null;
      return true;
    } catch (error) {
      AppLogger.log('Discovery start failed: $error', scope: 'discovery');

      final leftover = _socket ?? socket;
      _socket = null;
      _transportFailed = true;
      if (leftover != null) {
        try {
          leftover.close();
        } catch (_) {}
      }
      await _lock.release();
      return false;
    } finally {
      _starting = false;
    }
  }

  /// 配对成功等场景主动再推一次组播（缩短互见等待）。
  void announceNow() => _sendMulticastAnnounce();

  Future<void> stop() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    _statsPulse?.cancel();
    _statsPulse = null;
    final socket = _socket;
    _socket = null;
    AppLogger.log(
      'UDP discovery stopped',
      scope: 'discovery',
      details: {
        'txOk': _txOk,
        'txFail': _txFail,
        'rxOk': _rxOk,
        'unicastOk': _unicastOk,
        'transportFailed': _transportFailed,
      },
    );
    // transportFailed 保留到下次成功 start，迫使 rebuild 路径。
    if (socket != null) {
      try {
        socket.leaveMulticast(InternetAddress(discoveryMulticastAddress));
      } catch (_) {}
      socket.close();
    }
    await _lock.release();
  }

  void _sendMulticastAnnounce() {
    if (!_announceEnabled) return;
    final socket = _socket;
    if (socket == null) return;
    _pinMulticastInterface(socket);
    final payload = self();
    if (payload.fingerprint.isEmpty) return;
    if (!_isUsableHost(payload.host)) {
      _markTransportFailed('bad_self_host');
      return;
    }
    final bytes = utf8.encode(jsonEncode(
      payload.copyWith(wantReply: true).toJson(),
    ));
    try {
      socket.send(
        bytes,
        InternetAddress(discoveryMulticastAddress),
        discoveryPort,
      );
      _txOk++;
      _logStatsPulse();
    } catch (e, st) {
      _txFail++;
      AppLogger.log(
        'discovery TX failed',
        scope: 'discovery',
        error: e,
        stackTrace: st,
        details: {'txFail': _txFail, 'selfHost': payload.host},
      );
      _markTransportFailed('send_failed');
      return;
    }
  }

  void _noteRx(AnnouncePayload payload, String sourceHost) {
    _rxOk++;
    final fp = payload.fingerprint;
    final now = _now();
    final last = _lastRxLogMs[fp] ?? 0;
    // 每对端最多约 30s 打一条 RX，避免 5s 心跳刷屏。
    if (now - last >= 30000) {
      _lastRxLogMs[fp] = now;
      AppLogger.logVerbose(
        'UDP RX announce',
        scope: 'discovery',
        details: {
          'fp': _shortFp(fp),
          'from': sourceHost,
          'host': payload.host,
          'port': payload.port,
          'wantReply': payload.wantReply,
          'nas': payload.nas,
          'rxOk': _rxOk,
        },
      );
    }
    _logStatsPulse();
  }

  void _logStatsPulse({bool force = false}) {
    final now = _now();
    if (!force && now - _lastStatsLogMs < 60000) return;
    _lastStatsLogMs = now;
    AppLogger.logVerbose(
      'UDP discovery pulse',
      scope: 'discovery',
      details: {
        'healthy': isHealthy,
        'running': isRunning,
        'needsRebuild': needsRebuild,
        'announceEnabled': _announceEnabled,
        'selfHost': self().host,
        'txOk': _txOk,
        'txFail': _txFail,
        'rxOk': _rxOk,
        'unicastOk': _unicastOk,
      },
    );
  }

  static String _shortFp(String fp) =>
      fp.length > 12 ? '${fp.substring(0, 12)}…' : fp;

  void _markTransportFailed(String reason) {
    if (_transportFailed && _socket == null) return;
    _transportFailed = true;
    AppLogger.log(
      'discovery transport failed → needs rebuild ($reason)',
      scope: 'discovery',
    );
    _heartbeat?.cancel();
    _heartbeat = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        socket.leaveMulticast(InternetAddress(discoveryMulticastAddress));
      } catch (_) {}
      try {
        socket.close();
      } catch (_) {}
    }
    unawaited(_lock.release());
  }

  /// LocalSend 风格：对组播宣告立刻单播回声（wantReply=false，防环）。
  void _maybeUnicastReply({required InternetAddress to}) {
    if (!_announceEnabled) return;
    final socket = _socket;
    if (socket == null) return;
    final payload = self();
    if (payload.fingerprint.isEmpty) return;

    final now = _now();
    final last = _lastUnicastReplyMs[to.address] ?? 0;
    if (now - last < unicastReplyMinInterval.inMilliseconds) return;
    _lastUnicastReplyMs[to.address] = now;

    final bytes = utf8.encode(jsonEncode(
      payload.copyWith(wantReply: false).toJson(),
    ));
    try {
      socket.send(bytes, to, discoveryPort);
      _unicastOk++;
    } catch (e, st) {
      AppLogger.log(
        'discovery unicast reply failed',
        scope: 'discovery',
        error: e,
        stackTrace: st,
        details: {'to': to.address},
      );
      _markTransportFailed('unicast_failed');
    }
  }

  bool _isUsableHost(String host) =>
      host.isNotEmpty && host != '0.0.0.0' && host != '::';

  /// Windows 绑到选定局域网地址，避免 Meta/Hyper-V 成为组播出口。
  InternetAddress _bindAddress() {
    if (!Platform.isWindows) return InternetAddress.anyIPv4;
    final host = self().host;
    final parsed = InternetAddress.tryParse(host);
    if (parsed == null ||
        parsed.type != InternetAddressType.IPv4 ||
        !_isUsableHost(host)) {
      return InternetAddress.anyIPv4;
    }
    return parsed;
  }

  /// 只加入当前选定地址所在的网卡，与二维码 / 宿主绑定保持一致。
  Future<List<String>> _joinLanMulticast(RawDatagramSocket socket) async {
    final group = InternetAddress(discoveryMulticastAddress);
    if (!Platform.isWindows) {
      socket.joinMulticast(group);
      return const ['default'];
    }
    final host = self().host;
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: true,
      );
      for (final interface in interfaces) {
        final owns = interface.addresses.any(
          (address) => address.address == host,
        );
        if (!owns) continue;
        socket.joinMulticast(group, interface);
        return [interface.name];
      }
    } catch (error) {
      AppLogger.log(
        'join selected interface failed',
        scope: 'discovery',
        error: error,
        details: {'host': host},
      );
    }
    AppLogger.log(
      'selected interface not found for multicast',
      scope: 'discovery',
      details: {'host': host},
    );
    return const [];
  }

  /// Windows `IP_MULTICAST_IF`：后续组播从选定 IPv4 发出。
  void _pinMulticastInterface(RawDatagramSocket socket) {
    if (!Platform.isWindows) return;
    final host = self().host;
    final parsed = InternetAddress.tryParse(host);
    if (parsed == null ||
        parsed.type != InternetAddressType.IPv4 ||
        parsed.rawAddress.length != 4 ||
        !_isUsableHost(host)) {
      return;
    }
    try {
      socket.setRawOption(
        RawSocketOption(RawSocketOption.levelIPv4, 9, parsed.rawAddress),
      );
    } catch (error) {
      AppLogger.log(
        'pin multicast interface failed',
        scope: 'discovery',
        error: error,
        details: {'host': host},
      );
    }
  }

  int _now() =>
      nowMillis?.call() ?? DateTime.now().millisecondsSinceEpoch;

  void dispose() {
    stop();
    _announceController.close();
  }
}
