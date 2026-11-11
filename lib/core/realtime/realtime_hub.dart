import 'dart:async';

import 'package:shelf/shelf.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../auth/peer_fingerprint_middleware.dart';
import '../common/app_logger.dart';
import '../identity/peer.dart';
import 'realtime_connection_registry.dart';
import 'realtime_event.dart';

typedef RealtimeInboundHandler = Future<void> Function(
  String peerFingerprint,
  RealtimeEvent event,
);

typedef RealtimePeerLifecycle = void Function(String peerFingerprint);

/// 被连接侧 realtime hub（挂 `/ws`，随宿主常驻）。
class RealtimeHub {
  RealtimeHub({
    required this.registry,
    this.onEvent,
    this.onPeerConnected,
    this.onPeerDisconnected,
  });

  static const path = '/ws';

  final RealtimeConnectionRegistry registry;
  final RealtimeInboundHandler? onEvent;
  final RealtimePeerLifecycle? onPeerConnected;
  final RealtimePeerLifecycle? onPeerDisconnected;

  Handler get handler {
    return (Request request) async {
      final peer = request.context[peerKey] as Peer?;
      if (peer == null) {
        return Response.unauthorized('peer required');
      }
      final wsHandler = webSocketHandler((WebSocketChannel channel, _) {
        _attach(peer.fingerprint, channel);
      });
      return wsHandler(request);
    };
  }

  void _attach(String peerFingerprint, WebSocketChannel channel) {
    final connection = RealtimeConnection(
      peerFingerprint: peerFingerprint,
      channel: channel,
    );
    registry.put(connection);
    onPeerConnected?.call(peerFingerprint);

    channel.stream.listen(
      (message) async {
        try {
          final raw = message is String ? message : message.toString();
          final event = RealtimeEvent.decode(raw);
          if (event.type == RealtimeEventType.ping) {
            connection.send(
              RealtimeEvent.create(
                type: RealtimeEventType.pong,
                payload: const {},
              ),
            );
            return;
          }
          await onEvent?.call(peerFingerprint, event);
        } catch (e) {
          AppLogger.log('ws inbound error: $e', scope: 'realtime');
        }
      },
      onDone: () {
        registry.remove(peerFingerprint);
        onPeerDisconnected?.call(peerFingerprint);
      },
      onError: (_) {
        registry.remove(peerFingerprint);
        onPeerDisconnected?.call(peerFingerprint);
      },
      cancelOnError: true,
    );
  }
}
