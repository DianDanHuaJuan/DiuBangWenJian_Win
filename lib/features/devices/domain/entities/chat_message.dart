/// 聊天消息实体。
enum ChatMessageKind { text, offer }

enum ChatDirection { outbound, inbound }

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.peerFingerprint,
    required this.direction,
    required this.kind,
    required this.body,
    required this.createdAtMs,
  });

  final String id;
  final String peerFingerprint;
  final ChatDirection direction;
  final ChatMessageKind kind;

  /// text 内容，或 offer 的 taskId。
  final String body;
  final int createdAtMs;

  Map<String, Object?> toMap() => {
        'id': id,
        'peer_fingerprint': peerFingerprint,
        'direction': direction.name,
        'kind': kind.name,
        'body': body,
        'created_at_ms': createdAtMs,
      };

  factory ChatMessage.fromMap(Map<String, Object?> map) {
    return ChatMessage(
      id: map['id'] as String,
      peerFingerprint: map['peer_fingerprint'] as String,
      direction: ChatDirection.values.firstWhere(
        (e) => e.name == map['direction'],
        orElse: () => ChatDirection.inbound,
      ),
      kind: ChatMessageKind.values.firstWhere(
        (e) => e.name == map['kind'],
        orElse: () => ChatMessageKind.text,
      ),
      body: map['body'] as String? ?? '',
      createdAtMs: map['created_at_ms'] as int? ?? 0,
    );
  }
}
