import 'package:flutter/material.dart';

import '../../domain/entities/chat_message.dart';

/// 气泡外侧：头像 + 名称 + 时间（对齐原项目互传会话行布局）。
class ChatMessageFrame extends StatelessWidget {
  const ChatMessageFrame({
    super.key,
    required this.message,
    required this.senderName,
    required this.child,
    this.senderEmoji = '',
  });

  final ChatMessage message;
  final String senderName;
  final String senderEmoji;
  final Widget child;

  bool get _mine => message.direction == ChatDirection.outbound;

  @override
  Widget build(BuildContext context) {
    final nameStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: const Color(0xFF9C9B99),
          fontWeight: FontWeight.w700,
        );
    final timeStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: const Color(0xFFB0AEAA),
        );

    final column = Column(
      crossAxisAlignment:
          _mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(
            left: _mine ? 0 : 4,
            right: _mine ? 4 : 0,
            bottom: 4,
          ),
          child: Text(senderName, style: nameStyle),
        ),
        child,
        Padding(
          padding: EdgeInsets.only(
            top: 4,
            left: _mine ? 0 : 4,
            right: _mine ? 4 : 0,
          ),
          child: Text(_formatTime(message.createdAtMs), style: timeStyle),
        ),
      ],
    );

    final avatar = _ChatAvatar(emoji: senderEmoji);

    return Align(
      alignment: _mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.88,
        ),
        child: Row(
          mainAxisAlignment:
              _mine ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!_mine) ...[
              avatar,
              const SizedBox(width: 8),
            ],
            Flexible(child: column),
            if (_mine) ...[
              const SizedBox(width: 8),
              avatar,
            ],
          ],
        ),
      ),
    );
  }

  static String _formatTime(int ms) {
    if (ms <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final hm =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    final sameDay =
        dt.year == now.year && dt.month == now.month && dt.day == now.day;
    if (sameDay) return hm;
    return '${dt.month}/${dt.day} $hm';
  }
}

class _ChatAvatar extends StatelessWidget {
  const _ChatAvatar({required this.emoji});

  final String emoji;

  @override
  Widget build(BuildContext context) {
    final face = emoji.trim().isEmpty ? '🙂' : emoji.trim();
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFFEAF3EC),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(face, style: const TextStyle(fontSize: 22)),
    );
  }
}
