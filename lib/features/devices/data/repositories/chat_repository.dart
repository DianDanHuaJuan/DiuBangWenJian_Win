import '../../domain/entities/chat_message.dart';
import '../datasources/chat_local_data_source.dart';

/// 聊天仓库。
class ChatRepository {
  ChatRepository({required ChatLocalDataSource local}) : _local = local;

  final ChatLocalDataSource _local;

  Future<void> save(ChatMessage message) => _local.upsert(message);

  Future<List<ChatMessage>> messagesFor(String peerFingerprint) =>
      _local.listForPeer(peerFingerprint);

  Future<ChatMessage?> findById(String id) => _local.findById(id);
}
