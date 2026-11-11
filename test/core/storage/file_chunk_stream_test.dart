import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:diubangwenjian/core/storage/file_chunk_stream.dart';

void main() {
  late Directory tempDir;
  late File file;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('chunk_stream_');
    file = File(p.join(tempDir.path, 'payload.bin'));
    // 700KB：覆盖多块 + 尾块
    final bytes = List<int>.generate(700 * 1024, (i) => i % 256);
    await file.writeAsBytes(bytes, flush: true);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('openFileChunked 默认 256KB 分块且内容完整', () async {
    final chunks = <List<int>>[];
    await for (final c in openFileChunked(file)) {
      chunks.add(c);
    }
    expect(chunks.length, 3);
    expect(chunks[0].length, kNasFileReadChunkBytes);
    expect(chunks[1].length, kNasFileReadChunkBytes);
    expect(chunks[2].length, 700 * 1024 - 2 * kNasFileReadChunkBytes);
    final joined = chunks.expand((e) => e).toList();
    expect(joined.length, 700 * 1024);
    expect(joined[0], 0);
    expect(joined[255], 255);
  });

  test('openFileChunked 支持 Range 子区间', () async {
    final chunks = <List<int>>[];
    await for (final c in openFileChunked(
      file,
      start: 100,
      endExclusive: 100 + 10,
      chunkSize: 4,
    )) {
      chunks.add(c);
    }
    final joined = chunks.expand((e) => e).toList();
    expect(joined.length, 10);
    expect(joined.first, 100 % 256);
  });
}
