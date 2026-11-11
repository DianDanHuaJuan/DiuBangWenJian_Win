import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../common/app_logger.dart';
import 'realtime_event.dart';

/// 单条对端 WS 连接。
class RealtimeConnection {
  RealtimeConnection({
    required this.peerFingerprint,
    required this.channel,
  });

  final String peerFingerprint;
  final WebSocketChannel channel;
  final int connectedAtMs = DateTime.now().millisecondsSinceEpoch;

  void send(RealtimeEvent event) {
    channel.sink.add(event.encode());
  }

  Future<void> close() async {
    await channel.sink.close();
  }
}

/// 被连接侧连接表（本机宿主上，按对端指纹索引）。
class RealtimeConnectionRegistry {
  final Map<String, RealtimeConnection> _byPeer = {};

  /// 入站连上/断开修订计数；概览等 UI 订阅后重算「已连接」。
  final ValueNotifier<int> changes = ValueNotifier(0);

  RealtimeConnection? get(String fingerprint) => _byPeer[fingerprint];

  bool get hasConnections => _byPeer.isNotEmpty;

  Iterable<String> get connectedFingerprints => _byPeer.keys;

  void put(RealtimeConnection connection) {
    final old = _byPeer.remove(connection.peerFingerprint);
    unawaited(old?.close() ?? Future.value());
    _byPeer[connection.peerFingerprint] = connection;
    _bump();
  }

  void remove(String fingerprint) {
    if (_byPeer.remove(fingerprint) == null) return;
    _bump();
  }

  bool sendTo(String fingerprint, RealtimeEvent event) {
    final conn = _byPeer[fingerprint];
    if (conn == null) return false;
    try {
      conn.send(event);
      return true;
    } catch (e) {
      AppLogger.log('ws send failed: $e', scope: 'realtime');
      return false;
    }
  }

  Future<void> closeAll() async {
    final list = _byPeer.values.toList();
    if (list.isEmpty) return;
    _byPeer.clear();
    for (final c in list) {
      await c.close();
    }
    _bump();
  }

  void _bump() {
    changes.value = changes.value + 1;
  }
}
