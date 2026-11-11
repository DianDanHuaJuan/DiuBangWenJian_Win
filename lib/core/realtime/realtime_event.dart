import 'dart:convert';

/// 实时事件类型（P2P 互传 + 聊天 + peer.status）。
enum RealtimeEventType {
  ping,
  pong,
  chat,
  offer,
  accept,
  receipt,
  peerStatus,
  peerStatusGet,
  unknown;

  static RealtimeEventType fromWire(String value) {
    switch (value) {
      case 'ping':
        return RealtimeEventType.ping;
      case 'pong':
        return RealtimeEventType.pong;
      case 'chat':
        return RealtimeEventType.chat;
      case 'offer':
        return RealtimeEventType.offer;
      case 'accept':
        return RealtimeEventType.accept;
      case 'receipt':
        return RealtimeEventType.receipt;
      case 'peer.status':
        return RealtimeEventType.peerStatus;
      case 'peer.status.get':
        return RealtimeEventType.peerStatusGet;
      default:
        return RealtimeEventType.unknown;
    }
  }

  String get wire {
    switch (this) {
      case RealtimeEventType.ping:
        return 'ping';
      case RealtimeEventType.pong:
        return 'pong';
      case RealtimeEventType.chat:
        return 'chat';
      case RealtimeEventType.offer:
        return 'offer';
      case RealtimeEventType.accept:
        return 'accept';
      case RealtimeEventType.receipt:
        return 'receipt';
      case RealtimeEventType.peerStatus:
        return 'peer.status';
      case RealtimeEventType.peerStatusGet:
        return 'peer.status.get';
      case RealtimeEventType.unknown:
        return 'unknown';
    }
  }
}

/// 统一 envelope：`{v,type,id,ts,payload}`。
class RealtimeEvent {
  const RealtimeEvent({
    required this.type,
    required this.id,
    required this.timestampMs,
    required this.payload,
    this.version = 1,
  });

  final int version;
  final RealtimeEventType type;
  final String id;
  final int timestampMs;
  final Map<String, dynamic> payload;

  Map<String, dynamic> toJson() => {
        'v': version,
        'type': type.wire,
        'id': id,
        'ts': timestampMs,
        'payload': payload,
      };

  String encode() => jsonEncode(toJson());

  factory RealtimeEvent.fromJson(Map<String, dynamic> json) {
    return RealtimeEvent(
      version: json['v'] as int? ?? 1,
      type: RealtimeEventType.fromWire(json['type'] as String? ?? ''),
      id: json['id'] as String? ?? '',
      timestampMs: json['ts'] as int? ?? 0,
      payload: Map<String, dynamic>.from(
        json['payload'] as Map? ?? const {},
      ),
    );
  }

  factory RealtimeEvent.decode(String raw) =>
      RealtimeEvent.fromJson(jsonDecode(raw) as Map<String, dynamic>);

  factory RealtimeEvent.create({
    required RealtimeEventType type,
    required Map<String, dynamic> payload,
    String? id,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return RealtimeEvent(
      type: type,
      id: id ?? 'evt_$now',
      timestampMs: now,
      payload: payload,
    );
  }
}
