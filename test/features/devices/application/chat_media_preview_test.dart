import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:diubangwenjian/core/task/transfer_task.dart';
import 'package:diubangwenjian/features/devices/application/chat_media_preview.dart';
import 'package:diubangwenjian/features/devices/domain/entities/chat_message.dart';

TransferTask _task({
  required String id,
  required String path,
  required String name,
  TransferTaskState state = TransferTaskState.done,
}) {
  return TransferTask(
    id: id,
    type: TransferTaskType.p2pOffer,
    state: state,
    peerFingerprint: 'ab' * 32,
    fileName: name,
    sizeBytes: 12,
    createdAtMs: 1,
    localPath: path,
  );
}

void main() {
  late Directory tempDir;
  late File jpg;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('chat_preview_');
    jpg = File(p.join(tempDir.path, 'a.jpg'));
    await jpg.writeAsBytes([1, 2, 3]);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('图片任务可预览；缺文件或非媒体不可预览', () {
    final ok = _task(id: '1', path: jpg.path, name: 'a.jpg');
    expect(isChatMediaPreviewable(ok), isTrue);
    expect(fileEntryFromTransferTask(ok)!.isImage, isTrue);

    final missing = _task(
      id: '2',
      path: p.join(tempDir.path, 'gone.jpg'),
      name: 'gone.jpg',
    );
    expect(isChatMediaPreviewable(missing), isFalse);

    final pdf = File(p.join(tempDir.path, 'n.pdf'));
    pdf.writeAsBytesSync([1]);
    final doc = _task(id: '3', path: pdf.path, name: 'n.pdf');
    expect(isChatMediaPreviewable(doc), isFalse);
  });

  test('会话媒体列表按消息顺序去重', () {
    final t = _task(id: '1', path: jpg.path, name: 'a.jpg');
    final messages = [
      ChatMessage(
        id: 'm1',
        peerFingerprint: 'p',
        direction: ChatDirection.outbound,
        kind: ChatMessageKind.offer,
        body: '1',
        createdAtMs: 1,
      ),
      ChatMessage(
        id: 'm2',
        peerFingerprint: 'p',
        direction: ChatDirection.outbound,
        kind: ChatMessageKind.offer,
        body: '1',
        createdAtMs: 2,
      ),
    ];
    final list = chatSessionMediaEntries(
      messages: messages,
      tasksById: {'1': t},
    );
    expect(list, hasLength(1));
    expect(list.first.name, 'a.jpg');
  });
}
