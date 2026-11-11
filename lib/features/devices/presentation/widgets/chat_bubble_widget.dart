import 'package:flutter/material.dart';

import '../../domain/entities/chat_message.dart';

/// 文字气泡内容（外侧头像/名/时间由 [ChatMessageFrame] 包一层）。
class ChatBubbleWidget extends StatelessWidget {
  const ChatBubbleWidget({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final mine = message.direction == ChatDirection.outbound;
    final bg = mine
        ? Theme.of(context).colorScheme.primary
        : Colors.white;
    final fg = mine ? Colors.white : const Color(0xFF1A1918);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.68,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          border: mine ? null : Border.all(color: const Color(0xFFE6E2DC)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Text(
            message.body,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: fg),
          ),
        ),
      ),
    );
  }
}
