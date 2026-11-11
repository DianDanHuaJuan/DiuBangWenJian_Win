import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';

import '../auth/request_signer.dart';
import '../common/app_logger.dart';
import '../identity/peer_repository.dart';
import '../identity/tls_certificate_builder.dart';
import '../network/peer_address.dart';
import 'realtime_event.dart';

/// 发起侧 WS 会话：进入聊天页时拨号对端 `/ws`；空闲可断开。
class RealtimeSessionService {
  RealtimeSessionService({
    required Future<PeerRepository> Function() peerRepository,
    required this.selfFingerprint,
    RequestSigner signer = const RequestSigner(),
    this.idleTimeout = const Duration(minutes: 5),
    this.onPeerConnected,
    this.onPeerDisconnected,
  })  : _peerRepository = peerRepository,
        _signer = signer;

  final Future<PeerRepository> Function() _peerRepository;
  final String selfFingerprint;
  final RequestSigner _signer;
  final Duration idleTimeout;
  final void Function(String fingerprint)? onPeerConnected;
  final void Function(String fingerprint)? onPeerDisconnected;

  /// 出站连上/断开修订计数；概览等 UI 订阅后重算「已连接」。
  final ValueNotifier<int> changes = ValueNotifier(0);

  IOWebSocketChannel? _channel;
  String? _peerFingerprint;
  StreamSubscription? _sub;
  Timer? _idleTimer;
  final _inbound =
      StreamController<RealtimeEvent>.broadcast(sync: false);

  Stream<RealtimeEvent> get events => _inbound.stream;
  String? get connectedPeer => _peerFingerprint;
  bool get isConnected => _channel != null;

  /// 拨号到 [fingerprint]；已连同一对端则保活。
  Future<bool> connect(String fingerprint) async {
    if (_peerFingerprint == fingerprint && _channel != null) {
      _touchIdle();
      return true;
    }
    await disconnect();

    final repository = await _peerRepository();
    final peer = await repository.findByFingerprint(fingerprint);
    if (peer == null) return false;
    final parsed = PeerAddress.tryParse(peer.lastSeenAddress);
    if (parsed == null) return false;

    final headers = _signer
        .sign(fingerprint: selfFingerprint, secret: peer.secret)
        .toMap();
    final uri = Uri(
      scheme: 'wss',
      host: parsed.host,
      port: parsed.port,
      path: '/ws',
    );

    final client = HttpClient()
      ..badCertificateCallback = (cert, _, _) =>
          CertificateFingerprint.fromDer(cert.der) == peer.fingerprint;

    try {
      final channel = IOWebSocketChannel.connect(
        uri,
        headers: headers,
        customClient: client,
      );
      await channel.ready.timeout(const Duration(seconds: 8));
      _channel = channel;
      _peerFingerprint = fingerprint;
      _sub = channel.stream.listen(
        (message) {
          _touchIdle();
          try {
            final raw = message is String ? message : message.toString();
            _inbound.add(RealtimeEvent.decode(raw));
          } catch (e) {
            AppLogger.log('ws client decode: $e', scope: 'realtime');
          }
        },
        onDone: () {
          final fp = _peerFingerprint;
          _channel = null;
          _peerFingerprint = null;
          if (fp != null) {
            _bump();
            onPeerDisconnected?.call(fp);
          }
        },
        onError: (e) {
          AppLogger.log('ws client error: $e', scope: 'realtime');
          unawaited(disconnect());
        },
        cancelOnError: true,
      );
      _touchIdle();
      _bump();
      onPeerConnected?.call(fingerprint);
      return true;
    } catch (e) {
      AppLogger.log('ws connect failed: $e', scope: 'realtime');
      await disconnect();
      return false;
    }
  }

  Future<bool> send(RealtimeEvent event) async {
    final channel = _channel;
    if (channel == null) return false;
    try {
      channel.sink.add(event.encode());
      _touchIdle();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> disconnect() async {
    final fp = _peerFingerprint;
    _idleTimer?.cancel();
    _idleTimer = null;
    await _sub?.cancel();
    _sub = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _peerFingerprint = null;
    if (fp != null) {
      _bump();
      onPeerDisconnected?.call(fp);
    }
  }

  void _touchIdle() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, () {
      unawaited(disconnect());
    });
  }

  void _bump() {
    changes.value = changes.value + 1;
  }

  Future<void> dispose() async {
    await disconnect();
    await _inbound.close();
    changes.dispose();
  }
}
