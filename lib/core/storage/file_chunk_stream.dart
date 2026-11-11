import 'dart:io';

/// 视频/大文件播流默认读盘块（对齐原 NAS Server 901db47）。
const int kNasFileReadChunkBytes = 256 * 1024;

/// 按固定块大小读取文件。
///
/// [endExclusive] 为开区间结束偏移；null 表示读到 EOF。
Stream<List<int>> openFileChunked(
  File file, {
  int start = 0,
  int? endExclusive,
  int chunkSize = kNasFileReadChunkBytes,
}) async* {
  if (chunkSize <= 0) {
    throw ArgumentError.value(chunkSize, 'chunkSize', 'must be > 0');
  }
  final raf = await file.open();
  try {
    final fileSize = await raf.length();
    final end = endExclusive ?? fileSize;
    if (start < 0 || start >= end || start >= fileSize) {
      return;
    }
    final clampedEnd = end > fileSize ? fileSize : end;
    await raf.setPosition(start);
    var remaining = clampedEnd - start;
    while (remaining > 0) {
      final readSize = remaining < chunkSize ? remaining : chunkSize;
      final data = await raf.read(readSize);
      if (data.isEmpty) break;
      yield data;
      remaining -= data.length;
    }
  } finally {
    await raf.close();
  }
}
