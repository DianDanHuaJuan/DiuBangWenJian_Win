import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/file_provider/file_entry.dart';
import '../../../core/task/transfer_task.dart';
import '../domain/entities/chat_message.dart';

/// 互传任务 → 本机 [FileEntry]（聊天预览走同一套画廊，不另起 UI）。
FileEntry? fileEntryFromTransferTask(
  TransferTask task, {
  String? overrideAbsolutePath,
}) {
  final path = overrideAbsolutePath ?? task.localPath;
  if (path == null || path.isEmpty) return null;
  final name = task.fileName.isNotEmpty ? task.fileName : p.basename(path);
  return FileEntry(
    name: name,
    relativePath: path,
    rootId: 'chat',
    rootDisplayName: '聊天',
    isDirectory: false,
    sizeBytes: task.sizeBytes,
    modifiedAtMs: task.updatedAtMs ?? task.createdAtMs,
    absolutePath: path,
  );
}

bool _isImageOrVideoName(String name) {
  final lower = name.toLowerCase();
  const images = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic'];
  const videos = ['.mp4', '.mov', '.mkv', '.webm', '.avi', '.m4v'];
  return images.any(lower.endsWith) || videos.any(lower.endsWith);
}

bool _isImageName(String name) {
  final lower = name.toLowerCase();
  const images = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic'];
  return images.any(lower.endsWith);
}

/// 出站有源文件 / 入站已落盘 / 入站图片已在报价缓存 → 可预览。
bool isChatMediaPreviewable(
  TransferTask? task, {
  String? cachedPath,
}) {
  if (task == null) return false;
  if (!_isImageOrVideoName(task.fileName)) return false;
  final path = cachedPath ?? task.localPath;
  if (path == null || path.isEmpty) return false;
  return File(path).existsSync();
}

/// 入站图片：可先拉缓存再预览；视频须下载后播（策略 §5.3）。
bool canPullChatImagePreview(TransferTask? task) {
  if (task == null) return false;
  if (task.type != TransferTaskType.p2pDownload) return false;
  if (task.state != TransferTaskState.offered &&
      task.state != TransferTaskState.failed) {
    return false;
  }
  return _isImageName(task.fileName);
}

bool _isVideoName(String name) {
  final lower = name.toLowerCase();
  const videos = ['.mp4', '.mov', '.mkv', '.webm', '.avi', '.m4v', '.3gp'];
  return videos.any(lower.endsWith);
}

/// 入站视频：可先拉到 App 缓存预览；点预览内「下载」再晋升公共库。
bool canPullChatVideoPreview(TransferTask? task) {
  if (task == null) return false;
  if (task.type != TransferTaskType.p2pDownload) return false;
  if (task.state != TransferTaskState.offered &&
      task.state != TransferTaskState.failed) {
    return false;
  }
  return _isVideoName(task.fileName);
}

/// 本会话内可预览媒体（出站源文件 / 入站已落盘 / 缓存原图）。
List<FileEntry> chatSessionMediaEntries({
  required List<ChatMessage> messages,
  required Map<String, TransferTask> tasksById,
  Map<String, String>? cachedPathsByTaskId,
}) {
  final seen = <String>{};
  final out = <FileEntry>[];
  for (final m in messages) {
    if (m.kind != ChatMessageKind.offer) continue;
    final task = tasksById[m.body];
    if (task == null) continue;
    final cached = cachedPathsByTaskId?[task.id];
    if (!isChatMediaPreviewable(task, cachedPath: cached)) continue;
    final entry = fileEntryFromTransferTask(
      task,
      overrideAbsolutePath: cached ?? task.localPath,
    );
    if (entry == null) continue;
    final key = entry.absolutePath!;
    if (!seen.add(key)) continue;
    out.add(entry);
  }
  return out;
}
